#!/usr/bin/env bash
#
# Puts the current shell into the state the guide assumes, without running the
# guide. Sourced, never executed:
#
#     . auto-build/lib/session.sh        from the repo root
#     . ./lib/session.sh                  from auto-build/
#
# It evaluates the guide's environment setup block and its helper-function
# blocks into your shell, applies your credentials over the placeholders that
# block sets, and makes sure the three port-forwards are up. After it, the
# guide's commands work when pasted, `get_token dev` returns a token, and
# `curl http://localhost:8081/llm` reaches the gateway.
#
# This is also where up.sh and verify.sh get that logic. up.sh sources this file
# for the credential and port-forward code so there is one implementation rather
# than two that drift; verify.sh should source it plainly, which leaves it in a
# session it can assert against.
#
# What it defines, all safe to call again:
#
#   session_up                 all of the below, in order. Sourcing runs this.
#   session_env                evaluate the environment setup block
#   session_helpers            evaluate the blocks that define forwards(),
#                              get_token() and decode_jwt()
#   session_apply_credentials  your values over the guide's placeholders
#   session_forwards           ensure 8081, 15020 and 4000
#   session_kill_forwards <fd> close every forward for the namespace
#   session_port_state <port> <path>
#                              prints free, answering, or blocked
#
# Set SESSION_DEFS_ONLY=1 before sourcing to define the functions and do
# nothing, which is what up.sh does.
#
# Nothing here sets a shell option, installs a trap, or calls exit. A sourced
# file that does any of those changes the shell you are working in, and `exit`
# in one closes your terminal. Errors are reported and returned.

# Finding our own directory differs by shell: zsh sets $0 to the sourced file,
# bash keeps the shell's name there and puts the file in BASH_SOURCE.
if [ -n "${ZSH_VERSION:-}" ]; then
  SESSION_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
else
  SESSION_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi

SESSION_EXTRACT=${SESSION_EXTRACT:-$SESSION_DIR/extract.sh}
SESSION_GUIDE=${SESSION_GUIDE:-$SESSION_DIR/../../docs/deployment-guide-keycloak.md}

# UP_ENV_FILE is honoured so a fixture run can point at a throwaway file.
SESSION_ENV_FILE=${UP_ENV_FILE:-$SESSION_DIR/../.env.local}

# The block that pins versions and sets the credential placeholders.
SESSION_ENV_BLOCK=environment-setup-env

# The blocks that only define shell helpers later blocks and later steps call.
# Not 12.2's traffic generator: it defines send_traffic() and then calls it five
# times against your provider.
SESSION_HELPER_BLOCKS="ports-used-in-this-guide
6-2-get-two-tokens-and-look-at
6-2-get-two-tokens-and-look-at-2"

# The one helper block that both defines get_token and calls it. preflight
# checks Keycloak by evaluating this rather than by reimplementing the fetch: a
# check that does not use the guide's own code is checking something else.
SESSION_TOKEN_BLOCK=6-2-get-two-tokens-and-look-at

SESSION_CREDENTIALS="AGENTGATEWAY_LICENSE_KEY ANTHROPIC_API_KEY OPENAI_API_KEY"

# The namespace whose port-forwards these scripts may close, and the pattern
# they are matched with. The pattern is the guide's own, from the forwards()
# helper in Environment setup. Scoped to the namespace: it will close a forward
# against agentgateway-system and nothing pointing anywhere else.
SESSION_FORWARD_NS=agentgateway-system
SESSION_FORWARD_PATTERN="kubectl port-forward.*$SESSION_FORWARD_NS"

