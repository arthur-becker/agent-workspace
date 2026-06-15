# Agent workspace for Claude Code — deployable on Dokploy.
# Serves three access paths from one container:
#   1. SSH                         (path 1)
#   2. VS Code Remote-SSH          (path 2, uses the same sshd)
#   3. code-server (browser VS Code) (path 3)
#
# Baked in: Node.js (for Claude Code), Python, Bun, Docker CLI, git + core CLI.

FROM node:22-bookworm

ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- Core CLI + build tooling + Python + sshd ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git openssh-server sudo \
        ripgrep jq vim nano less htop tmux \
        build-essential \
        python3 python3-pip python3-venv pipx \
        unzip zip \
    && rm -rf /var/lib/apt/lists/*

# --- uv (fast Python package/venv manager) ---
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- Docker CLI (talks to the host daemon via a mounted socket) ---
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code (global) ---
RUN npm install -g @anthropic-ai/claude-code

# --- code-server (browser VS Code) ---
RUN curl -fsSL https://code-server.dev/install.sh | sh

# --- Non-root user with passwordless sudo ---
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    # docker group so the mounted socket is usable; GID is fixed up at runtime
    && groupadd -f docker && usermod -aG docker ${USERNAME}

# --- Bun (installed for the agent user) ---
USER ${USERNAME}
RUN curl -fsSL https://bun.sh/install | bash
ENV BUN_INSTALL="/home/${USERNAME}/.bun"
ENV PATH="/home/${USERNAME}/.bun/bin:${PATH}"

USER root

# sshd runtime dir
RUN mkdir -p /var/run/sshd

# Persisted at runtime via volumes (see compose): projects + agent home (creds/config)
RUN mkdir -p /workspace && chown ${USERNAME}:${USERNAME} /workspace

# --- Security guardrails (defense-in-depth; see SECURITY.md) ---
# Claude Code managed settings: highest precedence, not overridable by user/project.
COPY config/managed-settings.json /etc/claude-code/managed-settings.json
# System-wide git pre-push hook: blocks force pushes & remote ref deletions.
COPY config/git-hooks/pre-push /etc/git-hooks/pre-push
RUN chmod +x /etc/git-hooks/pre-push \
    && git config --system core.hooksPath /etc/git-hooks

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV WORKSPACE=/workspace
WORKDIR /workspace

# 22 = SSH (paths 1 & 2), 8080 = code-server (path 3)
EXPOSE 22 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
