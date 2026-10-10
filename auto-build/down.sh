#!/usr/bin/env bash
#
# Removes what the guide created, and nothing else.
#
# Usage:
#   ./down.sh                  both namespaces, the Helm releases, the forwards
#   ./down.sh --approve        do not stop to confirm the cluster first
#   ./down.sh --dry-run        say what would go, remove nothing
#   ./down.sh --crds           also the CRDs
#   ./down.sh --cluster        also the kind cluster
#   ./down.sh --all            all of the above
#
# What it removes by default:
#
#   1. Port-forwards for both namespaces. First, because they point at things
#      that are about to stop existing.
#   2. The resources the guide created in the namespace, while the controller is
#      still running to process their finalizers.
#   3. The three Helm releases.
#   4. The namespace, which takes anything left with it.
#   5. The Keycloak namespace from Step 6.1, with the realm in it. A new
#      Keycloak imports the realm afresh, so nothing is lost that the next
#      build does not recreate.
#
# What it leaves unless told otherwise, and why:
#
#   The CRDs. Deleting a CRD deletes every resource of that kind in the cluster,
#   including ones this guide never created, so `--crds` is opt in. up.sh
#   reinstalls them anyway, so leaving them costs a rebuild nothing.
#
#   The cluster. `--cluster` deletes the kind cluster named by KIND_CLUSTER_NAME,
#   default `kind`. Nothing else here touches the cluster itself.
#
#   Files the guide told you to write. `agentgateway-values.yaml` is worth
#   keeping for upgrades, which is what Step 1 says, and `catalog.json` is worth
#   keeping if you generated it. Both are reported, neither is deleted.
#
# Safe to run against a half-built cluster, an already torn down one, or no
# cluster at all. Everything is checked for before it is removed, absence is
# reported rather than treated as an error, and running it twice is the same as
# running it once. The exit status counts things that actually failed to go.

set -u

self=${0##*/}
here=$(cd -- "$(dirname -- "$0")" && pwd)

# Resolved from this script's directory, not the working one.
SESSION=$here/lib/session.sh

dry_run=false
approve=false
do_crds=false
do_cluster=false

KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-kind}

removed=0
absent=0
problems=0

die() {
  echo "$self: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run)  dry_run=true ;;
    --approve)  approve=true ;;
    --crds)     do_crds=true ;;
    --cluster)  do_cluster=true ;;
    --all)      do_crds=true; do_cluster=true ;;
    -h|--help)
      sed -n '3,41p' "$0" | cut -c 3-
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if $approve && $dry_run; then
  die "--approve with --dry-run is a contradiction: a dry run removes nothing, so
  there is nothing to approve. Accepting both would teach the habit of typing
  --approve without reading what follows it, and what follows this one is a
  namespace going away."
fi

[ -f "$SESSION" ] || die "not found: $SESSION"

# For the namespace name and the port-forward handling. DEFS_ONLY because
# sourcing it normally would start the forwards this is here to close.
SESSION_DEFS_ONLY=1
# shellcheck source=session.sh
. "$SESSION"

# DOWN_NS retargets everything here, including which forwards get closed, so a
# run against a namespace that does not exist can be used to check this script
# without touching a built one.
NS=${DOWN_NS:-$SESSION_FORWARD_NS}
SESSION_FORWARD_NS=$NS
SESSION_FORWARD_PATTERN="kubectl port-forward.*$NS"
KEYCLOAK_NS=${DOWN_KEYCLOAK_NS:-$SESSION_KEYCLOAK_NS}
SESSION_KEYCLOAK_NS=$KEYCLOAK_NS

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

# Only two of these four are an outcome, so only two take a glyph. Absent, would
# go and kept get the same width of nothing, which keeps the column straight in
# colour and out of it.
gone()    { removed=$((removed + 1))
            printf '%s removed   %s\n' "${SESSION_GLYPH_OK:-[ok]}" "$1"; }
missing() { absent=$((absent + 1))
            printf '%s absent    %s\n' "${SESSION_GLYPH_NONE:-      }" "$1"; }
would()   { printf '%s would go  %s\n' "${SESSION_GLYPH_NONE:-      }" "$1"; }
kept()    { printf '%s kept      %s\n' "${SESSION_GLYPH_NONE:-      }" "$1"; }
problem() { problems=$((problems + 1))
            printf '%s FAILED    %s: %s\n' "${SESSION_GLYPH_FAIL:-[FAIL]}" "$1" "$2"; }

# --------------------------------------------------------------------------
# Is there a cluster at all
# --------------------------------------------------------------------------

cluster_up=false
if kubectl cluster-info --request-timeout=5s </dev/null >/dev/null 2>&1; then
  cluster_up=true
fi