# --------------------------------------------------------------------------
# Colour and status glyphs
#
# On only when stdout is a terminal and NO_COLOR is unset. A file or a CI job
# gets plain text, and the glyphs become [ok] and [FAIL] there, because a log
# full of coloured circles is harder to read afterwards than words are.
#
# NO_COLOR counts when it is set to anything non-empty, which is what the
# convention asks for: the value is not a setting, its presence is.
#
# Both glyphs are padded here to the same display width within each mode, so a
# column printed after one lines up with a column printed after the other. That
# padding cannot be left to a `%-6s` in the caller: printf counts bytes, the
# escape codes are bytes, and they take no width on screen, so a padded coloured
# token comes out narrow by exactly the length of the escapes.
#
# The glyph is U+25CF rather than an emoji circle. Emoji are two cells wide in
# some terminals and one in others, which moves every column after them.
# --------------------------------------------------------------------------

SESSION_COLOR=false
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  SESSION_COLOR=true
fi

if $SESSION_COLOR; then
  SESSION_GREEN=$(printf '\033[32m')
  SESSION_RED=$(printf '\033[31m')
  SESSION_BOLD=$(printf '\033[1m')
  SESSION_RESET=$(printf '\033[0m')
  SESSION_GLYPH_OK="${SESSION_GREEN}●${SESSION_RESET}"
  SESSION_GLYPH_FAIL="${SESSION_RED}✗${SESSION_RESET}"
  # For a line that is neither: down.sh has four kinds, and only two of them are
  # an outcome. Same width as the other two so the column holds.
  SESSION_GLYPH_NONE=" "
else
  SESSION_GREEN=""
  SESSION_RED=""
  SESSION_BOLD=""
  SESSION_RESET=""
  SESSION_GLYPH_OK="[ok]  "
  SESSION_GLYPH_FAIL="[FAIL]"
  SESSION_GLYPH_NONE="      "
fi

# Local ports the guide uses, and how long to wait for a new forward to answer.
SESSION_PORTS=${SESSION_PORTS:-"8081 15020 4000"}
SESSION_FORWARD_TIMEOUT=${SESSION_FORWARD_TIMEOUT:-15}

# --------------------------------------------------------------------------
# The cluster this would act on, and asking first
# --------------------------------------------------------------------------

session_kube_context() {
  kubectl config current-context 2>/dev/null
}

# The address behind the context, not the context name. A context called
# `kind-kind` pointed at something else is exactly the mistake worth catching
# before anything is created or removed.
session_kube_apiserver() {
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
}

# session_confirm <approved> <action>
#
# Enter proceeds, anything else aborts. Asked only when stdin is a terminal and
# approval was not given: a pipeline has nobody to ask, and stopping to wait for
# an answer that cannot come is how a script hangs in CI.
session_confirm() {
  local approved=${1:-false} action=${2:-continue} reply

  if [ "$approved" = true ]; then
    printf '%sApproved with --approve.%s\n' "${SESSION_GREEN:-}" "${SESSION_RESET:-}"
    return 0
  fi

  if [ ! -t 0 ]; then
    printf 'stdin is not a terminal, so nothing was asked. Proceeding.\n'
    return 0
  fi

  printf '\nPress Enter to %s, anything else to abort: ' "$action"
  if ! IFS= read -r reply; then
    printf '\nNo answer. Aborted, nothing was changed.\n'
    return 1
  fi

  if [ -n "$reply" ]; then
    printf '%sAborted, nothing was changed.%s\n' "${SESSION_RED:-}" "${SESSION_RESET:-}"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Blocks
# --------------------------------------------------------------------------

# Print one block's body, by ID. extract.sh is the only thing that parses the
# guide; this reads its stream.
session_block_body() {
  local id=${1:-}
  if [ -z "$id" ]; then
    echo "session.sh: session_block_body needs a block ID" >&2
    return 2
  fi
  "$SESSION_EXTRACT" "$SESSION_GUIDE" | awk -v want="$id" '
    /^# >>> /{ inside = ($3 == want); next }
    inside { print }
  '
}

# Evaluate a block into the calling shell. Checked with `bash -n` first: a
# syntax error in an eval reaches half the block, and half of an environment
# setup block is worse than none of it.
session_eval_block() {
  local id=${1:-} body
  body=$(session_block_body "$id") || return 1

  if [ -z "$body" ]; then
    echo "session.sh: no block with ID $id in ${SESSION_GUIDE##*/}" >&2
    return 1
  fi

  if ! printf '%s\n' "$body" | bash -n 2>/dev/null; then
    echo "session.sh: block $id is not valid shell, so it was not evaluated." >&2
    echo "session.sh: run auto-build/up.sh --dry-run, which names the line." >&2
    return 1
  fi

  eval "$body"
}

session_env() {
  session_snapshot_credentials
  session_eval_block "$SESSION_ENV_BLOCK" || return 1
  printf 'environment:  %s pinned from %s\n' \
    "${AGENT_GATEWAY_VERSION:-version unset}" "${SESSION_GUIDE##*/}"
}

session_helpers() {
  local id rc=0
  for id in $(printf '%s' "$SESSION_HELPER_BLOCKS"); do
    if session_eval_block "$id"; then
      printf 'helpers:      %s\n' "$id"
    else
      printf 'helpers:      %s FAILED\n' "$id"
      rc=1
    fi
  done

  # get_token returns the string null when the IdP rejects or is unreachable,
  # because jq renders a missing .access_token that way. The export then
  # succeeds and every later request is a 401 that looks like a policy problem.
  case ${ALLOWED_TOKEN:-} in
    ''|null)
      printf 'helpers:      ALLOWED_TOKEN is %s. Is Keycloak up and reachable at %s?\n' \
        "${ALLOWED_TOKEN:-empty}" "${KEYCLOAK_URL:-unset}"
      rc=1
      ;;
  esac

  return $rc
}

