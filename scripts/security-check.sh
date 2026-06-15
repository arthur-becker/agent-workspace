#!/usr/bin/env bash
# security-check.sh — verify the agent-workspace hardening is actually in place.
#
# Run it INSIDE the container. Several checks are user-specific, so for full
# coverage run it as BOTH accounts:
#   ssh agent@<host> -p <port> security-check
#   ssh admin@<host> -p <port> security-check
# (or pipe this file:  ssh agent@<host> -p <port> 'bash -s' < scripts/security-check.sh)
#
# Exit code: 0 if no FAILs, 1 if any check FAILed. WARNs don't fail the run.
set -uo pipefail

ME="$(id -un 2>/dev/null || echo "?")"
PASS=0; FAIL=0; WARN=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[90m'; Z=$'\033[0m'
else
  G=""; R=""; Y=""; D=""; Z=""
fi
ok() { printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; PASS=$((PASS+1)); }
no() { printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; FAIL=$((FAIL+1)); }
wn() { printf '  %sWARN%s %s\n' "$Y" "$Z" "$1"; WARN=$((WARN+1)); }
sk() { printf '  %sSKIP%s %s\n' "$D" "$Z" "$1"; }
hdr() { printf '\n%s== %s ==%s\n' "$D" "$1" "$Z"; }

printf 'agent-workspace security check — user: %s, host: %s\n' "$ME" "$(hostname 2>/dev/null || echo '?')"

# --- Privilege: agent has no sudo, admin has full sudo -----------------------
hdr "Privilege (sudo)"
case "$ME" in
  agent)
    sudo -n true 2>/dev/null && no "agent CAN sudo (must not)" || ok "agent has no sudo"
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx sudo && no "agent is in the 'sudo' group" || ok "agent not in 'sudo' group" ;;
  admin)
    sudo -n true 2>/dev/null && ok "admin has passwordless sudo" \
      || wn "admin sudo asked for a password (ok only if you intentionally require one)" ;;
  *) sk "sudo checks (run as 'agent' and 'admin' to cover these)" ;;
esac

# --- Docker should be absent -------------------------------------------------
hdr "Docker (should be absent)"
command -v docker >/dev/null 2>&1 \
  && wn "docker CLI present at $(command -v docker) — expected removed" \
  || ok "no docker CLI on PATH"

# --- Secrets in the environment ----------------------------------------------
hdr "Secrets in environment"
SEC=0
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN GITHUB_TOKEN GH_TOKEN; do
  [[ -n "${!v:-}" ]] && { no "$v is set in the environment"; SEC=1; }
done
[[ $SEC -eq 0 ]] && ok "no known secret env vars set"
SUS="$(env 2>/dev/null | grep -ioE '^[A-Z0-9_]*(TOKEN|SECRET|_KEY|PASSWORD|APIKEY)=' | sed 's/=$//' | sort -u | tr '\n' ' ')"
[[ -n "$SUS" ]] && wn "env has vars matching secret-ish names (names only): $SUS"

# --- Git: agent must hold no remote credentials ------------------------------
hdr "Git credentials (agent must have none)"
if [[ "$ME" == "agent" ]]; then
  GC=0
  [[ -f "$HOME/.git-credentials" ]] && { no "~/.git-credentials exists"; GC=1; }
  [[ -f "$HOME/.netrc" ]]          && { no "~/.netrc exists"; GC=1; }
  H="$(git config --get credential.helper 2>/dev/null || true)"
  [[ -n "$H" ]] && { no "git credential.helper is set ('$H')"; GC=1; }
  ls "$HOME"/.ssh/id_* >/dev/null 2>&1 && wn "private SSH key(s) in ~/.ssh — make sure none grant git push"
  [[ $GC -eq 0 ]] && ok "no git credential files/helpers in agent home"
else
  sk "agent credential-file checks (run as 'agent')"
fi
TOKURL="$(find /workspace -maxdepth 5 -path '*/.git/config' 2>/dev/null \
          | xargs -r grep -lE 'url[[:space:]]*=[[:space:]]*https?://[^/@[:space:]]+:[^/@[:space:]]+@' 2>/dev/null || true)"
[[ -n "$TOKURL" ]] && no "embedded token in a remote URL: $TOKURL" || ok "no embedded tokens in /workspace remote URLs"

