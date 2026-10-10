#!/usr/bin/env bash
#
# Asserts that the controls the guide builds are in place and enforcing.
#
#     ./verify.sh
#
# Point it at any cluster built from the guide, including one built by hand.
# It sources lib/session.sh first, so the versions, the helpers and the tokens it
# needs are present and the port-forwards are up before anything is asserted.
#
# Every check prints PASS or FAIL with what was expected and what came back, and
# the exit status is the number of failures. A check that cannot be run is a
# failure, not a skip: a control nobody could test is not a control anybody
# should rely on.
#
# There is no `set -e` here on purpose. A verify run reports on every check,
# including the ones after the first failure, which is the difference between
# "the budget is not enforcing" and "something went wrong somewhere".
#
# Costs money. Five of these checks reach the provider, one of them for 500
# output tokens. The count is reported at the end.
#
# Three things this deliberately does not assert, each because the assertion
# would be wrong rather than merely fragile:
#
#   Masking on a streamed response. On v2026.7.1 `Mask` does not apply to a
#   stream, only `Reject` does, so a streamed body with an unmasked address in
#   it is correct behaviour and asserting otherwise would fail a working
#   gateway. 8.4 in the guide covers what streaming does and does not get.
#
#   The model total in the catalog log line. `models=` moves whenever the
#   shipped catalog changes, and it changes without you doing anything.
#   `count=2` is the stable fact: your ConfigMap plus the shipped default.
#
#   Anything using a token fetched at the top of the run. The reference realm's
#   access token lifespan is short, so tokens are fetched immediately before the
#   request that uses them. An expired token turns a 403 assertion into a 401,
#   which reads as an authorization bug that is not there.

set -u

self=${0##*/}
here=$(cd -- "$(dirname -- "$0")" && pwd)

passed=0
failed=0
provider_calls=0

# Overridable so the failure path can be exercised against something that
# answers wrongly on purpose, and so a forward on a different local port can be
# pointed at without editing this file.
GW=${VERIFY_GW:-http://localhost:8081}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

# One line per check. A failure repeats the actual value in full underneath,
# because the column is truncated and the full value is the thing you need.
_report() {
  local outcome=$1 name=$2 want=$3 got=$4 full=${5:-}
  local shown=$got
  # An empty actual is the case the guide warns about: a dead port-forward and a
  # masked value both come back as nothing, so nothing has to be visible.
  [ -z "$shown" ] && shown='(empty)'
  [ ${#shown} -gt 34 ] && shown="${shown:0:31}..."

  # PASS and FAIL are both four characters wide, so colouring the word cannot
  # move the columns after it. Padding a coloured token with %-Ns would: printf
  # counts the escape bytes and they take no width on screen.
  local token=$outcome
  case $outcome in
    PASS) token="${SESSION_GREEN:-}PASS${SESSION_RESET:-}" ;;
    FAIL) token="${SESSION_RED:-}FAIL${SESSION_RESET:-}" ;;
  esac

  printf '%s  %-44s expected %-22s actual %s\n' "$token" "$name" "$want" "$shown"
  if [ "$outcome" = FAIL ] && [ -n "$full" ]; then
    printf '      actual in full: %s\n' "$full"
  fi
}

check_eq() {
  local name=$1 want=$2 got=$3
  local flat
  flat=$(printf '%s' "$got" | tr '\n' ' ')
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    _report PASS "$name" "$want" "$flat"
  else
    failed=$((failed + 1))
    _report FAIL "$name" "$want" "$flat" "$flat"
  fi
}

check_contains() {
  local name=$1 needle=$2 haystack=$3
  local flat
  flat=$(printf '%s' "$haystack" | tr '\n' ' ')
  case $haystack in
    *"$needle"*)
      passed=$((passed + 1))
      _report PASS "$name" "contains $needle" "$flat"
      ;;
    *)
      failed=$((failed + 1))
      _report FAIL "$name" "contains $needle" "$flat" "$flat"
      ;;
  esac
}

die() {
  echo >&2
  echo "$self: $*" >&2
  echo "$self: nothing was asserted." >&2
  exit 2
}

# --------------------------------------------------------------------------
# Requests
# --------------------------------------------------------------------------

body_for() { # body_for <model> <prompt> [extra json]
  printf '{"model":"%s","messages":[{"role":"user","content":"%s"}]%s}' \
    "$1" "$2" "${3:-}"
}