# --------------------------------------------------------------------------
# Credentials
#
# Taken before the environment setup block runs, applied after it. The block
# sets placeholders, so the order is what makes versions come from the guide
# and secrets come from you.
# --------------------------------------------------------------------------

session_snapshot_credentials() {
  local v
  for v in $(printf '%s' "$SESSION_CREDENTIALS"); do
    eval "SESSION_AMBIENT_$v=\${$v:-}"
  done
}

session_apply_credentials() {
  local v file_value ambient value origin have_file=false note=""

  # Clear the placeholders rather than writing over them, so a placeholder
  # cannot survive by being mistaken for a value.
  for v in $(printf '%s' "$SESSION_CREDENTIALS"); do
    unset "$v" 2>/dev/null || true
  done

  if [ -f "$SESSION_ENV_FILE" ]; then
    have_file=true
    # shellcheck disable=SC1090
    . "$SESSION_ENV_FILE"
  fi

  printf '\ncredentials:\n'

  for v in $(printf '%s' "$SESSION_CREDENTIALS"); do
    eval "file_value=\${$v:-}"
    eval "ambient=\${SESSION_AMBIENT_$v:-}"

    if $have_file && [ -n "$file_value" ] && [ -n "$ambient" ] &&
       [ "$file_value" != "$ambient" ]; then
      echo "$v is set in ${SESSION_ENV_FILE##*/} and in your environment, to different values." >&2
      echo "  The README says pick one. Which one wins here would otherwise depend" >&2
      echo "  on shell history, so this stops instead. Unset one and try again." >&2
      return 2
    fi

    if [ -n "$file_value" ]; then
      value=$file_value
      origin=${SESSION_ENV_FILE##*/}
    elif [ -n "$ambient" ]; then
      value=$ambient
      origin=environment
    else
      value=""
      origin="not set"
    fi

    # Exported even when empty. Blocks reference these under `set -u`, and an
    # unset variable fails as a shell error rather than as the missing
    # credential it is.
    eval "export $v=\$value"

    case $value in
      *'<'*'>'*)
        origin="$origin (placeholder)"
        value=""
        eval "export $v=''"
        ;;
    esac

    printf '  %-26s %-22s %s\n' "$v" "$origin" \
      "$([ -n "$value" ] && echo "${#value} chars" || echo "-")"
  done

  for v in AGENTGATEWAY_LICENSE_KEY ANTHROPIC_API_KEY; do
    eval "value=\${$v:-}"
    if [ -z "$value" ]; then
      echo "$v is not set. Copy .env.example to .env.local and fill it in, or export it." >&2
      return 2
    fi
  done

  if [ -z "${OPENAI_API_KEY:-}" ]; then
    note="OPENAI_API_KEY is not set. Step 8.3's block policy-llm-guardrails-2 will
  still run and will install a moderation guardrail with no credential, and the
  guide's own note for that step says every request then returns 503. Set the key,
  or tag that block when=manual in the guide."
    printf '\nwarning: %s\n' "$note"
  fi

  return 0
}

# --------------------------------------------------------------------------
# Port-forwards
# --------------------------------------------------------------------------

session_port_target() {
  case ${1:-} in
    8081)  printf 'deployment/agentgateway-proxy 80' ;;
    15020) printf 'deployment/agentgateway-proxy 15020' ;;
    4000)  printf 'service/solo-enterprise-ui 80' ;;
    *)     return 1 ;;
  esac
}