# --- Claude managed-settings -------------------------------------------------
hdr "Claude managed-settings"
MS=/etc/claude-code/managed-settings.json
if [[ -r "$MS" ]]; then
  ok "managed-settings present and readable"
  for rule in 'Bash(sudo:*)' 'Bash(docker:*)' 'Bash(git push:*)'; do
    grep -qF "\"$rule\"" "$MS" && ok "deny rule present: $rule" || no "deny rule MISSING: $rule"
  done
else
  wn "cannot read $MS (run as admin to verify its contents)"
fi

# --- Git server-side guardrails ----------------------------------------------
hdr "Git guardrails"
HP="$(git config --system --get core.hooksPath 2>/dev/null || true)"
[[ "$HP" == "/etc/git-hooks" ]] && ok "core.hooksPath pinned to /etc/git-hooks" || no "core.hooksPath not system-pinned (got '${HP:-unset}')"
[[ -x /etc/git-hooks/pre-push ]] && ok "pre-push hook installed & executable" || no "pre-push hook missing/not executable"
SD="$(git config --system --get-all safe.directory 2>/dev/null || true)"
printf '%s\n' "$SD" | grep -qx '\*' && no "safe.directory='*' is set system-wide (should NOT be)" || ok "no blanket safe.directory"

# --- Cloud-metadata egress blocked -------------------------------------------
hdr "Cloud-metadata egress"
if curl -fsS -m2 http://169.254.169.254/ >/dev/null 2>&1; then
  no "169.254.169.254 is REACHABLE — cloud metadata NOT blocked"
else
  ok "cloud-metadata 169.254.169.254 unreachable"
fi

# --- Workspace is the agent's private area -----------------------------------
hdr "Workspace ownership"
OWN="$(stat -c '%U' /workspace 2>/dev/null || echo '?')"
[[ "$OWN" == "agent" ]] && ok "/workspace owned by agent" || wn "/workspace owner is '$OWN' (expected agent)"
PERM="$(stat -c '%a' /workspace 2>/dev/null || echo '')"
[[ "$PERM" =~ ^2 ]] && wn "/workspace has the setgid/shared-group bit ($PERM) — expected private (755)" || ok "/workspace not group-shared ($PERM)"

# --- Claude always runs as agent (wrapper) -----------------------------------
hdr "Claude runs as agent"
CW=/usr/local/bin/claude
if [[ -r "$CW" ]] && grep -q 'claude.real' "$CW" 2>/dev/null; then ok "claude is the agent-enforcing wrapper"; else wn "$CW is not the wrapper (or unreadable)"; fi
[[ -e /usr/local/bin/claude.real ]] && ok "claude.real (real CLI) present" || wn "claude.real missing"

# --- SSH ---------------------------------------------------------------------
hdr "SSH"
SC=/etc/ssh/sshd_config
if [[ -r "$SC" ]]; then
  grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]+no' "$SC" && ok "root SSH login disabled" || wn "PermitRootLogin is not 'no'"
else
  sk "sshd_config not readable"
fi

# --- Persistence: globals survive a restart ----------------------------------
hdr "Persistence (deps survive restart)"
is_mount() { grep -q " $1 " /proc/mounts 2>/dev/null; }
is_mount /home/agent && ok "/home/agent is a mounted volume" || wn "/home/agent not a mount — agent config/creds may not persist"
for d in /home/agent/.npm-global /home/agent/.bun /home/agent/.local/share/uv /home/agent/.cache; do
  is_mount "$d" && ok "$d is a dedicated volume" || sk "$d not a dedicated mount (still persists if /home/agent is a volume)"
done

# --- Summary -----------------------------------------------------------------
printf '\n%s========================================%s\n' "$D" "$Z"
printf 'Summary: %sPASS %d%s  %sWARN %d%s  %sFAIL %d%s\n' "$G" "$PASS" "$Z" "$Y" "$WARN" "$Z" "$R" "$FAIL" "$Z"
[[ $FAIL -gt 0 ]] && { printf '%sFAILED — review the FAIL lines above.%s\n' "$R" "$Z"; exit 1; }
printf '%sOK — no failures%s%s\n' "$G" "$Z" "$([[ $WARN -gt 0 ]] && echo ' (some warnings)')"
exit 0