status_of() { # status_of <path> <json> [header...]
  local path=$1 json=$2
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' --max-time 120 \
    "$GW$path" -H "Content-Type: application/json" "$@" -d "$json" 2>/dev/null
}

body_of() { # body_of <path> <json> [header...]
  local path=$1 json=$2
  shift 2
  curl -sS --max-time 120 \
    "$GW$path" -H "Content-Type: application/json" "$@" -d "$json" 2>/dev/null
}

# --------------------------------------------------------------------------
# Session
# --------------------------------------------------------------------------

[ -f "$here/lib/session.sh" ] || die "not found: $here/lib/session.sh"

# shellcheck source=lib/session.sh
. "$here/lib/session.sh"
session_status=$?

if [ "$session_status" -ne 0 ]; then
  die "lib/session.sh could not put this shell in a state worth asserting against.
  What failed is above. A request through a port-forward that is not up returns
  nothing, and nothing looks the same as a masked value or a clean pass."
fi

NS=$SESSION_FORWARD_NS
MODEL=${LLM_PRIMARY_MODEL:-}
[ -n "$MODEL" ] ||
  die "LLM_PRIMARY_MODEL is not set, so the guide's environment setup block did not run."

echo
echo "preconditions:"

kubectl get deployment agentgateway-proxy -n "$NS" >/dev/null 2>&1 ||
  die "no agentgateway-proxy deployment in $NS. Build the environment with ./up.sh first."
printf '  proxy deployment present in %s\n' "$NS"

# A token that came back empty or null makes every 200 into a 401 and every 403
# into a 401, so it is settled before anything is asserted rather than after.
probe_token=$(get_token dev 2>/dev/null)
case $probe_token in
  ''|null) die "get_token dev returned '${probe_token:-empty}'. Is Keycloak deployed in ${SESSION_KEYCLOAK_NS} and forwarded on localhost:${SESSION_KEYCLOAK_PORT}?" ;;
  *.*.*)   printf '  get_token returns a three part token\n' ;;
  *)       die "get_token dev did not return a JWT: ${probe_token:0:40}" ;;
esac

echo
echo "assertions:"

# --------------------------------------------------------------------------
# Authentication: every route is covered, including the ones added later
# --------------------------------------------------------------------------

anon_body=$(body_for "$MODEL" "verify: anonymous")
for route in /llm /llm-svc /llm-alias /llm-failover; do
  check_eq "anonymous $route rejected" 401 "$(status_of "$route" "$anon_body")"
done

# --------------------------------------------------------------------------
# Authorization: in the allowed group and not in it
#
# Fetched here rather than at the top. Both tokens are used within seconds of
# being issued, which is what keeps a 403 a 403.
# --------------------------------------------------------------------------

allowed_token=$(get_token dev 2>/dev/null)
denied_token=$(get_token agent 2>/dev/null)
authz_body=$(body_for "$MODEL" "verify: say ok")

provider_calls=$((provider_calls + 1))
check_eq "dev token allowed on /llm" 200 \
  "$(status_of /llm "$authz_body" -H "Authorization: Bearer $allowed_token")"

check_eq "agent token denied on /llm" 403 \
  "$(status_of /llm "$authz_body" -H "Authorization: Bearer $denied_token")"

# --------------------------------------------------------------------------
# Guardrails
# --------------------------------------------------------------------------

# Rejected on the request side, so the provider is never called.
allowed_token=$(get_token dev 2>/dev/null)
ssn_body=$(body_for "$MODEL" "verify: my social security number is 123-45-6789")
check_eq "prompt containing an SSN rejected" 400 \
  "$(status_of /llm "$ssn_body" -H "Authorization: Bearer $allowed_token")"

# Masked on the response side, which costs a provider call because the content
# has to be generated before it can be redacted. Buffered, not streamed: see the
# note at the top of this file.
allowed_token=$(get_token dev 2>/dev/null)
email_body=$(body_for "$MODEL" \
  "Reply with exactly this line and nothing else: contact us at support@example.com")
provider_calls=$((provider_calls + 1))
email_out=$(body_of /llm "$email_body" -H "Authorization: Bearer $allowed_token" |
  jq -r '.choices[0].message.content // "no content in response"' 2>/dev/null)
check_contains "email in a buffered response is masked" '<EMAIL_ADDRESS>' "$email_out"

# --------------------------------------------------------------------------
# Virtual keys: the credential the machine route wants, and the one it does not
# --------------------------------------------------------------------------