# The path each probe asks for. Any HTTP status counts as answering: what is
# being tested is the tunnel, not the application behind it, and a 404 proves a
# tunnel as well as a 200 does.
session_port_path() {
  case ${1:-} in
    8081)  printf '/' ;;
    15020) printf '/metrics' ;;
    4000)  printf '/age/' ;;
    *)     printf '/' ;;
  esac
}

session_port_label() {
  case ${1:-} in
    8081)  printf 'gateway' ;;
    15020) printf 'metrics' ;;
    4000)  printf 'ui     ' ;;
    *)     printf '?      ' ;;
  esac
}

# free      nothing is listening, so a forward can bind
# answering something is listening and served an HTTP response
# blocked   something is listening and did not answer: the usual case is a
#           forward whose pod was replaced, which keeps the local port open and
#           has nothing at the other end
#
# One curl tells the three apart. Exit 7 is a refused connection, so the port is
# free. Exit 0 with a status line means answering. Anything else connected and
# then failed, which is the case worth acting on.
session_port_state() {
  # Not named `status` or `path`: zsh makes `status` read-only and ties `path`
  # to PATH, so those names work in bash and break, or worse quietly maim the
  # shell, in the zsh a reader is most likely sourcing this from.
  local port=${1:-} probe_path=${2:-/} code curl_status
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
    "http://localhost:${port}${probe_path}" 2>/dev/null)
  curl_status=$?

  if [ "$curl_status" -eq 7 ]; then
    printf 'free'
  elif [ "$curl_status" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
    printf 'answering'
  else
    printf 'blocked'
  fi
}

# The forwards for one local port, rather than for the namespace. The guide
# writes the mapping after the namespace, as `-n agentgateway-system 8081:80`.
session_port_forward_pids() {
  pgrep -f "kubectl port-forward.*$SESSION_FORWARD_NS.*[[:space:]]${1:-}:" 2>/dev/null
}

