#!/usr/bin/env bash
#
# Checks that a build can work, shows you what it would build against, and asks
# before anything is created.
#
# Usage:
#   ./preflight.sh              check, then confirm
#   ./preflight.sh --approve    check, and do not ask
#   ./preflight.sh --guide <f>  check against a different guide
#
# It runs on its own, and up.sh runs it before the first block and refuses to
# start if it fails. Failing here costs a correction. Failing halfway through a
# build costs a teardown.
#
# Every check names the fix rather than the symptom. A check that says something
# is wrong without saying what to do about it has moved the work, not done it.
#
# Nothing here changes anything: no resource is created, no port-forward is
# started, no credential is written anywhere. It reads, and it asks.
#
# One of these deserves its reasoning stated, because the obvious version
# passes while the thing it checks is broken:
#
#   A kubeconfig with a current context in it proves nothing. The context can
#   name a cluster that is gone, and every kubectl in the build then fails one at
#   a time, a hundred blocks deep. `kubectl get --raw /healthz` asks the
#   apiserver itself, which is the only thing that can answer for it.
#
# Keycloak is not checked here. The guide deploys it into the cluster in Step
# 6.1, so before a build there is nothing to check, and a check that fails on
# every clean cluster is not a precondition. Whether a token comes back is
# checked where it can be: waits.sh, after the block that forwards it.
#
# Exit status:
#   0  every check passed, and you approved
#   1  a check failed
#   2  bad arguments, or a guide that cannot be read
#   3  you aborted at the prompt

set -u

self=${0##*/}
here=$(cd -- "$(dirname -- "$0")" && pwd)

# Resolved from this script's directory, not the working one.
SESSION=$here/lib/session.sh

approve=false
GUIDE_OVERRIDE=""

passed=0
failed=0
fixes=""

die() {
  echo "$self: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --approve) approve=true ;;
    --guide)
      shift
      [ $# -gt 0 ] || die "--guide needs a file"
      GUIDE_OVERRIDE=$1
      ;;
    --dry-run)
      die "there is no --dry-run here: this script changes nothing as it is."
      ;;
    -h|--help)
      sed -n '3,39p' "$0" | cut -c 3-
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -f "$SESSION" ] || die "not found: $SESSION"

SESSION_DEFS_ONLY=1
# shellcheck source=session.sh
. "$SESSION"

[ -z "$GUIDE_OVERRIDE" ] || SESSION_GUIDE=$GUIDE_OVERRIDE
[ -f "$SESSION_GUIDE" ] || die "no such guide: $SESSION_GUIDE"

# Output from the guide's blocks is captured to files rather than through $( ),
# because a command substitution runs in a subshell and the exports those blocks
# exist to make would not survive it.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------
# Reporting
#
# One line per check, in the same glyph column up.sh uses. A failure is followed
# by its fix, and the fixes are collected so a long run does not make you scroll
# back through the output to find them.
# --------------------------------------------------------------------------

ok_check() {
  passed=$((passed + 1))
  printf '%s %s\n' "${SESSION_GLYPH_OK:-[ok]}" "$1"
}

# no_check <what is wrong> <the fix, one or more lines>
no_check() {
  local what=$1 fix=$2 line
  failed=$((failed + 1))
  printf '%s %s\n' "${SESSION_GLYPH_FAIL:-[FAIL]}" "$what"
  printf '%s\n' "$fix" | while IFS= read -r line; do
    [ -n "$line" ] && printf '       %s\n' "$line"
  done
  fixes="$fixes  $what
$(printf '%s\n' "$fix" | sed 's/^/       /')
"
}

echo "checks:"

# --------------------------------------------------------------------------
# 1. Tools
# --------------------------------------------------------------------------

tools_missing=""
for tool in kubectl helm jq curl; do
  command -v "$tool" >/dev/null 2>&1 || tools_missing="$tools_missing $tool"
done

if [ -z "$tools_missing" ]; then
  ok_check "kubectl, helm, jq and curl are on PATH"
else
  no_check "not on PATH:$tools_missing" \
"install them. On macOS: brew install$tools_missing"
fi

# --------------------------------------------------------------------------
# 2. A cluster that answers, not a kubeconfig that mentions one
#
# Two guards on one kubectl call, both learned the hard way. --request-timeout,
# because the unbounded form leaves kubectl retrying an apiserver that is not
# listening. And </dev/null, because a kubeconfig whose user has no credentials
# makes kubectl prompt for a username: it then waits on stdin forever, and a
# preflight that hangs has failed at the one thing it exists to do quickly.
# --------------------------------------------------------------------------

context=$(session_kube_context)
apiserver=$(session_kube_apiserver)

if [ -z "$context" ]; then
  no_check "no current kubectl context" \
"kubectl config get-contexts, then kubectl config use-context <name>.
For the lab, kind create cluster makes one and selects it."
elif ! kubectl get --raw /healthz --request-timeout=10s </dev/null >"$tmp/healthz" 2>&1; then
  no_check "the apiserver behind context $context does not answer" \
