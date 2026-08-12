#!/usr/bin/env bash
#
# Removes what the guide created, and nothing else.
#
# Usage:
#   ./down.sh                  the namespace, the Helm releases, the forwards
#   ./down.sh --dry-run        say what would go, remove nothing
#   ./down.sh --crds           also the CRDs
#   ./down.sh --keycloak       also the Attachment A container
#   ./down.sh --cluster        also the kind cluster
#   ./down.sh --all            all of the above
#
# What it removes by default:
#
#   1. Port-forwards for the namespace. First, because they point at things that
#      are about to stop existing.
#   2. The resources the guide created in the namespace, while the controller is
#      still running to process their finalizers.
#   3. The three Helm releases.
#   4. The namespace, which takes anything left with it.
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
#   Keycloak. It comes from Attachment A rather than the guide, and it is a
#   container rather than anything in the cluster. `--keycloak` removes it.
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

SESSION=$here/session.sh

dry_run=false
do_crds=false
do_keycloak=false
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
    --crds)     do_crds=true ;;
    --keycloak) do_keycloak=true ;;
    --cluster)  do_cluster=true ;;
    --all)      do_crds=true; do_keycloak=true; do_cluster=true ;;
    -h|--help)
      sed -n '3,43p' "$0" | cut -c 3-
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

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

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

gone()    { removed=$((removed + 1));   printf '  removed   %s\n' "$1"; }
missing() { absent=$((absent + 1));     printf '  absent    %s\n' "$1"; }
would()   {                             printf '  would go  %s\n' "$1"; }
kept()    {                             printf '  kept      %s\n' "$1"; }
problem() { problems=$((problems + 1)); printf '  FAILED    %s: %s\n' "$1" "$2"; }

# --------------------------------------------------------------------------
# Is there a cluster at all
# --------------------------------------------------------------------------

cluster_up=false
if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  cluster_up=true
fi

echo "tearing down:"
printf '  namespace %s, context %s\n' "$NS" "$(kubectl config current-context 2>/dev/null || echo none)"
$dry_run && echo "  --dry-run, so nothing will be removed"
echo

# --------------------------------------------------------------------------
# 1. Port-forwards
#
# Before anything else. A forward outlives what it points at, so one left open
# against a namespace that no longer exists is a local port held for nothing.
# --------------------------------------------------------------------------

echo "port-forwards:"
n=$(pgrep -f "$SESSION_FORWARD_PATTERN" 2>/dev/null | wc -l | tr -d ' ')
[ -n "$n" ] || n=0
if [ "$n" -eq 0 ]; then
  missing "port-forwards for $NS"
else
  plural=s
  [ "$n" -eq 1 ] && plural=""
  if $dry_run; then
    would "$n port-forward$plural for $NS"
  else
    session_kill_forwards 1 >/dev/null
    gone "$n port-forward$plural for $NS"
  fi
fi
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
    case "
$installed
" in
      *"
$release
"*)
        if $dry_run; then
          would "helm release $release"
        elif helm uninstall "$release" -n "$NS" --wait --timeout 3m >/dev/null 2>&1; then
          gone "helm release $release"
        else
          problem "helm release $release" "uninstall failed"
        fi
        ;;
      *) missing "helm release $release" ;;
    esac
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
# 5. CRDs, opt in
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
# 6. Keycloak, opt in. Attachment A, not the guide.
# --------------------------------------------------------------------------

if $do_keycloak; then
  echo "keycloak:"
  if ! command -v docker >/dev/null 2>&1; then
    missing "the keycloak container (no docker)"
  elif [ -z "$(docker ps -aq --filter name=^keycloak$ 2>/dev/null)" ]; then
    missing "the keycloak container"
  elif $dry_run; then
    would "the keycloak container, and the realm in it"
  elif docker rm -f keycloak >/dev/null 2>&1; then
    gone "the keycloak container"
  else
    problem "the keycloak container" "docker rm failed"
  fi
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

# --------------------------------------------------------------------------

echo
if $dry_run; then
  echo "Nothing was removed. Run without --dry-run to do it."
  exit 0
fi

printf '%s removed, %s already absent' "$removed" "$absent"
[ "$problems" -gt 0 ] && printf ', %s failed' "$problems"
printf '.\n'

if [ "$problems" -eq 0 ]; then
  if [ "$removed" -eq 0 ]; then
    echo "There was nothing to remove. Running this again will say the same."
  else
    echo "Run ./up.sh to build it again."
  fi
else
  echo
  echo "What failed is above. A namespace that will not go is usually a finalizer"
  echo "on a resource whose controller has already been uninstalled."
fi

exit "$problems"
