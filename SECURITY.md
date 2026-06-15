# Security model & mitigations

This box runs an autonomous coding agent (Claude Code). Treat it as **a machine
that can run arbitrary code as the `agent` user**. Design your controls around
that, not around trusting the agent to behave.

## The one thing to internalize
This setup is hardened so the agent's blast radius is **its own container and the
repos it has write access to — and nothing else.** Two facts shape that:

1. **No `sudo` for the agent.** The `agent` user (which runs Claude Code) has **zero
   sudo** — it cannot install system packages, edit root-owned guardrails, or escalate
   to root at all. Everything it needs installs **user-space** (npm/uv/pip/bun into its
   own home). System changes require logging in as a **separate `admin` account** with
   full sudo — a human break-glass login the agent never uses. This closes the old
   `sudo apt-get → root package scripts → container-root` escalation entirely.
2. **No Docker at all, no host reach.** There is **no Docker** in this workspace —
   no CLI and no daemon (the rootless dind sidecar has been removed). The agent
   cannot build or run containers, so there's no Docker socket to abuse, no nested
   user namespaces, and no relaxed `seccomp`/`apparmor`. Combined with the non-root
   `agent` user in an unprivileged container, this is what makes it acceptable to run
   **on the same host as production apps**.

In-container controls still primarily prevent **accidents**. The hard guarantees
for your two stated concerns come from **outside** the container:

