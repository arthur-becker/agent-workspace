#!/usr/bin/env bash
# Boots the agent workspace: configures access, then runs sshd + code-server together.
set -euo pipefail

USERNAME="${USERNAME:-agent}"
ADMINNAME="${ADMINNAME:-admin}"
USER_HOME="/home/${USERNAME}"

log() { echo "[entrypoint] $*"; }

# --- 1. SSH access (paths 1 & 2) ---------------------------------------------
# Two login accounts:
#   - ${USERNAME}  : runs Claude Code. NO sudo. Auth via AUTHORIZED_KEYS or SSH_PASSWORD.
#   - ${ADMINNAME} : human break-glass with FULL sudo (apt/system changes). Auth via
#                    ADMIN_AUTHORIZED_KEYS or ADMIN_PASSWORD. The agent never uses it.
install_keys() {  # <user> <newline-separated-keys>
  local user="$1" keys="$2" home="/home/$1"
  mkdir -p "${home}/.ssh"
  if [[ -n "${keys}" ]]; then
    printf '%s\n' "${keys}" > "${home}/.ssh/authorized_keys"
    log "Installed authorized_keys for ${user}."
  fi
  chmod 700 "${home}/.ssh"
  [[ -f "${home}/.ssh/authorized_keys" ]] && chmod 600 "${home}/.ssh/authorized_keys"
  chown -R "${user}:${user}" "${home}/.ssh"
}
install_keys "${USERNAME}"  "${AUTHORIZED_KEYS:-}"
install_keys "${ADMINNAME}" "${ADMIN_AUTHORIZED_KEYS:-}"

# Optional password logins (key auth preferred for both). NOTE: the admin has
# NOPASSWD sudo, so an admin password is effectively a ROOT password — prefer keys.
if [[ -n "${SSH_PASSWORD:-}" ]]; then
  echo "${USERNAME}:${SSH_PASSWORD}" | chpasswd && log "Password set for ${USERNAME}."
fi
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  echo "${ADMINNAME}:${ADMIN_PASSWORD}" | chpasswd && log "Password set for ${ADMINNAME}."
fi

# Key-only by default; enable password auth per-user only where a password was set.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
# Idempotent managed block (re-written each boot so restarts don't duplicate it).
sed -i '/# >>> workspace-managed/,/# <<< workspace-managed/d' /etc/ssh/sshd_config
{
  echo "# >>> workspace-managed (per-user password auth; auto-generated)"
  [[ -n "${SSH_PASSWORD:-}"   ]] && printf 'Match User %s\n    PasswordAuthentication yes\n' "${USERNAME}"
  [[ -n "${ADMIN_PASSWORD:-}" ]] && printf 'Match User %s\n    PasswordAuthentication yes\n' "${ADMINNAME}"
  echo "# <<< workspace-managed"
} >> /etc/ssh/sshd_config

# Generate host keys on first boot (persisted via the home/etc volume if mounted).
ssh-keygen -A >/dev/null 2>&1 || true

# --- 2. Block cloud-metadata egress -----------------------------------------
# Stops the agent (or anything it runs) from reaching cloud instance-metadata
# endpoints and stealing the host's IAM/cloud credentials — an SSRF/prompt-
# injection path that bypasses the container boundary entirely. We blackhole the
# routes as root; the non-root agent can't undo them (it has no sudo and no
# CAP_NET_ADMIN). Requires the NET_ADMIN cap (set in compose).
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

# --- 3. Claude Code auth -----------------------------------------------------
# By design, NO Anthropic secret is injected into the agent's environment.
# Log in interactively the first time you connect:  `claude`  (the OAuth token
# is stored in ~/.claude, persisted by the volume). This is what keeps the key
# out of `env` / `/proc/*/environ` for the agent. See SECURITY.md for the
# advanced `apiKeyHelper` option if you need non-interactive auth.

# Make sure home + workspace are owned by the agent (volumes can reset this).
# /workspace is the agent's private working area — not shared writable with admin.
chown "${USERNAME}:${USERNAME}" "${USER_HOME}" "${WORKSPACE:-/workspace}" 2>/dev/null || true
# Fresh named volumes (npm/bun/uv/cache) can come up root-owned — fix their mount
# points so the agent can write its persisted globals. Non-recursive (cheap).
for d in .npm-global .bun .local .local/share .local/share/uv .cache; do
  chown "${USERNAME}:${USERNAME}" "${USER_HOME}/${d}" 2>/dev/null || true
done

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
