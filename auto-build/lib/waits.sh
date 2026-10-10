#!/usr/bin/env bash
#
# Readiness conditions, keyed to the block IDs extract.sh emits.
#
# The guide does not contain these. A reader working through it in one terminal
# reads the output of one command before typing the next, so the pause is free.
# A runner has no such pause, and the race it hits is the difference between a
# policy that is enforcing and a policy that was accepted a moment ago.
#
# Sourced, not executed, by a runner:
#
#     . ./lib/waits.sh
#     cmd=$(wait_for "$id") && [ -n "$cmd" ] && eval "$cmd"
#
# The returned string is expanded by the caller, so the helper functions below
# have to be in scope. Nothing here is wired into a runner yet.
#
# Three entry points:
#   wait_for <id>    print the condition for a block ID, or nothing for an ID
#                    with no entry. Exit 0 either way: most block IDs have no
#                    wait, and that is not a failure.
#   has_wait <id>    exit 0 if the ID has an entry, 1 if it does not
#   wait_ids         print every ID the table keys, one per line
#
# Also runnable directly for inspection: --list, --table, --for <id>.
#
# On what these conditions rest, and what they do not:
#
# The conditions here were derived from the guide -- from what each block
# creates, and from status output the guide captured from a live cluster. They
# have not themselves been run against a cluster. Two consequences worth having
# in front of you before you trust one:
#
#   A wait that is missing or too weak fails loudly on the next command, which
#   is the design the README describes. A wait on a condition that never
#   arrives does the opposite: it converts a working step into a timeout, and
#   reads as a broken step. So every entry below waits on a condition this guide
#   has already shown reaching True, and where it could not, there is no entry.
#   The gaps are listed at the end of the table rather than filled with a guess.
#
#   `kubectl wait --for=condition=` reads `.status.conditions` and nothing else.
#   EnterpriseAgentgatewayBudget puts its conditions there, so kubectl wait
#   works on budgets. EnterpriseAgentgatewayPolicy reports against an ancestor,
#   at `.status.ancestors[].conditions`, so kubectl wait cannot see a policy
#   condition at all and the policy waits poll that path instead.

WAITS_NS=${WAITS_NS:-agentgateway-system}
WAITS_TIMEOUT=${WAITS_TIMEOUT:-180}
WAITS_PORT_TIMEOUT=${WAITS_PORT_TIMEOUT:-60}

# No `set -e` here. This file is meant to be sourced, and setting shell options
# in a sourced file changes them for the runner that sourced it.

# --------------------------------------------------------------------------
# The table.
#
# One line per block ID: the ID, then the condition to satisfy after that block
# runs. First field is the ID -- block IDs cannot contain whitespace, so no
# delimiter is needed. Blank lines and `#` lines are ignored, which is what
# makes the deferred entries at the bottom inert.
#
# In document order, so it can be read against the guide.
# --------------------------------------------------------------------------

