# Security model & mitigations

This box runs an autonomous coding agent (Claude Code). Treat it as **a machine
that can run arbitrary code as the `agent` user**. Design your controls around
that, not around trusting the agent to behave.

## The one thing to internalize
The `agent` user has **passwordless `sudo`** (for a usable dev box). Therefore
**every in-container guardrail below is bypassable by the agent itself** (`sudo`,
`--no-verify`, calling the real binary directly). In-container controls reduce
**accidents** — the normal case where Claude Code respects the rules it's given.
They are **not a sandbox** against a deliberately adversarial agent.

Real guarantees come from outside the container:
| Concern | Real guarantee (outside) | In-container defense-in-depth (this repo) |
|---|---|---|
| Force-push / rewriting your repos | **Remote branch protection** (GitHub/GitLab) | pre-push hook + Claude deny rules |
| Secrets leaking via env | **Don't put secrets in env** (interactive login) | deny rules on `env`/cred files |
| Agent escaping the box | **No `--privileged`, drop the docker socket, run on an isolated VM** | non-root user, key-only SSH |

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

- **Docker socket = root on the host.** Mounting `/var/run/docker.sock` lets the
  agent start host containers (including privileged ones) — effectively host root.
  It's included because you asked for the Docker CLI. **Remove the `/var/run/docker.sock`
  line in `docker-compose.yml` unless you need it**; the CLI still installs fine,
  it just won't connect. If you need container builds without host access, consider
  a rootless/nested daemon instead.
- **Passwordless sudo.** Convenient, but it defeats the in-container guardrails. If
  your threat model includes an untrusted agent, remove the `sudoers.d/agent` rule in
  the Dockerfile (or restrict it to specific commands) and pre-install everything the
  agent needs at build time.
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
- [ ] Docker socket removed unless genuinely needed
- [ ] Decided whether passwordless sudo is acceptable for your threat model
- [ ] Running on an isolated VM if the work is sensitive
