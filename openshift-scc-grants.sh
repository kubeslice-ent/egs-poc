#!/bin/bash
# SCC grants EGS needs on OpenShift (cluster-admin required).
#
#   ./openshift-scc-grants.sh apply   # create namespaces if missing, then grant
#   ./openshift-scc-grants.sh revoke  # remove every grant made by 'apply'
#
# Uses KUBECONFIG / current context. Override with: KUBECONFIG=... CONTEXT=admin ./openshift-scc-grants.sh apply
set -euo pipefail

ACTION="${1:-}"
CONTEXT_ARG=()
[ -n "${CONTEXT:-}" ] && CONTEXT_ARG=(--context "$CONTEXT")

case "$ACTION" in
  apply)  VERB="add-scc-to-"; ;;
  revoke) VERB="remove-scc-from-"; ;;
  *) echo "usage: $0 apply|revoke" >&2; exit 1 ;;
esac

grant_sa()    { oc "${CONTEXT_ARG[@]}" adm policy "${VERB}user"  "$1" -z "$2" -n "$3"; }   # scc, serviceaccount, namespace
grant_group() { oc "${CONTEXT_ARG[@]}" adm policy "${VERB}group" "$1" "system:serviceaccounts:$2"; } # scc, namespace

if [ "$ACTION" = "apply" ]; then
  # Namespaces the per-account grants need to exist (Helm adopts them later).
  for ns in egs-monitoring; do
    oc "${CONTEXT_ARG[@]}" create namespace "$ns" --dry-run=client -o yaml | oc "${CONTEXT_ARG[@]}" apply -f -
  done
fi

# --- egs-monitoring (kube-prometheus-stack hard-codes runAsUser/fsGroup, runs with RuntimeDefault seccomp) ---
# nonroot-v2 (not anyuid: anyuid has no seccompProfiles here and rejects RuntimeDefault)
for sa in prometheus-grafana \
          prometheus-kube-prometheus-alertmanager \
          prometheus-kube-prometheus-operator \
          prometheus-kube-prometheus-prometheus \
          prometheus-kube-state-metrics; do
  grant_sa nonroot-v2 "$sa" egs-monitoring
done
# node-exporter uses hostNetwork, hostPID and hostPath
grant_sa privileged prometheus-prometheus-node-exporter egs-monitoring

# --- controller + UI (fixed UIDs 65536/1000 and fsGroup 1000) ---
grant_group nonroot-v2 kubeslice-controller
grant_group nonroot-v2 kubeslice-system

# --- worker networking: nsmgr, forwarder-kernel, netop, spire, NSM webhook (hostNetwork/hostPath/privileged) ---
# The worker chart also creates egs-worker-privileged-scc for spire + kubeslice-system when
# global.profile.openshift=true; kubeslice-nsm-webhook-system is NOT covered by the chart.
for ns in kubeslice-system spire kubeslice-nsm-webhook-system; do
  grant_group privileged "$ns"
done

echo "done: $ACTION"
