#!/usr/bin/env bash
# Boots the agent workspace: configures access, then runs sshd + code-server together.
set -euo pipefail

USERNAME="${USERNAME:-agent}"
USER_HOME="/home/${USERNAME}"

log() { echo "[entrypoint] $*"; }

# --- 1. SSH access (paths 1 & 2) ---------------------------------------------
# Public-key auth via AUTHORIZED_KEYS (paste one or more keys, newline-separated).
mkdir -p "${USER_HOME}/.ssh"
if [[ -n "${AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "${AUTHORIZED_KEYS}" > "${USER_HOME}/.ssh/authorized_keys"
  log "Installed authorized_keys for ${USERNAME}."
fi
chmod 700 "${USER_HOME}/.ssh"
[[ -f "${USER_HOME}/.ssh/authorized_keys" ]] && chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/.ssh"

# Optional password login (handy for first connect; key auth is preferred).
if [[ -n "${SSH_PASSWORD:-}" ]]; then
  echo "${USERNAME}:${SSH_PASSWORD}" | chpasswd
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  log "Password auth enabled for ${USERNAME}."
else
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Generate host keys on first boot (persisted via the home/etc volume if mounted).
ssh-keygen -A >/dev/null 2>&1 || true

# --- 2. Block cloud-metadata egress -----------------------------------------
# Stops the agent (or anything it runs) from reaching cloud instance-metadata
# endpoints and stealing the host's IAM/cloud credentials — an SSRF/prompt-
# injection path that bypasses the container boundary entirely. We blackhole the
# routes as root; the non-root agent can't undo them (no CAP_NET_ADMIN, and `ip`
# is not in its sudo allowlist). Requires the NET_ADMIN cap (set in compose).
block_metadata() {
  local had_admin=1 t
  # IPv4 metadata endpoints across clouds (AWS/Azure/GCP/DO/Oracle/Hetzner=.169.254,
  # AWS ECS task=.170.2, Alibaba=100.100.100.200).
  for t in 169.254.169.254/32 169.254.170.2/32 100.100.100.200/32; do
    ip route replace blackhole "$t" 2>/dev/null || had_admin=0
  done
  # IPv6 IMDS (AWS).
  ip -6 route replace blackhole fd00:ec2::254/128 2>/dev/null || true
  if [[ $had_admin -eq 1 ]]; then
    log "Cloud-metadata egress blocked (blackhole routes)."
  else
    log "WARNING: could not add blackhole routes — missing NET_ADMIN cap? Metadata NOT blocked." >&2
  fi
}
block_metadata

# --- Docker ------------------------------------------------------------------
# No host socket is mounted. The `docker` CLI reaches the rootless dind sidecar
# over TCP via DOCKER_HOST (tcp://docker:2375), set in the image. Nothing to do
# here; the daemon comes up as a separate compose service. See SECURITY.md.

# --- 3. Claude Code auth -----------------------------------------------------
# By design, NO Anthropic secret is injected into the agent's environment.
# Log in interactively the first time you connect:  `claude`  (the OAuth token
# is stored in ~/.claude, persisted by the volume). This is what keeps the key
# out of `env` / `/proc/*/environ` for the agent. See SECURITY.md for the
# advanced `apiKeyHelper` option if you need non-interactive auth.

# Make sure the home + workspace are owned by the user (volumes can reset this).
chown "${USERNAME}:${USERNAME}" "${USER_HOME}" "${WORKSPACE:-/workspace}" 2>/dev/null || true

# --- 4. Start sshd (background) ----------------------------------------------
log "Starting sshd on :22"
/usr/sbin/sshd -D &
SSHD_PID=$!

# --- 5. Start code-server (browser VS Code, path 3) --------------------------
CODE_PORT="${CODE_SERVER_PORT:-8080}"
export PASSWORD="${CODE_SERVER_PASSWORD:-}"   # consumed by code-server
AUTH_MODE="password"
[[ -z "${PASSWORD}" ]] && AUTH_MODE="none"    # rely on Dokploy/Traefik auth if no password set

log "Starting code-server on :${CODE_PORT} (auth=${AUTH_MODE})"
exec sudo -u "${USERNAME}" --preserve-env=PASSWORD,PATH,HOME,BUN_INSTALL \
  env HOME="${USER_HOME}" \
  code-server \
    --bind-addr "0.0.0.0:${CODE_PORT}" \
    --auth "${AUTH_MODE}" \
    --disable-telemetry \
    --user-data-dir "${USER_HOME}/.local/share/code-server" \
    "${WORKSPACE:-/workspace}"

# (exec replaces this shell with code-server; sshd keeps running as a child.)
wait ${SSHD_PID}
