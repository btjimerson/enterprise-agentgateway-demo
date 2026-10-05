#!/usr/bin/env bash
# Shared helpers for co-installing two Solo "management" chart releases in the
# SAME cluster — e.g. release "management" in agentgateway-system alongside a
# second Solo product that installs the same chart into another namespace.
#
# The `management` chart (solo-enterprise-helm/charts/management) ships
# cluster-scoped management-plane CRDs — e.g.
# kubernetesclusters.kagent-enterprise.solo.io — as Helm-OWNED resources. A
# cluster-scoped CRD can be owned by only one Helm release, so a SECOND
# management release in the same cluster fails with:
#   "invalid ownership metadata; ... meta.helm.sh/release-name must equal ..."
#
# These helpers make the second install reuse the CRDs the first one created
# (management-crds.enabled=false), and keep teardown of one release from
# deleting CRDs (and their CRs) out from under a still-installed sibling.
#
# Usage:
#   source "$(dirname "$0")/../common/management-crds.sh"
#   helm upgrade -i "$REL" ... $(mgmt_crds_install_flag "$REL" "$CTX")
#   # in cleanup(), BEFORE `helm uninstall "$REL"`:
#   mgmt_crds_release_shared "$REL" "$SIBLING_REL" "$SIBLING_NS" "$CTX"

# A CRD the management chart always ships; used as the ownership marker.
: "${SOLO_MGMT_MARKER_CRD:=kubernetesclusters.kagent-enterprise.solo.io}"

# Helm release-name that currently owns the shared management CRDs (empty when
# the marker CRD does not exist yet).
#   $1 kube-context
_mgmt_crds_owner() {
  kubectl --context "$1" get crd "${SOLO_MGMT_MARKER_CRD}" \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true
}

# Echo the extra `helm --set` flags a SECOND management release needs to coexist
# with an existing one in the same cluster, or nothing when this is the first/
# only release (so a standalone install keeps its default cluster-wide UI).
#
# The `management` chart ships two kinds of fixed-name cluster-scoped singletons
# that only one Helm release can own:
#   * the management CRDs            -> share them: management-crds.enabled=false
#   * ClusterRole/ClusterRoleBinding -> avoid them: set kubernetes.watchNamespaces
#     `solo-enterprise-ui-role*`        so the chart renders namespaced Roles in
#                                       the watched namespaces instead.
# Detection is order-independent: whichever release installs first owns the
# cluster-scoped resources; the second is steered to share/namespace them.
#   $1 our release name   $2 kube-context   $3 comma-separated namespaces to watch
mgmt_coinstall_flags() {
  local our="$1" ctx="$2" watch_ns="$3" owner
  owner="$(_mgmt_crds_owner "$ctx")"
  if [ -n "${owner}" ] && [ "${owner}" != "${our}" ]; then
    echo "--set management-crds.enabled=false --set kubernetes.watchNamespaces={${watch_ns}}"
  fi
}

# Before uninstalling OUR management release: if the sibling release is still
# installed and WE own the shared CRDs, hand ownership to the sibling and pin
# helm.sh/resource-policy=keep so our `helm uninstall` leaves them in place.
# This prevents tearing down one walkthrough from deleting the shared CRDs (and
# every CR of those kinds) that the other walkthrough is still using.
#   $1 our release   $2 sibling release   $3 sibling namespace   $4 kube-context
mgmt_crds_release_shared() {
  local our="$1" other="$2" other_ns="$3" ctx="$4"
  helm status "${other}" -n "${other_ns}" --kube-context "${ctx}" >/dev/null 2>&1 || return 0
  [ "$(_mgmt_crds_owner "${ctx}")" = "${our}" ] || return 0

  echo "Preserving shared management CRDs for the still-installed '${other}' release..."
  local crds c
  crds="$(kubectl --context "${ctx}" get crd \
    -o custom-columns='N:.metadata.name,R:.metadata.annotations.meta\.helm\.sh/release-name' \
    --no-headers 2>/dev/null | awk -v r="${our}" '$2==r {print $1}')"
  for c in ${crds}; do
    kubectl --context "${ctx}" annotate crd "${c}" \
      helm.sh/resource-policy=keep --overwrite >/dev/null 2>&1 || true
    kubectl --context "${ctx}" annotate crd "${c}" \
      meta.helm.sh/release-name="${other}" \
      meta.helm.sh/release-namespace="${other_ns}" --overwrite >/dev/null 2>&1 || true
  done
}
