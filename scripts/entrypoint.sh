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

# --- 2. Docker socket permissions -------------------------------------------
# If the host's docker socket is mounted, align the in-container docker group
# GID to the socket's owner GID so ${USERNAME} can use it without root.
if [[ -S /var/run/docker.sock ]]; then
  SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
  if ! getent group "${SOCK_GID}" >/dev/null; then
    groupmod -g "${SOCK_GID}" docker 2>/dev/null || groupadd -g "${SOCK_GID}" dockerhost
  fi
  TARGET_GROUP="$(getent group "${SOCK_GID}" | cut -d: -f1)"
  usermod -aG "${TARGET_GROUP}" "${USERNAME}" || true
  log "Docker socket detected; ${USERNAME} added to group ${TARGET_GROUP} (gid ${SOCK_GID})."
fi

# --- 3. Pass through Anthropic creds if provided -----------------------------
# Optional: set ANTHROPIC_API_KEY in the env for non-interactive auth.
# Otherwise just run `claude` after connecting and log in interactively.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "export ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" > "${USER_HOME}/.anthropic_env"
  grep -q anthropic_env "${USER_HOME}/.bashrc" 2>/dev/null \
    || echo "[ -f ~/.anthropic_env ] && source ~/.anthropic_env" >> "${USER_HOME}/.bashrc"
  chown "${USERNAME}:${USERNAME}" "${USER_HOME}/.anthropic_env"
fi

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