WAIT_TABLE=$(cat <<'TABLE'
# --- Up and Running
step-1-deploy-the-agentgateway                      wait_crds_established
helm-enterprise-agentgateway-crds                   wait_crds_established
helm-enterprise-agentgateway                        wait_deployments_available
gateway-agentgateway-proxy                          wait_gateway_programmed agentgateway-proxy && wait_rollout agentgateway-proxy
helm-management                                     wait_deployments_available
step-4-install-the-solo-ui                          wait_port 4000
step-5-verify-end-to-end-routing                    wait_port 8081

backend-anthropic-claude-sonnet-backend             wait_backend_accepted anthropic-claude-sonnet-backend
route-anthropic-claude-sonnet                       wait_route_accepted anthropic-claude-sonnet

# --- Secure
backend-keycloak                                    wait_backend_accepted keycloak
policy-llm-jwt-auth                                 wait_policy_attached llm-jwt-auth
policy-llm-authz                                    wait_policy_attached llm-authz
policy-llm-guardrails                               wait_policy_attached llm-guardrails
policy-llm-guardrails-2                             wait_policy_attached llm-guardrails

# --- Observe
10-1-look-at-the-metric                             wait_port 15020
10-2-add-caller-attribution-rollout-restart         wait_port 8081 && wait_port 15020
policy-llm-caller-attribution                       wait_policy_attached llm-caller-attribution
policy-llm-frontend-telemetry                       wait_policy_attached llm-frontend-telemetry
11-3-reference-it-and-attach-it-to-rollout-status    wait_port 8081 && wait_port 15020 && wait_port 4000
12-1-open-the-cost-dashboard                        wait_port 4000

# --- Control
route-anthropic-claude-sonnet-svc                   wait_route_accepted anthropic-claude-sonnet-svc
policy-llm-svc-apikey-auth                          wait_policy_attached llm-svc-apikey-auth
policy-llm-gateway-jwt-auth                         wait_policy_attached llm-gateway-jwt-auth
policy-llm-svc-jwt-permissive                       wait_policy_attached llm-svc-jwt-permissive
policy-llm-budget-enforcement                       wait_policy_attached llm-budget-enforcement
budget-llm-budgets                                  wait_budget_enforced llm-budgets && wait_exists ratelimitconfig agw-budget-llm-budgets-
budget-llm-budget-demo                              wait_budget_enforced llm-budget-demo && wait_exists ratelimitconfig agw-budget-llm-budget-demo-
budget-llm-budgets-2                                wait_budget_enforced llm-budgets
backend-anthropic-passthrough-backend               wait_backend_accepted anthropic-passthrough-backend
route-anthropic-alias                               wait_route_accepted anthropic-alias
policy-llm-model-aliases                            wait_policy_attached llm-model-aliases
backend-llm-failover-backend                        wait_backend_accepted llm-failover-backend && wait_route_accepted llm-failover
policy-llm-failover-health                          wait_policy_attached llm-failover-health
policy-llm-failover-health-2                        wait_policy_attached llm-failover-health
policy-llm-failover-health-3                        wait_policy_attached llm-failover-health
policy-llm-failover-health-4                        wait_policy_attached llm-failover-health
policy-llm-failover-model-headers                   wait_policy_attached llm-failover-model-headers
policy-llm-prompt-enrichment                        wait_policy_attached llm-prompt-enrichment
policy-llm-token-ceiling                            wait_policy_attached llm-token-ceiling

# --- Read from the cluster on v2026.7.1, rather than reasoned about. What the
# --- four deferred entries turned out to be:
#
#   HTTPRoute and EnterpriseAgentgatewayBackend are keyed above now. The routes
#   need a filtered jsonpath because their conditions are per parent; the
#   backends do not, because theirs are at .status.conditions where kubectl wait
#   reads. Step 3 says a route's status shows `Accepted` and `Programmed`; the
#   live status carries `Accepted` and `ResolvedRefs`, and no `Programmed`. The
#   guide is wrong about that word, and ResolvedRefs is the useful one anyway.
#
#   eagpol and eagbud condition paths are confirmed, and the policy wait no
#   longer greps a reason string for it. Both are noted at their helpers.
#
#   enterpriseagentgatewayparameters-llm-cost-params gets no entry, and the
#   reason changed rather than persisting. The ConfigMap that block's step reads,
#   agentgateway-proxy-model-catalog, is not created by it: the controller
#   creates it with the Gateway, owned by the Gateway, at the same timestamp, a
#   minute before the parameters resource exists. So there is nothing here to
#   wait for that the Gateway's own wait has not already covered. The roll that
#   the patch does trigger is waited on by the guide's own next block.
#
# --- Still not keyable, and the reason is unchanged:
#
# 15-3-verify-and-demonstrate-patch-eagpol          All three patch a policy that is already attached, so a wait on
# 17-2-verify-with-something-patch-eagpol           `Attached` passes instantly whether or not the patch landed. A
# policy-llm-prompt-enrichment-restore              check that cannot fail is not a check. What these three need is an
#                                                   assertion on the patched field, which is verify.sh, not a wait.
TABLE
)

# --------------------------------------------------------------------------
# Lookup
# --------------------------------------------------------------------------

