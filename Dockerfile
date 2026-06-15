# Agent workspace for Claude Code — deployable on Dokploy.
# Serves three access paths from one container:
#   1. SSH                         (path 1)
#   2. VS Code Remote-SSH          (path 2, uses the same sshd)
#   3. code-server (browser VS Code) (path 3)
#
# Baked in: Node.js (for Claude Code), Python, Bun, git + core CLI.
# NOTE: no Docker CLI — the agent intentionally cannot build or run containers.

FROM node:22-bookworm

ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=1000
# Separate human break-glass admin with FULL sudo. Claude Code runs as ${USERNAME};
# system changes (apt, etc.) require logging in as ${ADMINNAME}. See SECURITY.md.
ARG ADMINNAME=admin
ARG ADMIN_UID=1001
ARG ADMIN_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- Core CLI + build tooling + Python + sshd ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git openssh-server sudo \
        iproute2 procps \
        ripgrep jq vim nano less htop tmux \
        build-essential \
        python3 python3-pip python3-venv pipx \
        unzip zip \
    && rm -rf /var/lib/apt/lists/*

# --- uv (fast Python package/venv manager) ---
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- Claude Code (global), WRAPPED to always run as the `agent` user ---
# The real CLI is moved to claude.real; /usr/local/bin/claude becomes a wrapper that
# drops to `agent` whoever invokes it. This is what lets you log in as `admin` (full
# sudo) yet have Claude itself run sandboxed as `agent`. See SECURITY.md.
# (npm updates to claude-code overwrite the wrapper — re-run the mv/COPY after an update.)
RUN npm install -g @anthropic-ai/claude-code \
    && mv "$(command -v claude)" /usr/local/bin/claude.real
COPY scripts/claude-wrapper /usr/local/bin/claude
RUN chmod 0755 /usr/local/bin/claude

# --- code-server (browser VS Code) ---
RUN curl -fsSL https://code-server.dev/install.sh | sh

# --- Agent user: NON-root and NO sudo at all (see SECURITY.md) ---
# Claude Code runs as this user. It has ZERO sudo — it cannot install system
# packages, edit root-owned guardrails, or escalate. Everything it needs installs
# user-space (npm/uv/pip/bun into its home; see below). System changes require
# logging in as the separate `${ADMINNAME}` account.
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME}

# --- Admin user: FULL sudo, for HUMAN break-glass login only ---
# Not used by the agent. You SSH in as `${ADMINNAME}` to run apt/system changes.
# Sudo is NOPASSWD (the SSH login itself is the gate); set a sudo password instead
# by removing NOPASSWD and providing ADMIN_PASSWORD if you prefer two factors.
RUN groupadd --gid ${ADMIN_GID} ${ADMINNAME} \
    && useradd --uid ${ADMIN_UID} --gid ${ADMIN_GID} -m -s /bin/bash ${ADMINNAME} \
    && printf '%s\n' \
        '# Full, unrestricted sudo for the human admin account.' \
        "${ADMINNAME} ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/${ADMINNAME} \
    && chmod 0440 /etc/sudoers.d/${ADMINNAME} \
    && visudo -cf /etc/sudoers.d/${ADMINNAME}

# --- Bun + user-space package dirs (agent installs globals WITHOUT sudo; these
#     dirs are persisted via dedicated volumes so restarts don't reinstall — see
#     docker-compose.yml) ---
USER ${USERNAME}
RUN curl -fsSL https://bun.sh/install | bash \
    && mkdir -p /home/${USERNAME}/.npm-global \
                /home/${USERNAME}/.bun \
                /home/${USERNAME}/.local/share/uv/bin \
                /home/${USERNAME}/.cache/npm \
                /home/${USERNAME}/.cache/uv
ENV BUN_INSTALL="/home/${USERNAME}/.bun"
ENV NPM_CONFIG_PREFIX="/home/${USERNAME}/.npm-global"
ENV NPM_CONFIG_CACHE="/home/${USERNAME}/.cache/npm"
# uv: pin global tools, their bin shims, downloaded Pythons, and cache under the
# persisted home (the agent-uv / agent-cache volumes). These match uv's defaults
# but pinning guarantees the locations are the ones we persist.
ENV UV_TOOL_DIR="/home/${USERNAME}/.local/share/uv/tools"
ENV UV_TOOL_BIN_DIR="/home/${USERNAME}/.local/share/uv/bin"
ENV UV_PYTHON_INSTALL_DIR="/home/${USERNAME}/.local/share/uv/python"
ENV UV_CACHE_DIR="/home/${USERNAME}/.cache/uv"
ENV PATH="/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.bun/bin:/home/${USERNAME}/.local/share/uv/bin:${PATH}"

USER root

# sshd runtime dir
RUN mkdir -p /var/run/sshd

# Persisted at runtime via volumes (see compose): projects + agent home (creds/config)
# /workspace is the agent's PRIVATE, agent-owned working area — NOT shared writable with
# admin. That avoids a group-writable repo the agent could poison for admin, and keeps
# git's dubious-ownership protection on. The human publishes deliberately — see SECURITY.md.
RUN mkdir -p /workspace && chown ${USERNAME}:${USERNAME} /workspace

# --- Security guardrails (defense-in-depth; see SECURITY.md) ---
# Claude Code managed settings: highest precedence, not overridable by user/project.
# Note: the agent gets no git remote access via the no-credentials posture (don't put
# any SSH key / PAT / credential helper in /home/agent), not a git wrapper. See SECURITY.md.
COPY config/managed-settings.json /etc/claude-code/managed-settings.json
# System-wide git pre-push hook: backstop that blocks force pushes & ref deletions
# for the agent (admin is unrestricted). core.hooksPath is system-wide so a repo's own
# .git/hooks can't run. We deliberately do NOT set safe.directory — /workspace is
# agent-owned and not shared writable, so git's dubious-ownership protection stays ON
# (admin won't silently execute an agent-controlled repo config). See SECURITY.md.
COPY config/git-hooks/pre-push /etc/git-hooks/pre-push
RUN chmod +x /etc/git-hooks/pre-push \
    && git config --system core.hooksPath /etc/git-hooks

# Verification script — run `security-check` (as agent and admin) to confirm the
# hardening is in place. See README "Verifying the hardening".
COPY scripts/security-check.sh /usr/local/bin/security-check
RUN chmod +x /usr/local/bin/security-check

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV WORKSPACE=/workspace
WORKDIR /workspace

# 22 = SSH (paths 1 & 2), 8080 = code-server (path 3)
EXPOSE 22 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