ci_key=$(kubectl get secret llm-virtual-keys -n "$NS" \
  -o jsonpath='{.data.ci-pipeline}' 2>/dev/null | base64 -d 2>/dev/null |
  jq -r '.key // empty' 2>/dev/null)

if [ -z "$ci_key" ]; then
  failed=$((failed + 2))
  _report FAIL "virtual key accepted on /llm-svc" 200 "no key in llm-virtual-keys" \
    "could not read .data.ci-pipeline from secret llm-virtual-keys in $NS"
  _report FAIL "virtual key rejected as a bearer token" 401 "no key in llm-virtual-keys"
else
  svc_body=$(body_for "$MODEL" "verify: machine caller")
  provider_calls=$((provider_calls + 1))
  check_eq "virtual key accepted on /llm-svc" 200 \
    "$(status_of /llm-svc "$svc_body" -H "x-api-key: $ci_key")"

  # The same key as a bearer token is not an alternative credential. 13.3 is
  # explicit that this is not an OR.
  check_eq "virtual key rejected as a bearer token" 401 \
    "$(status_of /llm-svc "$svc_body" -H "Authorization: Bearer $ci_key")"
fi

# --------------------------------------------------------------------------
# Request field ceiling: what the caller asked for is not what the provider got
# --------------------------------------------------------------------------

allowed_token=$(get_token dev 2>/dev/null)
ceiling_body=$(body_for "$MODEL" \
  "Write a detailed technical explanation of how TCP congestion control works, covering slow start, congestion avoidance, fast retransmit and fast recovery, in at least 2000 words." \
  ',"max_tokens":5000')
provider_calls=$((provider_calls + 1))
ceiling_out=$(body_of /llm "$ceiling_body" -H "Authorization: Bearer $allowed_token")

check_eq "max_tokens 5000 capped to 500" 500 \
  "$(printf '%s' "$ceiling_out" | jq -r '.usage.completion_tokens // "absent"' 2>/dev/null)"
check_eq "capped response stops for length" length \
  "$(printf '%s' "$ceiling_out" | jq -r '.choices[0].finish_reason // "absent"' 2>/dev/null)"

# --------------------------------------------------------------------------
# Budget: accepted is not enforcing, so both are asserted
# --------------------------------------------------------------------------

budget_json=$(kubectl get eagbud llm-budgets -n "$NS" -o json 2>/dev/null)

check_eq "budget llm-budgets accepted" True \
  "$(printf '%s' "$budget_json" |
     jq -r '.status.conditions[]? | select(.type=="Accepted") | .status' 2>/dev/null |
     head -1 | grep . || echo absent)"

check_eq "budget llm-budgets enforced" True \
  "$(printf '%s' "$budget_json" |
     jq -r '.status.conditions[]? | select(.type=="Enforced") | .status' 2>/dev/null |
     head -1 | grep . || echo absent)"

# --------------------------------------------------------------------------
# Cost catalog: the file count, not the model count. See the note at the top.
# --------------------------------------------------------------------------

catalog_line=$(kubectl logs deployment/agentgateway-proxy -n "$NS" 2>/dev/null |
  grep 'watching model catalog files' | tail -1)

check_contains "proxy is watching two catalog files" 'count=2' \
  "${catalog_line:-no catalog line in the proxy log}"

# --------------------------------------------------------------------------
# Aliasing: a name the provider has never heard of resolves to a model it has
# --------------------------------------------------------------------------

allowed_token=$(get_token dev 2>/dev/null)
alias_body=$(body_for acme-chat "verify: say ok")
provider_calls=$((provider_calls + 1))
check_eq "acme-chat on /llm-alias resolves" "$MODEL" \
  "$(body_of /llm-alias "$alias_body" -H "Authorization: Bearer $allowed_token" |
     jq -r '.model // "absent"' 2>/dev/null)"

# --------------------------------------------------------------------------

total=$((passed + failed))
echo
printf '%s of %s checks passed. %s of them bill the provider when the gateway is up.\n' \
  "$passed" "$total" "$provider_calls"

if [ "$failed" -eq 0 ]; then
  echo "${SESSION_GREEN:-}Every control asserted here is in place and enforcing.${SESSION_RESET:-}"
else
  echo
  echo "${SESSION_RED:-}A failure here is a finding about the environment, not about this script.${SESSION_RESET:-}"
  echo "Check the control by hand before changing an assertion: an assertion"
  echo "loosened to pass is worse than no assertion."
fi

exit "$failed"
