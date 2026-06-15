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
2. **No host reach, no privileged container.** The host Docker socket is **not**
   mounted. Docker runs in a **rootless** dind sidecar (no `privileged: true`), so
   the agent can't touch the host daemon, and even a container escape from dind
   lands as an unprivileged, user-namespaced user — not host root. This is what
   makes it acceptable to run **on the same host as production apps**.

In-container controls still primarily prevent **accidents**. The hard guarantees
for your two stated concerns come from **outside** the container:

| Concern | Real guarantee (outside) | In-container defense-in-depth (this repo) |
|---|---|---|
| Force-push / rewriting your repos | **Remote branch protection** (GitHub/GitLab) | pre-push hook + Claude deny rules |
| Secrets leaking via env | **Don't put secrets in env** (interactive login) | deny rules on `env`/cred files |
| Agent reaching the host / prod | **Rootless dind (no host socket, no privileged)** | scoped sudo, non-root user, key-only SSH |

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

- **Docker = ROOTLESS dind, not the host.** The `docker` CLI points at a separate
  `docker:dind-rootless` sidecar (`DOCKER_HOST=tcp://docker:2375`) on a private
  network with no published port (2375 is unreachable from host/internet). It runs
  **without `privileged`** — the daemon and every container it spawns are an
  unprivileged, user-namespaced user. The agent builds *and* runs containers there;
  it **cannot** see the host daemon or your other Dokploy apps, and an escape from
  dind does not yield host root. This is why it's acceptable next to production.
  - **Requirements:** host kernel with **cgroup v2** (Ubuntu 22.04+/recent Debian —
    Dokploy hosts usually qualify) and `/dev/fuse` for the fuse-overlayfs storage
    driver (remove the `devices:` line if absent; it'll fall back, slower).
  - **`seccomp=unconfined` + `apparmor=unconfined`** on the dind sidecar are needed
    so it can create nested user namespaces. They relax that one container's syscall
    filtering, but because it's rootless the worst case is a non-root mapped user —
    still far weaker than the privileged daemon they replace.
  - **Residual risk (be honest):** rootless dind + relaxed seccomp is *not* zero risk
    next to prod — userns escapes are rare but not impossible. The strongest posture
    is still a dedicated VM. This config is the best balance given you need build+run
    on a shared host.
  - To drop Docker entirely: delete the `docker` service + `DOCKER_HOST` env.
- **Image builds require confirmation.** `docker build`/`buildx`/`compose build`/`push`
  are in the managed-settings `ask` list, so the agent must get an interactive
  approval (you build images manually / on demand, not silently).
- **Scoped sudo (not blanket root).** `sudoers.d/agent` allows only package commands.
  This stops casual escalation, but note `sudo apt-get` can run root package scripts —
  for maximum lockdown, remove the sudoers file and pre-install everything at build time.
- **Cloud-metadata theft — mitigated.** The entrypoint installs blackhole routes to
  the cloud instance-metadata IPs (`169.254.169.254`, `169.254.170.2`, `100.100.100.200`,
  IPv6 `fd00:ec2::254`) so the agent can't pull the host's IAM/cloud credentials. This
  needs the `NET_ADMIN` cap (granted in compose); the route is set by root at boot and
  the non-root agent can't remove it (`ip` isn't in its sudo allowlist).
  - **Gap (be honest):** this protects the **workspace** container. Containers the agent
    spins up *inside dind* egress through dind's own network stack and are **not** covered
    by the workspace's routes. To cover everything, add the host-firewall rule below.
  - **Complete coverage (host, optional but recommended on a cloud VM):** scope a drop to
    the agent's containers so you don't break prod's legitimate metadata use:
    ```bash
    # On the Docker host. Find the workspace/dind bridge subnet first:
    #   docker network inspect <stack>_default <stack>_dind | grep Subnet
    iptables  -I DOCKER-USER -s <those-subnets> -d 169.254.169.254 -j DROP
    iptables  -I DOCKER-USER -s <those-subnets> -d 169.254.170.2   -j DROP
    ip6tables -I DOCKER-USER -s <those-subnet6> -d fd00:ec2::254   -j DROP 2>/dev/null || true
    ```
    A blanket (no `-s`) rule blocks metadata for **all** containers including prod — only
    do that if no prod app relies on instance IAM. On AWS also enforce IMDSv2 + hop-limit 1.
- **Network reach (important on a shared host).** Docker keeps the workspace off your
  other apps' networks, so the agent can't directly dial prod containers by name. But
  it **can** reach (a) anything your prod apps publish on the host's ports, and (b) the
  host gateway IP. If a prod DB/admin port is published on `0.0.0.0`, the agent could
  hit it. Mitigations: bind prod published ports to `127.0.0.1` (not `0.0.0.0`), keep
  prod service-to-service traffic on internal Docker networks (unpublished), and/or add
  host-firewall rules blocking the workspace's subnet from prod ports.
- **code-server auth.** Always set `CODE_SERVER_PASSWORD` (or front it with Dokploy
  auth) and serve it only over HTTPS. `--auth none` + public domain = open shell.
- **SSH.** Key-only by default (`SSH_PASSWORD` empty), root login disabled. Keep it
  that way; rotate the published port off 22 if exposed to the internet.
- **Base image CVEs.** `node:22-bookworm` carries OS-level CVEs over time. Rebuild
  regularly to pull patches; pin to a digest for reproducibility if you need it.

## Running on a shared host with production (your setup)

You've chosen to run this next to prod on the same Dokploy host. The rootless-dind
config above removes the biggest danger (no privileged container, no host socket).
Do these in addition:

1. **Smoke-test the rootless daemon on your host before trusting it:**
   ```bash
   # after deploy, from inside the workspace (ssh in):
   docker info            # should report the rootless daemon, no errors
   docker run --rm hello-world
   docker build -t test - <<<'FROM alpine
   RUN echo ok'
   ```
   If `docker info` errors about cgroups, your host isn't cgroup-v2 / lacks
   delegation — tell me and we'll switch the storage/cgroup settings.
2. **Cap resources** so a runaway agent can't starve prod — add to the `workspace`
   and `docker` services in compose (or set in Dokploy's UI):
   ```yaml
   deploy:
     resources:
       limits: { cpus: "2", memory: 4g }
   ```
3. **Don't publish prod internal ports on `0.0.0.0`** — see the network note above.
4. **Least-privilege git token** for the agent — never your full-access PAT.
5. Accept the residual risk: rootless dind is much safer than privileged but not a
   hard VM boundary. If a future task is highly sensitive, move *that* work to a
   throwaway VM.

## Quick hardening checklist
- [ ] Branch protection enabled on every remote the agent can push to
- [ ] Agent's git token scoped to least privilege (PR-only if possible)
- [ ] `ANTHROPIC_API_KEY` not in env (interactive login or `apiKeyHelper`)
- [ ] `CODE_SERVER_PASSWORD` set, domain on HTTPS
- [ ] SSH key-only, sensible published port
- [ ] Rootless dind smoke-tested (`docker info` / `docker run hello-world`)
- [ ] CPU/memory limits set on workspace + docker services
- [ ] Prod published ports bound to 127.0.0.1, not 0.0.0.0
- [ ] Cloud-metadata blocked — verify `curl -m2 http://169.254.169.254/` from the
      workspace times out; add the host-firewall rule to also cover dind containers
- [ ] Docker via isolated dind (default) — host socket NOT mounted
- [ ] Sudo is scoped (default), or removed entirely for maximum lockdown
- [ ] Running on a dedicated VM if the work is sensitive (dind is privileged)
