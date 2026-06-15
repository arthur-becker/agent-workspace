# Agent Workspace (Claude Code) — Dokploy container

A single self-hosted container, deployable via [Dokploy](https://dokploy.com), that gives you a
persistent dev box wired for **Claude Code**, reachable three ways:

| # | Access path | How |
|---|-------------|-----|
| 1 | **SSH** | `ssh agent@<host> -p <SSH_PUBLISH_PORT>` |
| 2 | **VS Code Remote-SSH** (+ Claude Code extension) | VS Code → *Remote-SSH: Connect to Host* over the same SSH endpoint |
| 3 | **Browser VS Code** | `code-server` exposed on a Dokploy domain |

**Baked in:** Node.js 22 (runs Claude Code), Python 3 + `uv`/`pip`, Bun, Docker CLI, git, ripgrep, jq, tmux, build tools.

> ⚠️ This box runs an autonomous agent with shell access. **Read [SECURITY.md](SECURITY.md)** before exposing it — it covers force-push protection, keeping secrets out of the agent's env, the Docker-socket/sudo trade-offs, and a hardening checklist.

## Layout

```
Dockerfile             # the image
scripts/entrypoint.sh  # configures access, runs sshd + code-server
docker-compose.yml     # Dokploy Compose deployment
.env.example           # env vars to set in Dokploy
```

## Persistence
Two named volumes survive redeploys:
- `workspace-projects` → `/workspace` (your code/projects)
- `workspace-home` → `/home/agent` (Claude Code login/creds, code-server state, shell history, SSH host keys)

So once you log into Claude Code, you stay logged in across restarts.

## Deploy on Dokploy

1. **Push this repo** to GitHub/GitLab (or use Dokploy's raw Compose with build context).
2. In Dokploy: **Create → Compose**, connect the repository, set the compose path to `docker-compose.yml`.
3. **Environment** tab — set the variables from [.env.example](.env.example):
   - `AUTHORIZED_KEYS` → your SSH **public** key (`cat ~/.ssh/id_ed25519.pub`)
   - `CODE_SERVER_PASSWORD` → a strong password for browser VS Code
   - `SSH_PUBLISH_PORT` → a free host port, e.g. `2222`
   - `ANTHROPIC_API_KEY` → optional (or log in interactively later)
4. **Domains** tab — add a domain (e.g. `workspace.yourdomain.com`) routing to the `workspace`
   service, container port **8080**. Enable HTTPS. → that's browser VS Code (path 3).
5. **Deploy.** Make sure the host firewall allows your `SSH_PUBLISH_PORT`.

## Use it

**Path 1 — SSH**
```bash
ssh agent@your-server -p 2222
claude            # first run: log in interactively
```

**Path 2 — VS Code Remote-SSH**
- Add to `~/.ssh/config`:
  ```
  Host agent-workspace
    HostName your-server
    User agent
    Port 2222
  ```
- VS Code → *Remote-SSH: Connect to Host* → `agent-workspace`.
- Install the **Claude Code** extension in that remote window; open the integrated terminal and run `claude`.

**Path 3 — Browser VS Code**
- Visit `https://workspace.yourdomain.com`, enter `CODE_SERVER_PASSWORD`.
- Open the integrated terminal → `claude`.
- Claude Code's VS Code extension installs from the [Open VSX](https://open-vsx.org) registry that
  code-server uses; if it isn't listed there, use the integrated terminal (the CLI is identical).

## Notes & knobs
- **Docker-in-workspace:** the host Docker socket is mounted so the agent can build/run containers.
  The entrypoint aligns the in-container `docker` group to the socket's GID automatically. Remove the
  `/var/run/docker.sock` volume in `docker-compose.yml` if you don't want this.
- **Key-only SSH:** leave `SSH_PASSWORD` empty (default). Root login is disabled; you connect as `agent` (passwordless sudo).
- **Auth for code-server:** if you leave `CODE_SERVER_PASSWORD` empty, code-server runs with `--auth none` — only do that if you put Dokploy/Traefik auth in front of the domain.
- **Resize/scale:** it's a normal container — bump CPU/RAM in Dokploy as needed.