# Print the condition for a block ID. Prints nothing for an ID with no entry,
# and exits 0 either way, so a runner under `set -e` can look up every block
# without branching. Use has_wait to tell the two apart.
wait_for() {
  local id=${1:?usage: wait_for <block-id>}
  local line key rest cmd="" found=0

  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    key=${line%%[[:space:]]*}
    [ "$key" = "$id" ] || continue
    rest=${line#"$key"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    cmd=$rest
    found=$((found + 1))
  done <<EOF
$WAIT_TABLE
EOF

  # Two entries for one ID means one of them is dead and nothing says which.
  if [ "$found" -gt 1 ]; then
    echo "waits.sh: block ID keyed $found times in the wait table: $id" >&2
    return 1
  fi

  if [ "$found" -eq 1 ]; then
    printf '%s\n' "$cmd"
  fi
  return 0
}

# Exit 0 if this block ID has a wait.
has_wait() {
  local cmd
  cmd=$(wait_for "${1:?usage: has_wait <block-id>}") || return 1
  [ -n "$cmd" ]
}

# Every ID the table keys, in table order.
wait_ids() {
  local line
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    printf '%s\n' "${line%%[[:space:]]*}"
  done <<EOF
$WAIT_TABLE
EOF
}

# ID and condition, aligned, for reading.
wait_table() {
  local line key rest width=0
  for key in $(wait_ids); do
    [ ${#key} -gt "$width" ] && width=${#key}
  done
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    key=${line%%[[:space:]]*}
    rest=${line#"$key"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    printf "%-${width}s  %s\n" "$key" "$rest"
  done <<EOF
$WAIT_TABLE
EOF
}

# --------------------------------------------------------------------------
# Conditions
#
# Every one of these is bounded. A wait that can hang has turned a build into a
# thing you have to go and look at.
# --------------------------------------------------------------------------

# _poll <description> <seconds> <command string>
# The command string is eval'd because several of these conditions are
# pipelines. Every string passed to it is a literal in this file.
_poll() {
  local desc=$1 limit=$2 cmd=$3 waited=0

  while ! eval "$cmd" >/dev/null 2>&1; do
    if [ "$waited" -ge "$limit" ]; then
      echo "waits.sh: timed out after ${limit}s waiting for $desc" >&2
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

# Established is a core apiextensions condition, so this needs no product
# knowledge. `--all` rather than named CRDs deliberately: the plural names of
# the Solo CRDs are not something I can confirm without a cluster, and a wait
# on a name that does not exist is the failure mode this file exists to avoid.
wait_crds_established() {
  kubectl wait --for=condition=Established --timeout="${WAITS_TIMEOUT}s" crd --all
}

# Available is a core Deployment condition. `--all` covers the control plane
# without naming the hash-suffixed deployments. It only covers deployments that
# exist when it starts, which is why the Gateway gets its own wait below.
wait_deployments_available() {
  kubectl wait --for=condition=Available --timeout="${WAITS_TIMEOUT}s" \
    deployment --all -n "$WAITS_NS"
}

# Programmed is a Gateway API v1 Gateway condition, and it is the PROGRAMMED
# column Step 1 tells you to read.
wait_gateway_programmed() {
  local name=${1:?usage: wait_gateway_programmed <gateway>}
  kubectl wait --for=condition=Programmed --timeout="${WAITS_TIMEOUT}s" \
    "gateway/$name" -n "$WAITS_NS"
}

# The proxy Deployment is created by the controller in response to the Gateway,
# so it does not exist the instant the Gateway is applied, and `rollout status`
# against a missing deployment errors rather than waiting.
wait_rollout() {
  local name=${1:?usage: wait_rollout <deployment>}
  _poll "deployment/$name to exist" "$WAITS_TIMEOUT" \
    "kubectl get deployment '$name' -n '$WAITS_NS'" || return 1
  kubectl rollout status "deployment/$name" -n "$WAITS_NS" --timeout="${WAITS_TIMEOUT}s"
}

# Policy conditions are reported per ancestor, at .status.ancestors[].conditions,
# so `kubectl wait --for=condition=` cannot see them: it reads .status.conditions
# and nothing else. It does accept a filtered jsonpath, which is what this uses.
#
# Read from a live policy on v2026.7.1:
#   type Attached, status True, reason Attached, message "Attached to all targets"
#
# Keyed on the type and its status, not on the reason. An earlier version of this
# grepped the reason string, which is prose that can change between patch
# releases, and `grep Attached` also matches NotAttached.
wait_policy_attached() {
  local name=${1:?usage: wait_policy_attached <policy>}
  kubectl wait \
    --for=jsonpath='{.status.ancestors[*].conditions[?(@.type=="Attached")].status}'=True \
    --timeout="${WAITS_TIMEOUT}s" "eagpol/$name" -n "$WAITS_NS"
}

# HTTPRoute conditions are also per parent, at .status.parents[].conditions, for
# the same reason and with the same workaround.
#
# Read from a live route on v2026.7.1: types Accepted and ResolvedRefs, both
# status True. There is no Programmed condition on a route, whatever Step 3 says
# about the status showing one: Programmed belongs to the Gateway.
#
# Both conditions, not only Accepted. A route whose backendRef does not resolve
# is Accepted and useless, and that is the InvalidBackendRef case Step 3 warns
# about, so it is the one worth waiting on.
wait_route_accepted() {
  local name=${1:?usage: wait_route_accepted <route>}
  kubectl wait \
    --for=jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}'=True \
    --timeout="${WAITS_TIMEOUT}s" "httproute/$name" -n "$WAITS_NS" &&
  kubectl wait \
    --for=jsonpath='{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].status}'=True \
    --timeout="${WAITS_TIMEOUT}s" "httproute/$name" -n "$WAITS_NS"
}

# EnterpriseAgentgatewayBackend is the one that puts its conditions where
# kubectl wait can read them, at .status.conditions. Read from a live backend on
# v2026.7.1: type Accepted, status True, message "Backend successfully accepted".
wait_backend_accepted() {
  local name=${1:?usage: wait_backend_accepted <backend>}
  kubectl wait --for=condition=Accepted --timeout="${WAITS_TIMEOUT}s" \
    "enterpriseagentgatewaybackend/$name" -n "$WAITS_NS"
}

# Budget conditions are at .status.conditions, so kubectl wait works. Confirmed
# against a live budget on v2026.7.1: types Accepted and Enforced, both status
# True, reasons Valid and Enforced.
#
# Enforced rather than Accepted on purpose: Step 14.3 is about the gap between
# the two, where a budget is valid, compiled, and failing open.
wait_budget_enforced() {
  local name=${1:?usage: wait_budget_enforced <budget>}
  kubectl wait --for=condition=Enforced --timeout="${WAITS_TIMEOUT}s" \
    "eagbud/$name" -n "$WAITS_NS"
}

# For a resource the controller generates, where the name carries a hash and
# only the prefix is predictable. Step 14.3 captured
# ratelimitconfig/agw-budget-llm-budgets-c7c51a75 from a live cluster.
wait_exists() {
  local kind=${1:?usage: wait_exists <kind> <name-prefix>}
  local prefix=${2:?usage: wait_exists <kind> <name-prefix>}
  _poll "$kind matching $prefix" "$WAITS_TIMEOUT" \
    "kubectl get '$kind' -n '$WAITS_NS' -o name 2>/dev/null | grep -q '$prefix'"
}

# A port-forward is up when something answers on the local port. Any HTTP
# status proves the tunnel: 401 and 404 are as good as 200 here, and the guide
# has its own checks for what the response should be. 000 is curl reporting no
# connection, which is the case this is waiting out.
_port_answers() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    "http://localhost:${1}/" 2>/dev/null) || return 1
  [ -n "$code" ] && [ "$code" != "000" ]
}

wait_port() {
  local port=${1:?usage: wait_port <port>}
  _poll "a port-forward to answer on localhost:$port" "$WAITS_PORT_TIMEOUT" \
    "_port_answers $port"
}

# --------------------------------------------------------------------------
# Direct invocation, for reading the table rather than using it.
# --------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case ${1:-} in
    --list)  wait_ids ;;
    --table) wait_table ;;
    --for)
      shift
      wait_for "${1:?usage: waits.sh --for <block-id>}"
      ;;
    -h|--help)
      sed -n '3,25p' "$0" | cut -c 3-
      ;;
    *)
      echo "usage: waits.sh [--list | --table | --for <block-id>]" >&2
      echo "       or source it and call wait_for / has_wait / wait_ids" >&2
      exit 2
      ;;
  esac
fi
