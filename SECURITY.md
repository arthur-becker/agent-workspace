# Security model & mitigations

This box runs an autonomous coding agent (Claude Code). Treat it as **a machine
that can run arbitrary code as the `agent` user**. Design your controls around
that, not around trusting the agent to behave.

## The one thing to internalize
This setup is hardened so the agent's blast radius is **its own container and the
repos it has write access to — and nothing else.** Two facts shape that:

1. **Scoped `sudo`.** The `agent` user can only `sudo` package-management commands
   (`apt-get`/`apt`/`dpkg`/`service`) — not blanket root. It cannot freely escalate
   to delete guardrails or read root-owned files. (Caveat: `sudo apt-get` runs
   package scripts as root, so a determined agent could still reach container-root
   through it — but that's now contained to a host-isolated container, see below.)
2. **No host reach.** The host Docker socket is **not** mounted. Docker runs in an
   isolated dind sidecar, so the agent can't touch the host daemon or your other
   Dokploy apps.

In-container controls still primarily prevent **accidents**. The hard guarantees
for your two stated concerns come from **outside** the container:

| Concern | Real guarantee (outside) | In-container defense-in-depth (this repo) |
|---|---|---|
| Force-push / rewriting your repos | **Remote branch protection** (GitHub/GitLab) | pre-push hook + Claude deny rules |
| Secrets leaking via env | **Don't put secrets in env** (interactive login) | deny rules on `env`/cred files |
| Agent reaching the host | **Isolated dind (no host socket) + dedicated VM** | scoped sudo, non-root user, key-only SSH |

---

## Concern 1 — "no `git push --force` / no altering used repositories"

**Strongest control — do this:** enable branch protection on every remote you
let the agent touch:
- **GitHub:** Settings → Branches → protect `main` → *"Do not allow force pushes"*
  + *"Do not allow deletions"*. Better: require PRs, disallow direct pushes; give
  the agent a token that can only open PRs.
- **GitLab:** Protected Branches → *Allowed to force push = No*.
- Self-hosted bare remote: `git config receive.denyNonFastForwards true` and
  `receive.denyDeletes true` on the server.

These cannot be bypassed by any client, `--no-verify`, or `sudo` in this container.

**Defense-in-depth shipped here (catches accidents):**
- [`config/git-hooks/pre-push`](config/git-hooks/pre-push) — installed system-wide
  (`git config --system core.hooksPath /etc/git-hooks`). Rejects non-fast-forward
  pushes and remote ref deletions for **every** repo. Bypassable via `--no-verify`/`sudo`.
- Claude Code [`managed-settings.json`](config/managed-settings.json) deny rules for
  `git push --force/-f/--force-with-lease/--mirror/--delete/--no-verify`. These are
  prefix matches, so they catch the obvious forms but not every flag reordering —
  again, accident prevention, not enforcement.

## Concern 2 — "the agent shouldn't read ENV variables (secrets)"

You **can** keep secrets out of the agent's environment — and this repo now does
by default:
- **`ANTHROPIC_API_KEY` is never set in the container env.** You log in once with
  `claude` (interactive OAuth); the token is stored in `~/.claude` (persisted in the
  `workspace-home` volume). Result: `env`, `printenv`, `/proc/<pid>/environ`, and
  `process.env` contain no Anthropic secret.
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

- **Docker = isolated dind, not the host.** The `docker` CLI points at a separate
  `docker:dind` sidecar (`DOCKER_HOST=tcp://docker:2375`) on a private network
  with no published port (2375 is unreachable from host/internet). The agent
  builds/runs containers there; it **cannot** see
  the host daemon or your other Dokploy apps. **Honest caveat:** the dind sidecar
  itself runs `privileged: true`, so a container-escape *from inside dind* would land
  on the host — far harder than the host socket (which was direct host-root), but not
  zero. For sensitive work, still run on a dedicated VM. To drop Docker entirely,
  delete the `docker` service + `DOCKER_HOST` env; the CLI just won't connect.
- **Image builds require confirmation.** `docker build`/`buildx`/`compose build`/`push`
  are in the managed-settings `ask` list, so the agent must get an interactive
  approval (you build images manually / on demand, not silently).
- **Scoped sudo (not blanket root).** `sudoers.d/agent` allows only package commands.
  This stops casual escalation, but note `sudo apt-get` can run root package scripts —
  for maximum lockdown, remove the sudoers file and pre-install everything at build time.
- **Network isolation.** The agent can reach anything the container can. For sensitive
  setups, run this on a dedicated VM/network segment, not next to production.
- **code-server auth.** Always set `CODE_SERVER_PASSWORD` (or front it with Dokploy
  auth) and serve it only over HTTPS. `--auth none` + public domain = open shell.
- **SSH.** Key-only by default (`SSH_PASSWORD` empty), root login disabled. Keep it
  that way; rotate the published port off 22 if exposed to the internet.
- **Base image CVEs.** `node:22-bookworm` carries OS-level CVEs over time. Rebuild
  regularly to pull patches; pin to a digest for reproducibility if you need it.

## Quick hardening checklist
- [ ] Branch protection enabled on every remote the agent can push to
- [ ] Agent's git token scoped to least privilege (PR-only if possible)
- [ ] `ANTHROPIC_API_KEY` not in env (interactive login or `apiKeyHelper`)
- [ ] `CODE_SERVER_PASSWORD` set, domain on HTTPS
- [ ] SSH key-only, sensible published port
- [ ] Docker via isolated dind (default) — host socket NOT mounted
- [ ] Sudo is scoped (default), or removed entirely for maximum lockdown
- [ ] Running on a dedicated VM if the work is sensitive (dind is privileged)