session_start_forward() {
  local port=${1:-} target remote spec
  spec=$(session_port_target "$port") || return 1
  target=${spec%% *}
  remote=${spec##* }

  kubectl port-forward "$target" -n "$SESSION_FORWARD_NS" "${port}:${remote}" \
    >/dev/null 2>&1 &

  local waited=0 probe_path
  probe_path=$(session_port_path "$port")
  while [ "$waited" -lt "$SESSION_FORWARD_TIMEOUT" ]; do
    if [ "$(session_port_state "$port" "$probe_path")" = answering ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Ensure one port. Leaves a healthy forward alone: replacing one that works
# costs a request in flight and proves nothing.
session_ensure_port() {
  local port=${1:-} probe_path label state pids
  probe_path=$(session_port_path "$port")
  label=$(session_port_label "$port")
  state=$(session_port_state "$port" "$probe_path")

  case $state in
    answering)
      printf '  %-6s %s already up\n' "$port" "$label"
      return 0
      ;;

    free)
      if session_start_forward "$port"; then
        printf '  %-6s %s started\n' "$port" "$label"
        return 0
      fi
      printf '  %-6s %s FAILED to start, nothing answering after %ss\n' \
        "$port" "$label" "$SESSION_FORWARD_TIMEOUT"
      return 1
      ;;

    blocked)
      pids=$(session_port_forward_pids "$port")
      if [ -z "$pids" ]; then
        # A forward whose pod was deleted can exit on the connection the probe
        # just made, which leaves the port blocked a moment ago and free now.
        # Seen with Keycloak after a rollout restart. Look again before calling
        # it someone else's port.
        sleep 1
        if [ "$(session_port_state "$port" "$probe_path")" = free ] &&
           session_start_forward "$port"; then
          printf '  %-6s %s replaced, its forward had exited\n' "$port" "$label"
          return 0
        fi
        # Something is holding the port and it is not a forward for this
        # namespace. Killing it is not this script's business.
        printf '  %-6s %s IN USE by something that is not a forward for %s, left alone\n' \
          "$port" "$label" "$SESSION_FORWARD_NS"
        return 1
      fi

      kill $(printf '%s' "$pids") 2>/dev/null || true
      sleep 1
      if session_start_forward "$port"; then
        printf '  %-6s %s replaced, it was listening but not answering\n' "$port" "$label"
        return 0
      fi
      printf '  %-6s %s FAILED to replace, nothing answering after %ss\n' \
        "$port" "$label" "$SESSION_FORWARD_TIMEOUT"
      return 1
      ;;

    *)
      # Unreachable unless the probe itself broke. A case that falls through
      # returns 0, which would report a port as fine without having looked.
      printf '  %-6s %s UNKNOWN, the probe returned [%s] rather than a state\n' \
        "$port" "$label" "$state"
      return 1
      ;;
  esac
}

session_forwards() {
  local port rc=0
  printf '\nport-forwards:\n'
  for port in $(printf '%s' "$SESSION_PORTS"); do
    session_ensure_port "$port" || rc=1
  done
  return $rc
}

# Close every forward for the namespace, and say how many. This is the blunt
# one, for a runner that wants to start from nothing. Writes to the file
# descriptor given as $1 so a caller can report on stdout or on a saved stderr.
#
# A forward outlives the pod it points at. The old one lingers holding the local
# port, a replacement cannot bind, and requests go to a dead endpoint, so a
# leftover forward is both why the next run fails to bind and why it would read
# nothing if it did.
session_kill_forwards() {
  local fd=${1:-1} n

  n=$(pgrep -f "$SESSION_FORWARD_PATTERN" 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$n" ] || n=0

  if [ "$n" -eq 0 ]; then
    printf 'port-forwards: none left over for %s\n' "$SESSION_FORWARD_NS" >&"$fd"
    return 0
  fi

  pkill -f "$SESSION_FORWARD_PATTERN" 2>/dev/null || true
  # Long enough for the local ports to be released before anything binds them.
  sleep 1
  printf 'port-forwards: closed %s left over for %s\n' "$n" "$SESSION_FORWARD_NS" >&"$fd"
}

# --------------------------------------------------------------------------

session_up() {
  local rc=0

  if [ ! -f "$SESSION_GUIDE" ]; then
    echo "session.sh: no such guide: $SESSION_GUIDE" >&2
    return 2
  fi
  if [ ! -x "$SESSION_EXTRACT" ]; then
    echo "session.sh: not executable: $SESSION_EXTRACT" >&2
    return 2
  fi

  session_env || return 1
  session_apply_credentials || return $?
  session_helpers || rc=1
  session_forwards || rc=1

  echo
  if [ "$rc" -eq 0 ]; then
    echo "Session ready. Guide commands work as written in this shell."
  else
    echo "Session partly ready. What failed is above; nothing else was changed."
  fi
  return $rc
}

if [ "${SESSION_DEFS_ONLY:-}" != 1 ]; then
  session_up
fi
