#!/usr/bin/env bash
# Installs the Smart Scaler app (chart smart-scaler-app) on the EGS controller cluster on OpenShift.
# One run does: pre-flight checks, namespaces, the UI's anyuid grant, the values file, validation,
# helm install, and verification. Safe to run again: finished parts are detected and kept.
#
#   ./smart-scaler-install.sh --kubeconfig <controller-kubeconfig>
#   ./smart-scaler-install.sh --kubeconfig <controller-kubeconfig> --verify-only
#   ./smart-scaler-install.sh --kubeconfig <controller-kubeconfig> --uninstall [--delete-data]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="smart-scaler"
NAMESPACE="smart-scaler-backend"
ADMIN_NAMESPACE="smart-scaler-controller"     # fixed in the backend code
EGS_PROJECT="avesha"
WORKDIR="$HOME/smart-scaler-run"
CHART="$SCRIPT_DIR/charts/egs-saas-charts/smart-scaler-app"
STORAGE_CLASS=""
DOMAIN_EXCLUSION_LIST="avesha.io"
VERIFY_ONLY=false
UNINSTALL=false
DELETE_DATA=false
ASSUME_YES=false
KUBECONFIG_ARG=""

usage() {
  cat <<EOF
Usage: $0 --kubeconfig <path> [options]

  --kubeconfig <path>          cluster-admin kubeconfig of the EGS controller cluster (required)
  --project <name>             EGS project (default: $EGS_PROJECT)
  --workdir <dir>              where the values file is kept (default: $WORKDIR)
  --storage-class <name>       StorageClass for MySQL (default: the cluster's default class)
  --domain-exclusion <list>    email domains that may have several organizations,
                               comma-separated, no spaces (default: $DOMAIN_EXCLUSION_LIST)
  --chart <dir>                chart directory (default: the chart next to this script)
  --verify-only                only run the verification of an existing install
  --uninstall                  remove Smart Scaler. Keeps the database volume and both namespaces
  --delete-data                with --uninstall: also delete the smart-scaler-backend namespace and the database volume
  --yes                        with --uninstall: don't ask for confirmation
  -h, --help                   show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_ARG="${2:?}"; shift 2 ;;
    --project) EGS_PROJECT="${2:?}"; shift 2 ;;
    --workdir) WORKDIR="${2:?}"; shift 2 ;;
    --storage-class) STORAGE_CLASS="${2:?}"; shift 2 ;;
    --domain-exclusion) DOMAIN_EXCLUSION_LIST="${2?}"; shift 2 ;;
    --chart) CHART="${2:?}"; shift 2 ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --delete-data) DELETE_DATA=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi
step() { echo; echo "${B}[$1/6] $2${N}"; }
ok()   { echo "  ${G}OK${N}    $*"; }
warn() { echo "  ${Y}WARN${N}  $*"; }
die()  { echo "  ${R}FAIL${N}  $*" >&2; echo >&2; echo "Stopped. Nothing further was changed. See section 4, Troubleshooting, in the runbook." >&2; exit 1; }

[ -n "$KUBECONFIG_ARG" ] || { usage >&2; exit 2; }
if [ "$DELETE_DATA" = true ] && [ "$UNINSTALL" != true ]; then echo "--delete-data can only be used with --uninstall" >&2; exit 2; fi
if [ "$UNINSTALL" = true ] && [ "$VERIFY_ONLY" = true ]; then echo "--uninstall and --verify-only cannot be combined" >&2; exit 2; fi
[ -f "$KUBECONFIG_ARG" ] || { echo "Kubeconfig not found: $KUBECONFIG_ARG" >&2; exit 2; }
export KUBECONFIG="$(cd "$(dirname "$KUBECONFIG_ARG")" && pwd)/$(basename "$KUBECONFIG_ARG")"
VALUES="$WORKDIR/smart-scaler-values.yaml"
CA_FILE="$WORKDIR/ingress-ca.crt"