| Concern | Real guarantee (outside) | In-container defense-in-depth (this repo) |
|---|---|---|
| Force-push / rewriting your repos | **Agent has no git credentials** (can't authenticate a write) + remote branch protection | Claude deny on remote git + pre-push hook (agent-only) |
| Secrets leaking via env | **Don't put secrets in env** (interactive login) | deny rules on `env`/cred files |
| Agent reaching the host / prod | **No Docker at all + unprivileged, non-root container** | no agent sudo, key-only SSH, network isolation |

---

## Concern 1 — "no `git push --force` / no altering used repositories"

The stance here: **the `agent` user can't alter your remotes because it has no git
remote credentials.** A write to any real remote requires authentication; the agent has
none, so it can't push, delete, or force-push anything. The human **`admin`** account
holds the credentials and does all remote sync. (Note this blocks *authenticated writes*,
not anonymous reads — the agent can still `clone`/`fetch` a public remote unless you also
restrict egress; see the egress-allowlist note under "Other risks.")

**What enforces it (strongest first):**
1. **No push credentials for the agent (the hard guarantee).** Don't provision any git
   remote credential into the agent's reach — no SSH key in `/home/agent/.ssh`, no PAT,
   no `~/.git-credentials`/`.netrc`, no token embedded in a repo's remote URL, no
   credential helper. With no way to authenticate, the agent simply can't write to a
   remote. **This is the whole control — keep credentials out of its reach** (see the
   hygiene notes below — the agent can read anything in its own env, home, and `/workspace`).
2. **Claude [`managed-settings.json`](config/managed-settings.json) deny** on
   `git push/pull/fetch/ls-remote` — stops Claude even *attempting* remote ops on the
   normal path. (A script Claude runs could still call git directly, but #1 makes it fail.)
3. **[`config/git-hooks/pre-push`](config/git-hooks/pre-push)** — a system-wide backstop
   that blocks non-fast-forward pushes and ref deletions **for the agent only** (admin
   is unrestricted). Bypassable via `--no-verify`/`sudo`; pure belt-and-suspenders.

**Credential hygiene (this is what you're relying on — get it right):**
- Keep all git remote creds on the **`admin`** account: an **SSH key in `/home/admin/.ssh`**
  (mode 700; the agent isn't in admin's group, so it can't read it) is the clean choice.
- **Never embed a token in a remote URL** (`https://x-access-token:TOKEN@github.com/…`) —
  that lands in `.git/config` *inside `/workspace`*, which the agent can read.
- Avoid `~/.git-credentials`, `.netrc`, or credential helpers that cache **under `/workspace`**
  or system-wide; keep any helper storage in `/home/admin`.

**Still recommended — branch protection on the remote** (now the admin's pushes are the
only ones that reach it, but defense-in-depth and accident-prevention for *you* matter):
- **GitHub:** Settings → Branches → protect `main` → *"Do not allow force pushes"* +
  *"Do not allow deletions"*. Better: require PRs.
- **GitLab:** Protected Branches → *Allowed to force push = No*.
- Self-hosted bare remote: `git config receive.denyNonFastForwards true` and
  `receive.denyDeletes true` on the server. These can't be bypassed by any client.

**Publishing the agent's work (kept deliberately simple and safe).** `/workspace` is the
agent's **private, agent-owned** working area — it is *not* shared writable with `admin`,
and we set **no** `safe.directory`. That keeps git's "dubious ownership" protection **ON**:
if `admin` runs git inside an agent-owned repo, git stops rather than silently executing
the repo's (agent-controlled, prompt-injectable) config. Nothing is auto-trusted, so there
is **no standing agent→admin config-injection exposure**. The only cost: admin can't push
the agent's commits *in-place* without a deliberate step. Recommended ways to publish:
- **Review and push from a clean clone** (your workstation, or a fresh `admin` clone of the
  remote): pull the agent's branch over SSH, review the diff, push. The agent's repo config
  never runs on your trusted side.
- **Or push in-place, consciously:** as `admin`, opt into that one repo with
  `git config --global --add safe.directory <path>` (plus `sudo` for write access) — you're
  then trusting that repo's config, so do it only after reviewing the diff.

**To make it airtight (optional):** block the agent's network egress to git hosts so it
can't even *read* a remote anonymously — see the egress-allowlist note under "Other risks."

## Concern 2 — "the agent shouldn't read ENV variables (secrets)"

You **can** keep secrets out of the agent's environment, and the repo is set up to make
that the easy path — **but it only holds if you actually follow it.** It is not magic:
the protection is "don't put secrets in the container env," not a filter that scrubs them.

> ⚠️ **Risk — this is the main thing to get right.** Anything you put in the container
> environment (a compose `environment:` entry, a value in `.env`, an exported shell var)
> is **readable by the agent** — via `env`, `/proc/<pid>/environ`, `process.env`, etc. The
> managed-settings `deny` on `env`/`printenv` only blocks Claude's *own* tooling on the
> easy path; it does **not** stop a script the agent runs, and it can't un-leak a secret
> that's already in the environment. So: **do not set `ANTHROPIC_API_KEY` (or any other
> secret) in compose / `.env` / the container env.** If you don't yet know how to wire up
> the interactive login below, that's fine — the safe default is simply to leave those
> values unset and log in interactively when you first run `claude`.

What the repo does to keep the easy path safe:
- **`ANTHROPIC_API_KEY` is not set in the container env (by design).** You log in once with
  `claude` (interactive OAuth); the token is stored in `~/.claude` (persisted in the
  `workspace-home` volume). Result: `env`, `printenv`, `/proc/<pid>/environ`, and
  `process.env` contain no Anthropic secret — *as long as you don't add one yourself.*
- The entrypoint launches `code-server` with a **whitelist** of preserved env vars
  (`PASSWORD,PATH,HOME,BUN_INSTALL`), so terminals it spawns don't inherit stray secrets.
- `sshd` doesn't forward the container's env into login shells by default.
- [`managed-settings.json`](config/managed-settings.json) additionally denies `env`,
  `printenv`, and reads of `**/.env` and the credentials file.

**Honest limits:** you cannot hide a file-based credential from a process running as
the same user — the agent could read `~/.claude/.credentials.json`. The meaningful
controls are: (a) don't inject secrets into env (done), and (b) scope what the
credential can do (use a key/token with least privilege).

**If you need non-interactive auth without a plaintext env var** — use
`apiKeyHelper`: a script that prints the key on demand, fetched from a secret
manager (Vault, Doppler, cloud secret store). Set in `~/.claude/settings.json`:
```json
{ "apiKeyHelper": "/usr/local/bin/fetch-anthropic-key.sh" }
```
The key then never sits in env or on disk at rest.

---

## Other risks worth knowing

- **No Docker — removed entirely.** This workspace has no Docker CLI and no daemon
  (the rootless dind sidecar is gone). The agent **cannot build or run containers.**
  This deletes the single largest piece of attack surface the box used to carry: no
  Docker socket, no nested user namespaces, and no `seccomp=unconfined` /
  `apparmor=unconfined` relaxations (those existed *only* to let rootless dind create
  user namespaces). Defense-in-depth: a managed-settings `deny` on `Bash(docker:*)`
  stops Claude from running `docker` even if the CLI were reinstalled via `sudo apt-get`.
  - **If you ever need container build/run back:** restore the `docker:dind-rootless`
    service + `DOCKER_HOST` env from git history. That rootless-dind design (no host
    socket, no `privileged`) is the *safe* way to add it — but the safest posture, and
    the current one, is no Docker at all.
- **Two accounts: agent (no sudo) + admin (full sudo).** Claude Code runs as `agent`,
  which has **no sudo at all** — there's no `sudoers.d/agent`. The agent installs only
  user-space tooling (npm/uv/pip/bun into `~`); it cannot touch system packages or
  root-owned files. A separate **`admin`** user holds full `NOPASSWD:ALL` sudo and is
  reachable only by human SSH login (`ADMIN_AUTHORIZED_KEYS` / `ADMIN_PASSWORD`) — you
  use it to apt-install or change the system. Because the admin's sudo is NOPASSWD, the
  **SSH login is the gate**: keep it **key-only** (an `ADMIN_PASSWORD` is effectively a
  root password). The agent never has, and never uses, this account.
  - A managed-settings `deny` on `Bash(sudo:*)` stops Claude from even attempting sudo
    (it would fail anyway — `agent` isn't in any sudoers file).
  - **For maximum lockdown** you can drop the `admin` account too and pre-install
    everything at build time, leaving no sudo path in the running container at all.
- **Recommended workflow: log in as `admin`, run Claude as `agent` (enforced).** You
  get the best of both — sudo is one command away, but Claude stays sandboxed. The
  `claude` command is a **wrapper** ([`scripts/claude-wrapper`](scripts/claude-wrapper),
  installed as `/usr/local/bin/claude`; the real CLI is `claude.real`) that **always
  re-execs as `agent`**, no matter who launches it — your shell *or* the VS Code
  extension calling the binary directly. So:
  - `ssh admin@host` → you're admin; `sudo apt-get install …` works directly.
  - type `claude` (from `/workspace`) → it drops to `agent` and runs sandboxed there.
  - Claude **cannot** borrow your admin sudo: it runs under a different uid, and sudo's
    cached credentials are per-uid/tty — a process running as `agent` can't use them.
  - Run `claude` from a directory the agent owns (normally `/workspace`); the wrapper
    refuses a dir the agent can't read (e.g. `/home/admin`). Note: an npm update to
    claude-code overwrites the wrapper — re-apply it (see the Dockerfile note).
- **Cloud-metadata theft — mitigated.** The entrypoint installs blackhole routes to
  the cloud instance-metadata IPs (`169.254.169.254`, `169.254.170.2`, `100.100.100.200`,
  IPv6 `fd00:ec2::254`) so the agent can't pull the host's IAM/cloud credentials. This
  needs the `NET_ADMIN` cap (granted in compose); the route is set by root at boot and
  the non-root agent can't remove it (it has no sudo and no `CAP_NET_ADMIN`).
  - **Optional host belt-and-suspenders (cloud VM):** you can still drop metadata at the
    host firewall for the workspace's subnet, and on AWS enforce IMDSv2 + hop-limit 1:
    ```bash
    # On the Docker host. Find the workspace bridge subnet first:
    #   docker network inspect <stack>_default | grep Subnet
    iptables  -I DOCKER-USER -s <that-subnet> -d 169.254.169.254 -j DROP
    iptables  -I DOCKER-USER -s <that-subnet> -d 169.254.170.2   -j DROP
    ip6tables -I DOCKER-USER -s <that-subnet6> -d fd00:ec2::254  -j DROP 2>/dev/null || true
    ```
- **Network reach (important on a shared host).** Docker keeps the workspace off your
  other apps' networks, so the agent can't directly dial prod containers by name. But
  it **can** reach (a) anything your prod apps publish on the host's ports, and (b) the
  host gateway IP. If a prod DB/admin port is published on `0.0.0.0`, the agent could
  hit it. Mitigations: bind prod published ports to `127.0.0.1` (not `0.0.0.0`), keep
  prod service-to-service traffic on internal Docker networks (unpublished), and/or add
  host-firewall rules blocking the workspace's subnet from prod ports.
- **Limiting egress (optional, makes "no remote git" airtight and curbs exfiltration).**
  The agent has general outbound network (it needs the Anthropic API + package
  registries), so "no remote git" via the wrapper/creds is bypassable for *reads* and
  exfiltration is possible. To close that, force all egress through an allowlist: run a
  forward proxy and **block direct egress** at the host firewall (`DOCKER-USER`), then
  allow only the hosts you need (`api.anthropic.com`, your registries). Caveat: any
  allowlisted host that can store data is itself an exfil channel (e.g. allowing
  `github.com` for the admin's pushes also lets a leak ride out over it), so the value
  scales with how tight the list is. This is real infrastructure, not a one-liner.
- **code-server auth.** Always set `CODE_SERVER_PASSWORD` (or front it with Dokploy
  auth) and serve it only over HTTPS. `--auth none` + public domain = open shell.
- **SSH.** Key-only by default (`SSH_PASSWORD` empty), root login disabled. Keep it
  that way; rotate the published port off 22 if exposed to the internet.
- **Base image CVEs.** `node:22-bookworm` carries OS-level CVEs over time. Rebuild
  regularly to pull patches; pin to a digest for reproducibility if you need it.

## Running on a shared host with production (your setup)

You've chosen to run this next to prod on the same Dokploy host. Removing Docker
(above) eliminates the biggest danger this box used to carry — no daemon, no nested
user namespaces, no relaxed seccomp/apparmor. Do these in addition:

1. **Cap resources** so a runaway agent can't starve prod — add to the `workspace`
   service in compose (or set in Dokploy's UI):
   ```yaml
   deploy:
     resources:
       limits: { cpus: "2", memory: 4g }
   ```
2. **Don't publish prod internal ports on `0.0.0.0`** — see the network note above.
3. **Least-privilege git token on the `admin` account** — never your full-access PAT.
   The agent gets **no** git remote credential at all (local git only).
4. Accept the residual risk: the agent still runs **arbitrary code as the `agent`
   user** inside the container. The container + non-root user + no-agent-sudo are the
   boundary, not a hard VM. If a future task is highly sensitive, move *that* work to
   a throwaway VM.

## Quick hardening checklist
> Run `security-check` (as both `agent` and `admin`) to auto-verify most of these — see
> README "Verifying the hardening".
- [ ] Agent has NO git remote creds in `/home/agent` (no SSH key / PAT / credential
      helper) — local git only; the `admin` account holds the push credentials
- [ ] Branch protection enabled on every remote `admin` pushes to (defense-in-depth)
- [ ] `ANTHROPIC_API_KEY` not in env (interactive login or `apiKeyHelper`)
- [ ] `CODE_SERVER_PASSWORD` set, domain on HTTPS
- [ ] SSH key-only, sensible published port
- [ ] CPU/memory limits set on the workspace service
- [ ] Prod published ports bound to 127.0.0.1, not 0.0.0.0
- [ ] Cloud-metadata blocked — verify `curl -m2 http://169.254.169.254/` from the
      workspace times out
- [ ] Docker removed — no CLI, no daemon, managed-settings `deny` on `docker`
- [ ] Agent has NO sudo; admin account is key-only (`ADMIN_AUTHORIZED_KEYS` set,
      `ADMIN_PASSWORD` empty), or admin dropped entirely for maximum lockdown
- [ ] Running on a dedicated VM if the work is sensitive (container is not a hard boundary)