# The context first and prominently, in both paths. The mistake this is here to
# stop is not "did I mean to tear down", it is "did I mean to tear down *this*".
print_target() {
  printf '%s, from:\n' "$1"
  printf '  context     %s%s%s\n' \
    "${SESSION_BOLD:-}" "$(session_kube_context || echo none)" "${SESSION_RESET:-}"
  printf '  apiserver   %s\n' "$(session_kube_apiserver || echo unknown)"
  printf '  namespaces  %s, %s\n' "$NS" "$KEYCLOAK_NS"
}

# --------------------------------------------------------------------------
# The teardown itself, as one function so it can be run twice: once to
# enumerate, whose output becomes the list you are asked to approve, and once to
# act. The enumerating pass only reads.
# --------------------------------------------------------------------------

teardown() {
  # --------------------------------------------------------------------------
  # 1. Port-forwards
  #
  # Before anything else. A forward outlives what it points at, so one left open
  # against a namespace that no longer exists is a local port held for nothing.
  # --------------------------------------------------------------------------

  echo "port-forwards:"
  for fns in "$NS" "$KEYCLOAK_NS"; do
    n=$(pgrep -f "kubectl port-forward.*$fns" 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$n" ] || n=0
    if [ "$n" -eq 0 ]; then
      missing "port-forwards for $fns"
      continue
    fi
    plural=s
    [ "$n" -eq 1 ] && plural=""
    if $dry_run; then
      would "$n port-forward$plural for $fns"
    else
      pkill -f "kubectl port-forward.*$fns" 2>/dev/null || true
      gone "$n port-forward$plural for $fns"
    fi
  done
  echo

  # --------------------------------------------------------------------------
  # 2. What the guide created in the namespace
  #
  # By kind, while the controller is still running. A custom resource with a
  # finalizer on it outlives its controller, and deleting the namespace first can
  # then sit in Terminating with nothing left to process the finalizer.
  # --------------------------------------------------------------------------

  GUIDE_KINDS="eagpol eagbud enterpriseagentgatewaybackend enterpriseagentgatewayparameters
  httproute gateway"

  delete_all_of() { # delete_all_of <kind>
    local kind=$1 names

    # Missing kind and no objects of that kind are different things, and only the
    # second one is worth a line. `--ignore-not-found` covers absent objects, not
    # an absent CRD.
    if ! kubectl get "$kind" -n "$NS" >/dev/null 2>&1; then
      missing "$kind (kind not installed)"
      return 0
    fi

    names=$(kubectl get "$kind" -n "$NS" -o name 2>/dev/null)
    if [ -z "$names" ]; then
      missing "$kind (none in $NS)"
      return 0
    fi

    local count
    count=$(printf '%s\n' "$names" | grep -c .)
    if $dry_run; then
      would "$count $kind in $NS"
      return 0
    fi

    if kubectl delete "$kind" --all -n "$NS" --ignore-not-found --timeout=120s >/dev/null 2>&1; then
      gone "$count $kind in $NS"
    else
      problem "$kind" "kubectl delete did not finish"
    fi
  }

  echo "resources in $NS:"
  if ! $cluster_up; then
    missing "everything in the cluster (no cluster reachable)"
  elif ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    missing "namespace $NS, so nothing inside it either"
  else
    for kind in $(printf '%s' "$GUIDE_KINDS"); do
      delete_all_of "$kind"
    done
  fi
  echo

  # --------------------------------------------------------------------------
  # 3. Helm releases
  # --------------------------------------------------------------------------

  RELEASES="management enterprise-agentgateway enterprise-agentgateway-crds"

  echo "helm releases:"
  if ! $cluster_up; then
    missing "all releases (no cluster reachable)"
  elif ! command -v helm >/dev/null 2>&1; then
    problem "helm" "not installed, so the releases cannot be uninstalled"
  else
    installed=$(helm list -n "$NS" -q 2>/dev/null)
    for release in $(printf '%s' "$RELEASES"); do
      # A whole-line match. A case pattern built from newline-delimited strings
      # broke silently when it was indented: it then matched nothing, and every
      # release was reported absent and left installed.
      if ! printf '%s\n' "$installed" | grep -qx "$release"; then
        missing "helm release $release"
      elif $dry_run; then
        would "helm release $release"
      elif helm uninstall "$release" -n "$NS" --wait --timeout 3m >/dev/null 2>&1; then
        gone "helm release $release"
      else
        problem "helm release $release" "uninstall failed"
      fi
    done
  fi
  echo

  # --------------------------------------------------------------------------
  # 4. The namespace
  # --------------------------------------------------------------------------

  echo "namespace:"
  if ! $cluster_up; then
    missing "namespace $NS (no cluster reachable)"
  elif ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    missing "namespace $NS"
  elif $dry_run; then
    would "namespace $NS, and anything still in it"
  elif kubectl delete namespace "$NS" --ignore-not-found --timeout=180s >/dev/null 2>&1; then
    gone "namespace $NS"
  else
    problem "namespace $NS" "still deleting after 180s, usually a finalizer. kubectl get all -n $NS"
  fi
  echo

  # --------------------------------------------------------------------------
  # 5. The Keycloak namespace, from Step 6.1
  #
  # After the gateway's, so nothing is left validating tokens against an IdP
  # that has gone. Nothing in it carries a finalizer.
  # --------------------------------------------------------------------------

  echo "keycloak:"
  if ! $cluster_up; then
    missing "namespace $KEYCLOAK_NS (no cluster reachable)"
  elif ! kubectl get namespace "$KEYCLOAK_NS" >/dev/null 2>&1; then
    missing "namespace $KEYCLOAK_NS"
  elif $dry_run; then
    would "namespace $KEYCLOAK_NS, Keycloak and the realm in it"
  elif kubectl delete namespace "$KEYCLOAK_NS" --ignore-not-found --timeout=180s >/dev/null 2>&1; then
    gone "namespace $KEYCLOAK_NS"
  else
    problem "namespace $KEYCLOAK_NS" "still deleting after 180s. kubectl get all -n $KEYCLOAK_NS"
  fi
  echo

  # --------------------------------------------------------------------------
  # 6. CRDs, opt in
  # --------------------------------------------------------------------------

  if $do_crds; then
    echo "CRDs:"
    if ! $cluster_up; then
      missing "CRDs (no cluster reachable)"
    else
      for group in enterpriseagentgateway.solo.io agentgateway.dev gateway.networking.k8s.io; do
        crds=$(kubectl get crd -o name 2>/dev/null | grep "\.$group\$")
        if [ -z "$crds" ]; then
          missing "CRDs for $group"
          continue
        fi
        count=$(printf '%s\n' "$crds" | grep -c .)
        if $dry_run; then
          would "$count CRDs for $group, and every resource of those kinds in the cluster"
        elif printf '%s\n' "$crds" | xargs kubectl delete --ignore-not-found --timeout=120s >/dev/null 2>&1; then
          gone "$count CRDs for $group"
        else
          problem "CRDs for $group" "kubectl delete did not finish"
        fi
      done
    fi
    echo
  else
    echo "CRDs:"
    kept "CRDs, which up.sh reinstalls. --crds removes them"
    echo
  fi

  # --------------------------------------------------------------------------
  # 7. The cluster, opt in
  # --------------------------------------------------------------------------

  if $do_cluster; then
    echo "cluster:"
    if ! command -v kind >/dev/null 2>&1; then
      missing "the kind cluster (no kind binary, so it was not made by kind)"
    elif ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
      missing "kind cluster $KIND_CLUSTER_NAME"
    elif $dry_run; then
      would "kind cluster $KIND_CLUSTER_NAME, and everything in it"
    elif kind delete cluster --name "$KIND_CLUSTER_NAME" >/dev/null 2>&1; then
      gone "kind cluster $KIND_CLUSTER_NAME"
    else
      problem "kind cluster $KIND_CLUSTER_NAME" "kind delete failed"
    fi
    echo
  fi

  # --------------------------------------------------------------------------
  # Files, reported and left alone
  # --------------------------------------------------------------------------

  echo "files:"
  for f in "$here/agentgateway-values.yaml" "$here/catalog.json"; do
    if [ -f "$f" ]; then
      kept "${f#"$here/"}"
    else
      missing "${f#"$here/"}"
    fi
  done

}

# --------------------------------------------------------------------------
# Ask first, showing the context and what would go
# --------------------------------------------------------------------------

if $dry_run; then
  print_target "this would remove"
  echo
  teardown
  echo
  echo "Nothing was removed. Run without --dry-run to do it."
  exit 0
fi

# The plan comes from the same code that does the work, run with dry_run on, in a
# subshell so its counters do not carry into the real pass.
plan=$( dry_run=true; teardown )

print_target "this would remove"
echo
printf '%s\n' "$plan" | sed 's/^/  /'

if ! session_confirm "$approve" "remove this from $(session_kube_context || echo 'no context')"; then
  exit 3
fi

echo
teardown

# --------------------------------------------------------------------------

echo
printf '%s removed, %s already absent' "$removed" "$absent"
[ "$problems" -gt 0 ] && printf ', %s failed' "$problems"
printf '.\n'

if [ "$problems" -eq 0 ]; then
  if [ "$removed" -eq 0 ]; then
    echo "There was nothing to remove. Running this again will say the same."
  else
    echo "${SESSION_GREEN:-}Torn down. Run ./up.sh to build it again.${SESSION_RESET:-}"
  fi
else
  echo
  echo "${SESSION_RED:-}What failed is above.${SESSION_RESET:-} A namespace that will not go is usually a finalizer"
  echo "on a resource whose controller has already been uninstalled."
fi

exit "$problems"