# ---------------------------------------------------------------- 1. pre-flight
preflight() {
  step 1 "Pre-flight checks"
  local t
  for t in oc helm yq jq openssl curl; do command -v "$t" >/dev/null || die "'$t' is not installed on this workstation"; done
  ok "tools: oc, helm, yq, jq, openssl, curl"

  oc whoami >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECONFIG"
  ok "cluster: $(oc whoami --show-server) as $(oc whoami)"
  [ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = "yes" ] || die "this user is not cluster-admin"
  ok "cluster-admin rights"

  oc api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -qx 'routes.route.openshift.io' \
    || die "no OpenShift Route API: this installer is for OpenShift only"
  local port
  port="$(oc get svc kubeslice-api-gw -n kubeslice-controller -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || true)"
  [[ " $port " == *" 8080 "* ]] || die "service kubeslice-api-gw (port 8080) not found in kubeslice-controller: is this the EGS controller cluster?"
  oc get ns "kubeslice-$EGS_PROJECT" >/dev/null 2>&1 || die "EGS project namespace kubeslice-$EGS_PROJECT not found"
  ok "EGS controller found, project '$EGS_PROJECT'"

  local workers
  workers="$(oc get clusters.controller.kubeslice.io -n "kubeslice-$EGS_PROJECT" --no-headers 2>/dev/null | wc -l || true)"
  if [ "${workers:-0}" -gt 0 ]; then ok "registered worker clusters: $workers"
  else warn "no registered worker cluster found: sign-up will not be able to create an EGS workspace"; fi

  local domain
  domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  [ -n "$domain" ] || die "cannot read the cluster's apps domain"
  APP_HOST="smart-scaler.$domain"
  if getent hosts "$APP_HOST" >/dev/null 2>&1; then ok "hostname $APP_HOST resolves"
  else warn "$APP_HOST does not resolve from this workstation: the last check (HTTPS) will fail until DNS or VPN is fixed"; fi

  [ -f "$CHART/Chart.yaml" ] || die "chart not found at $CHART"
  ok "chart: smart-scaler-app $(yq '.version' < "$CHART/Chart.yaml")"
}