"the context exists and the cluster behind it does not. Start it, or switch.
kubectl get --raw /healthz --request-timeout=10s said:
$(tr '\n' ' ' <"$tmp/healthz" | cut -c1-100)"
elif [ "$(cat "$tmp/healthz")" != ok ]; then
  no_check "the apiserver behind context $context answered $(cat "$tmp/healthz"), not ok" \
"the cluster is up and not healthy.
kubectl get --raw '/readyz?verbose' lists which check is failing."
else
  ok_check "apiserver behind context $context answers /healthz with ok"
fi

# --------------------------------------------------------------------------
# 3. The guide's environment, then your credentials over its placeholders
#
# The environment block has to run before the ports can be checked: the
# Keycloak port comes from KEYCLOAK_LOCAL_PORT in it.
# --------------------------------------------------------------------------

session_snapshot_credentials

if session_eval_block "$SESSION_ENV_BLOCK" >"$tmp/env.out" 2>&1; then
  ok_check "the guide's environment setup block evaluates, ${AGENT_GATEWAY_VERSION:-no version} pinned"
else
  no_check "the guide's environment setup block does not evaluate" \
"./up.sh --dry-run names the line. An unquoted <placeholder> is the usual
cause: bash reads < and > as redirections, so the assignment is a syntax error.
$(tr '\n' ' ' <"$tmp/env.out" | cut -c1-100)"
fi

# Resolved in a subshell on purpose: the table is wanted, the exported values are
# not. Nothing here needs a credential, and not holding one is the safer default.
cred_table=""
if cred_table=$(session_apply_credentials 2>&1); then
  ok_check "all three credentials resolve"
else
  no_check "a credential is missing, or set in two places at once" \
"$(printf '%s' "$cred_table" | grep -vE '^ *$|^credentials:$' | tail -4)"
fi

# --------------------------------------------------------------------------
# 4. Ports
#
# Free is fine, and a forward that answers is fine. Everything else is either a
# port the build cannot bind or one that answers as something other than the
# gateway, and the second is worse: it looks like it works.
# --------------------------------------------------------------------------

for port in $(printf '%s' "$SESSION_PORTS"); do
  port_ns=$(session_port_ns "$port")
  state=$(session_port_state "$port" "$(session_port_path "$port")")
  holder=other
  [ -n "$(session_port_forward_pids "$port")" ] && holder=forward

  case "$state:$holder" in
    free:*)
      ok_check "port $port is free"
      ;;
    answering:forward)
      ok_check "port $port is held by a forward, and it answers"
      ;;
    answering:other)
      no_check "port $port answers, but not through a forward for $port_ns" \
"something else is serving that port. Stop it, or change the ports
consistently, which the guide's port table covers.
lsof -nP -iTCP:$port -sTCP:LISTEN names what holds it."
      ;;
    blocked:forward)
      no_check "port $port is held by a forward that does not answer" \
"a forward outlives the pod it points at, and keeps the port while it does.
. auto-build/lib/session.sh replaces it, or
pkill -f 'kubectl port-forward.*$port_ns'"
      ;;
    blocked:other)
      no_check "port $port is held by something that is not a forward, and it does not answer" \
"stop whatever holds it. lsof -nP -iTCP:$port -sTCP:LISTEN names it."
      ;;
  esac
done

# --------------------------------------------------------------------------
# The verdict
# --------------------------------------------------------------------------

echo
if [ "$failed" -gt 0 ]; then
  printf '%s%s of %s checks failed.%s\n' \
    "${SESSION_RED:-}" "$failed" "$((passed + failed))" "${SESSION_RESET:-}"
  echo
  echo "fixes:"
  printf '%s' "$fixes"
  echo "Nothing was built, and nothing on the cluster was changed."
  exit 1
fi

printf '%s%s checks passed.%s\n' \
  "${SESSION_GREEN:-}" "$passed" "${SESSION_RESET:-}"

# --------------------------------------------------------------------------
# What it would act on, then the question
# --------------------------------------------------------------------------

echo
echo "this would build against:"
printf '  context     %s%s%s\n' "${SESSION_BOLD:-}" "$context" "${SESSION_RESET:-}"
printf '  apiserver   %s\n' "${apiserver:-unknown}"
printf '  namespace   %s\n' "$SESSION_FORWARD_NS"
printf '  guide       %s\n' "${SESSION_GUIDE##*/}"
printf '  keycloak    deployed by the guide in Step 6.1, realm %s\n' "${KEYCLOAK_REALM:-unset}"
echo
echo "  credentials, by where they came from and how long they are. No value is"
echo "  printed here, or anywhere else in these scripts:"
# %s\n, not %s: the table came from a command substitution, which strips the
# trailing newline, and without it the next line lands on the end of this one.
printf '%s\n' "$cred_table" | sed -n 's/^  \([A-Z]\)/    \1/p'

if ! session_confirm "$approve" "build against $context"; then
  exit 3
fi
