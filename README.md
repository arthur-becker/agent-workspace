# Agent Workspace (Claude Code) — Dokploy container

A single self-hosted container, deployable via [Dokploy](https://dokploy.com), that gives you a
persistent dev box wired for **Claude Code**, reachable three ways:

| # | Access path | How |
|---|-------------|-----|
| 1 | **SSH** | `ssh agent@<host> -p <SSH_PUBLISH_PORT>` |
| 2 | **VS Code Remote-SSH** (+ Claude Code extension) | VS Code → *Remote-SSH: Connect to Host* over the same SSH endpoint |
| 3 | **Browser VS Code** | `code-server` exposed on a Dokploy domain |

**Baked in:** Node.js 22 (runs Claude Code), Python 3 + `uv`/`pip`, Bun, git, ripgrep, jq, tmux, build tools. **No Docker** — the agent can't build or run containers (see SECURITY.md).

> ⚠️ This box runs an autonomous agent with shell access. **Read [SECURITY.md](SECURITY.md)** before exposing it — it covers the agent/admin split (no agent sudo, local-only git), keeping secrets out of the agent's env, and a hardening checklist.

## Layout

```
Dockerfile             # the image
scripts/entrypoint.sh  # configures access, runs sshd + code-server
docker-compose.yml     # Dokploy Compose deployment
.env.example           # env vars to set in Dokploy
```

## Persistence
Named volumes survive restarts and redeploys:
- `workspace-projects` → `/workspace` (your code/projects)
- `workspace-home` → `/home/agent` (Claude Code login/creds, code-server state, shell history, SSH host keys)
- `agent-npm-global` → `/home/agent/.npm-global` (global npm packages)
- `agent-bun` → `/home/agent/.bun` (bun + bun globals)
- `agent-uv` → `/home/agent/.local/share/uv` (uv tools, downloaded Pythons, tool shims)
- `agent-cache` → `/home/agent/.cache` (npm/uv/pip build caches)

So once you log into Claude Code you stay logged in, **and global packages you install
(`npm i -g …`, `uv tool install …`, `bun add -g …`) are NOT reinstalled on the next start.**
Per-project deps (`node_modules`, `.venv`) live under `/workspace` and persist too.

> **Note:** system packages installed via `apt` (as `admin`) live in the image layer and do
> **not** persist across a *redeploy/rebuild*. For tools you always want, add them to the
> [Dockerfile](Dockerfile); `apt` installs are for one-off/runtime needs.

## Deploy on Dokploy

1. **Push this repo** to GitHub/GitLab (or use Dokploy's raw Compose with build context).
2. In Dokploy: **Create → Compose**, connect the repository, set the compose path to `docker-compose.yml`.
3. **Environment** tab — set the variables from [.env.example](.env.example):
   - `AUTHORIZED_KEYS` → the **agent's** SSH **public** key (`cat ~/.ssh/id_ed25519.pub`)
   - `ADMIN_AUTHORIZED_KEYS` → the **admin's** SSH public key (for system/`apt` changes;
     keep key-only — see [SECURITY.md](SECURITY.md))
   - `CODE_SERVER_PASSWORD` → a strong password for browser VS Code
   - `SSH_PUBLISH_PORT` → a free host port, e.g. `2222`
   - `ANTHROPIC_API_KEY` → **leave unset.** Log in interactively (`claude`) instead — a key
     set here is readable by the agent. See [SECURITY.md](SECURITY.md) Concern 2.
4. **Domains** tab — add a domain (e.g. `workspace.yourdomain.com`) routing to the `workspace`
   service, container port **8080**. Enable HTTPS. → that's browser VS Code (path 3).
5. **Deploy.** Make sure the host firewall allows your `SSH_PUBLISH_PORT`.

## Use it

> **Recommended:** connect as **`admin`** so `sudo` is always handy, then just run
> `claude` — a wrapper forces it to run sandboxed as the no-sudo `agent` user (see
> [SECURITY.md](SECURITY.md)). Run it from `/workspace`. You can still connect as
> `agent` directly if you don't want any sudo in the session.

**Path 1 — SSH (as admin, recommended)**
```bash
ssh admin@your-server -p 2222
sudo apt-get install <whatever-you-need>   # admin has full sudo
cd /workspace
claude            # auto-runs as `agent` (no sudo); first run: log in interactively
```

**Path 2 — VS Code Remote-SSH**
- Add to `~/.ssh/config`:
  ```
  Host agent-workspace
    HostName your-server
    User admin          # or `agent` for a no-sudo session
    Port 2222
  ```
- VS Code → *Remote-SSH: Connect to Host* → `agent-workspace`.
- Install the **Claude Code** extension; open the integrated terminal in `/workspace` and run `claude`
  (the wrapper runs it as `agent` even when the extension launches the binary directly).

**Path 3 — Browser VS Code**
- Visit `https://workspace.yourdomain.com`, enter `CODE_SERVER_PASSWORD`.
- This path always runs as `agent` (code-server is launched as `agent`); there is no sudo here.
- Open the integrated terminal → `claude`.
- Claude Code's VS Code extension installs from the [Open VSX](https://open-vsx.org) registry that
  code-server uses; if it isn't listed there, use the integrated terminal (the CLI is identical).

## Verifying the hardening

The image ships a `security-check` command that verifies the controls are actually in
place (no agent sudo, admin sudo, no Docker, no secrets in env, no agent git creds,
managed-settings deny rules, pinned `core.hooksPath`, no blanket `safe.directory`,
cloud-metadata blocked, private workspace, Claude-runs-as-agent wrapper, SSH locked down,
persistence volumes). It exits non-zero if any check **FAIL**s. Some checks are
per-account, so **run it as both `agent` and `admin`**.

**From your machine, over SSH:**
```bash
ssh agent@<host> -p <SSH_PUBLISH_PORT> security-check
ssh admin@<host> -p <SSH_PUBLISH_PORT> security-check
```

**From the Dokploy dashboard** (no SSH needed): open the `workspace` service → **Terminal**,
then run it as each account:
```bash
su - agent -c security-check
su - admin -c security-check
```

**Run it automatically on a schedule (Dokploy):** in the `workspace` service →
**Schedules** (cron jobs), add a job so Dokploy runs the check in the container and you
see PASS/FAIL in the run logs. Example — daily at 03:00:
- **Schedule (cron):** `0 3 * * *`
- **Command:** `bash -lc 'su - agent -c security-check && su - admin -c security-check'`

(The schedule runs inside the already-running container, so it sees the live config.)

## Notes & knobs
- **No Docker (by design):** the agent cannot build or run containers — no Docker CLI
  in the image and no daemon to talk to. This removes the largest piece of attack
  surface (no dind, no nested user namespaces, no relaxed seccomp/apparmor) and is
  why this box is comfortable next to production. A managed-settings `deny` on
  `docker` keeps it off even if the CLI is reinstalled. If you ever need it back,
  restore the `docker:dind-rootless` service from git history (see SECURITY.md).
- **Two accounts — `agent` (no sudo) and `admin` (full sudo):** Claude Code runs as
  `agent`, which has **no sudo** and installs everything user-space (npm/uv/pip/bun).
  To change the system (apt, etc.) SSH in as **`admin`** (`ssh admin@host -p <port>`),
  which has full `NOPASSWD` sudo. Keep `admin` **key-only** (`ADMIN_AUTHORIZED_KEYS`;
  leave `ADMIN_PASSWORD` empty) — with NOPASSWD sudo, an admin password equals root.
- **Git: agent can't alter your remotes, you publish deliberately.** The `agent` works
  locally (commit/branch/merge/diff) but **has no git remote credentials**, so it can't
  push, delete, or force-push anything — a write needs auth it doesn't have. A Claude
  `deny` also stops it attempting `push`/`pull`/`fetch`. `/workspace` is the agent's
  **private** area (not shared writable with `admin`), so there's no repo the agent can
  poison for you. To publish, review the agent's branch and push it from a clean clone
  (your workstation, or a fresh `admin` clone). **The real guarantee is credential
  hygiene: never put a key/PAT in `/home/agent` or a token in a repo URL under
  `/workspace`.** See [SECURITY.md](SECURITY.md) Concern 1.
- **Key-only SSH:** leave `SSH_PASSWORD`/`ADMIN_PASSWORD` empty (default). Root login is disabled.
- **Auth for code-server:** if you leave `CODE_SERVER_PASSWORD` empty, code-server runs with `--auth none` — only do that if you put Dokploy/Traefik auth in front of the domain.
- **Resize/scale:** it's a normal container — bump CPU/RAM in Dokploy as needed.