release_installed() { helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 2. cluster preparation
prepare() {
  step 2 "Prepare the cluster"
  local ns
  for ns in "$NAMESPACE" "$ADMIN_NAMESPACE"; do
    oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
  done
  ok "namespaces $NAMESPACE and $ADMIN_NAMESPACE"

  oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NAMESPACE:smart-scaler-ui" >/dev/null
  oc get clusterrolebinding system:openshift:scc:anyuid \
    -o jsonpath='{range .subjects[*]}{.namespace}/{.name}{"\n"}{end}' | grep -qx "$NAMESPACE/smart-scaler-ui" \
    || die "the anyuid grant for the UI ServiceAccount was not applied"
  ok "anyuid grant for the UI ServiceAccount only"

  if [ -n "$STORAGE_CLASS" ]; then
    oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass '$STORAGE_CLASS' not found"
    ok "StorageClass for MySQL: $STORAGE_CLASS"
  else
    local def
    def="$(oc get storageclass -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name] | join(",")')"
    [ -n "$def" ] || die "no default StorageClass: run again with --storage-class <name> (see: oc get storageclass)"
    ok "default StorageClass for MySQL: $def"
  fi
}

admin_secret_ok() {
  [ -n "$(oc get secret egs-admin-details -n "$ADMIN_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null)" ]
}

# ---------------------------------------------------------------- 3. values file
make_values() {
  step 3 "Values file"
  mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
  if [ -s "$VALUES" ]; then
    ok "found, kept unchanged: $VALUES"
    return
  fi
  # No values file. Refuse to generate new passwords over an existing install or database.
  release_installed && die "release '$RELEASE' is installed but $VALUES is missing. Restore the values file from your backup"
  oc get pvc "data-$RELEASE-mysql-0" -n "$NAMESPACE" >/dev/null 2>&1 \
    && die "a MySQL volume from an earlier install exists but $VALUES is missing. Restore the values file, or delete the volume: oc delete pvc data-$RELEASE-mysql-0 -n $NAMESPACE (this deletes all Smart Scaler data)"

  export MANAGE_ADMIN_SECRET=true EGS_ADMIN_TOKEN=""
  if oc get secret egs-admin-details -n "$ADMIN_NAMESPACE" >/dev/null 2>&1; then
    [ -n "$(oc get secret egs-admin-details -n "$ADMIN_NAMESPACE" -o jsonpath='{.data.token}')" ] \
      || die "Secret egs-admin-details exists in $ADMIN_NAMESPACE but has no 'token' key"
    MANAGE_ADMIN_SECRET=false
    ok "existing Secret egs-admin-details will be reused"
  else
    EGS_ADMIN_TOKEN="$(oc get secret kubeslice-rbac-rw-admin -n "kubeslice-$EGS_PROJECT" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [ -n "$EGS_ADMIN_TOKEN" ] || die "cannot read the EGS admin token from Secret kubeslice-rbac-rw-admin in kubeslice-$EGS_PROJECT"
    ok "EGS admin token read (length ${#EGS_ADMIN_TOKEN})"
  fi

  export APP_HOST STORAGE_CLASS DOMAIN_EXCLUSION_LIST
  export MYSQL_USER="smartscaler" MYSQL_DB="smart_scaler_saas"
  export MYSQL_PASSWORD ACCESS_TOKEN_SECRET REFRESH_TOKEN_SECRET ENCRYPTION_SECRET
  MYSQL_PASSWORD="$(openssl rand -hex 16)"
  ACCESS_TOKEN_SECRET="$(openssl rand -hex 32)"
  REFRESH_TOKEN_SECRET="$(openssl rand -hex 32)"
  ENCRYPTION_SECRET="$(openssl rand -hex 16)"       # exactly 32 characters
  ( umask 077; yq -n '
    .mysql.enabled                      = true                           |
    .mysql.persistence.storageClass     = strenv(STORAGE_CLASS)          |
    .backend.mysql.username             = strenv(MYSQL_USER)             |
    .backend.mysql.password             = strenv(MYSQL_PASSWORD)         |
    .backend.mysql.dbname               = strenv(MYSQL_DB)               |
    .backend.secrets.accessTokenSecret  = strenv(ACCESS_TOKEN_SECRET)    |
    .backend.secrets.refreshTokenSecret = strenv(REFRESH_TOKEN_SECRET)   |
    .backend.secrets.encryptionSecret   = strenv(ENCRYPTION_SECRET)      |
    .backend.domainExclusionList        = strenv(DOMAIN_EXCLUSION_LIST)  |
    .backend.service.type               = "ClusterIP"                    |
    .ui.service.type                    = "ClusterIP"                    |
    .route.enabled                      = true                           |
    .route.host                         = strenv(APP_HOST)               |
    .egs.manageAdminSecret              = env(MANAGE_ADMIN_SECRET)       |
    .egs.adminToken                     = strenv(EGS_ADMIN_TOKEN)' > "$VALUES" )
  unset EGS_ADMIN_TOKEN MYSQL_PASSWORD ACCESS_TOKEN_SECRET REFRESH_TOKEN_SECRET ENCRYPTION_SECRET
  ok "created with generated passwords: $VALUES"
}

# ---------------------------------------------------------------- 4 + 5. validate and install
install() {
  step 4 "Validate"
  if release_installed; then
    ok "release '$RELEASE' is already installed: validation and install skipped"
    step 5 "Install"
    ok "already installed ($(helm list -n "$NAMESPACE" -f "^$RELEASE\$" -o json | jq -r '.[0].chart'))"
  else
    if [ "$(yq '.egs.manageAdminSecret' < "$VALUES")" = "false" ] && ! admin_secret_ok; then
      die "$VALUES expects an existing Secret egs-admin-details (key 'token') in $ADMIN_NAMESPACE, but it is missing. Create it again, or set egs.manageAdminSecret to true and egs.adminToken in the values file"
    fi
    helm lint "$CHART" -f "$VALUES" >/dev/null 2>&1 || { helm lint "$CHART" -f "$VALUES" || true; die "helm lint failed"; }
    ok "chart lint"
    local out
    out="$(helm install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" --dry-run=server 2>&1 >/dev/null)" \
      || { echo "$out" >&2; die "dry run against the cluster failed"; }
    ok "dry run against the cluster"

    step 5 "Install"
    helm install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" >/dev/null || die "helm install failed"
    ok "helm release '$RELEASE' deployed"
  fi
  echo "        waiting for the pods (the first image download can take several minutes)..."
  oc rollout status statefulset/"$RELEASE-mysql" -n "$NAMESPACE" --timeout=15m >/dev/null || die "MySQL did not become ready"
  ok "MySQL ready"
  oc rollout status deploy/"$RELEASE-backend" -n "$NAMESPACE" --timeout=15m >/dev/null || die "the backend did not become ready"
  ok "backend ready"
  oc rollout status deploy/"$RELEASE-ui" -n "$NAMESPACE" --timeout=15m >/dev/null || die "the UI did not become ready"
  ok "UI ready"
}

# ---------------------------------------------------------------- 6. verify
verify() {
  step 6 "Verify"
  local failed=0
  bad() { echo "  ${R}FAIL${N}  $*"; failed=1; }

  local pods
  pods="$(oc get pods -n "$NAMESPACE" -o json)"
  local comp phase restarts scc want
  for comp in backend mysql ui; do
    phase="$(jq -r --arg p "$RELEASE-$comp" '[.items[] | select(.metadata.name | startswith($p))][0].status.phase // "missing"' <<<"$pods")"
    restarts="$(jq -r --arg p "$RELEASE-$comp" '[.items[] | select(.metadata.name | startswith($p))][0].status.containerStatuses[0].restartCount // "?"' <<<"$pods")"
    scc="$(jq -r --arg p "$RELEASE-$comp" '[.items[] | select(.metadata.name | startswith($p))][0].metadata.annotations["openshift.io/scc"] // "?"' <<<"$pods")"
    want="restricted-v2"; [ "$comp" = ui ] && want="anyuid"
    if [ "$phase" = Running ] && [ "$scc" = "$want" ]; then ok "$comp pod Running (SCC $scc, restarts $restarts)"
    else bad "$comp pod: status $phase, SCC $scc (expected Running, $want)"; fi
  done

  local tables
  tables="$(oc exec -n "$NAMESPACE" "$RELEASE-mysql-0" -- sh -c \
    'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" -N -e "select count(*) from information_schema.tables where table_schema=database()" "$MYSQL_DATABASE"' 2>/dev/null || echo "?")"
  if [ "$tables" = 15 ]; then ok "database: 15 tables"; else bad "database: $tables tables (expected 15)"; fi

  if admin_secret_ok; then ok "EGS admin Secret egs-admin-details present in $ADMIN_NAMESPACE"
  else bad "Secret egs-admin-details (key 'token') is missing in $ADMIN_NAMESPACE: sign-ups cannot create EGS workspaces"; fi

  local admitted
  admitted="$(oc get route -n "$NAMESPACE" -o json | jq -r '[.items[] | select(.status.ingress[0].conditions[0].status=="True")] | length')"
  if [ "$admitted" = 2 ]; then ok "routes: 2 admitted on $APP_HOST"; else bad "routes: $admitted of 2 admitted"; fi

  oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_FILE" 2>/dev/null || true
  local path code i
  for path in /api/v1/health-check /; do
    code=000
    for i in $(seq 1 60); do
      code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" "https://$APP_HOST$path" || true)"
      [ "$code" = 200 ] && break
      sleep 5
    done
    if [ "$code" = 200 ]; then ok "https://$APP_HOST$path -> 200"; else bad "https://$APP_HOST$path -> $code (expected 200)"; fi
  done

  echo
  if [ "$failed" = 0 ]; then
    echo "${G}${B}Smart Scaler is installed and verified.${N}"
    echo
    echo "  UI:           https://$APP_HOST"
    echo "  Values file:  $VALUES"
    echo "                Back this file up. Every upgrade or reinstall needs it."
    echo "  Next:         open the UI and create the first account (runbook, Step 3)."
  else
    echo "${R}${B}Verification failed.${N} See section 4, Troubleshooting, in the runbook." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- uninstall
# Removes Smart Scaler only: its Helm release, the UI's anyuid grant and, with --delete-data, its own
# namespace. $ADMIN_NAMESPACE is never deleted: a Secret egs-admin-details that was there before the
# install is not ours, and a reinstall with the kept values file needs it. It never touches EGS and never runs openshift-scc-grants.sh revoke.
uninstall() {
  local t
  for t in oc helm; do command -v "$t" >/dev/null || die "'$t' is not installed on this workstation"; done
  oc whoami >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECONFIG"
  [ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = "yes" ] || die "this user is not cluster-admin"

  echo
  echo "${B}Uninstall Smart Scaler${N} from $(oc whoami --show-server)"
  echo "  Removes:  Helm release '$RELEASE' in $NAMESPACE, and the anyuid grant of the UI ServiceAccount"
  if [ "$DELETE_DATA" = true ]; then
    echo "  ${R}Deletes:${N}  namespace $NAMESPACE, with the database volume:"
    echo "            every Smart Scaler user and organization is lost"
    echo "  Keeps:    namespace $ADMIN_NAMESPACE"
  else
    echo "  Keeps:    the database volume (all users and organizations) and both namespaces"
  fi
  echo "  Keeps:    EGS, its grants, and the EGS tenant-* workspaces created by sign-ups"
  echo "  Keeps:    the values file $VALUES"
  if [ "$ASSUME_YES" != true ]; then
    local answer=""
    read -r -p "Type 'yes' to continue: " answer || true
    [ "$answer" = "yes" ] || { echo "Cancelled. Nothing was changed."; exit 1; }
  fi
  echo

  if release_installed; then
    helm uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null || die "helm uninstall failed"
    ok "Helm release '$RELEASE' removed"
  else
    ok "Helm release '$RELEASE' was not installed"
  fi
  oc adm policy remove-scc-from-user anyuid "system:serviceaccount:$NAMESPACE:smart-scaler-ui" >/dev/null 2>&1 || true
  if oc get clusterrolebinding system:openshift:scc:anyuid -o jsonpath='{range .subjects[*]}{.namespace}/{.name}{"\n"}{end}' 2>/dev/null \
      | grep -qx "$NAMESPACE/smart-scaler-ui"; then die "the anyuid grant of the UI ServiceAccount is still there"; fi
  ok "anyuid grant of the UI ServiceAccount removed"

  if [ "$DELETE_DATA" = true ]; then
    oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=10m >/dev/null || die "could not delete namespace $NAMESPACE"
    ok "namespace $NAMESPACE deleted, with the database volume"
    echo
    echo "${G}${B}Smart Scaler and its data are removed.${N}"
    echo "  The values file is kept. Delete it if you don't plan to reinstall: $VALUES"
  else
    if oc get pvc "data-$RELEASE-mysql-0" -n "$NAMESPACE" >/dev/null 2>&1; then ok "database volume data-$RELEASE-mysql-0 kept"; fi
    echo
    echo "${G}${B}Smart Scaler is removed. Its data is kept.${N}"
    echo "  To get it back with the same users, run the installer again with the same values file: $VALUES"
  fi
}

if [ "$UNINSTALL" = true ]; then
  uninstall
  exit 0
fi

preflight
if [ "$VERIFY_ONLY" = true ]; then
  release_installed || die "release '$RELEASE' is not installed in $NAMESPACE"
  verify
  exit 0
fi
prepare
make_values
install
verify
