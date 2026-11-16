# Smart Scaler App – Installation Runbook

**Chart:** `smart-scaler-app` 0.2.0 (app version 3.3.0) from the egs-poc repository, path `charts/egs-saas-charts/smart-scaler-app`.
**Validated chart commit:** egs-poc `3b63fe9`, the merge of PR #8.
**Installs:** the Smart Scaler backend and UI, connected to an EGS stack that is already running.
**Target cluster:** the **EGS controller cluster** on **OpenShift**, the one that runs `kubeslice-api-gw` in `kubeslice-controller`. For a plain Kubernetes cluster, see the [Appendix](#appendix--plain-kubernetes-nodeport-variant).

> **Scope.** This is a proof-of-concept setup:
> - The backend runs with `GIN_MODE=debug` and `APP_ENV=development`. Both are chart values (`backend.ginMode`, `backend.appEnv`), but no other settings have been tested.
> - The images come from the development path `avesha/aveshadev`, and the backend tag is a SNAPSHOT build.
> - TLS uses the OpenShift router's certificate. The chart has no health probes.
>
> Don't use it as-is for production or customer environments.

> **Validation status.**
> - **Chart 0.2.0 at `3b63fe9`:** `helm lint` and `helm template` checks pass. On a plain Kubernetes (kind) cluster it was installed, upgraded from 0.1.0, rolled back, downgraded and uninstalled without errors.
> - **OpenShift parts** (Routes, the `anyuid` grant): rendered and checked offline. **Not yet installed on the dell-poc controller cluster.** Save the output of Step 6 from the first install; it replaces the expected values in [Troubleshooting → OpenShift](#openshift-the-ui-needs-anyuid).

---

## Contents
1. [What gets installed](#1-what-gets-installed)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 – Set variables and get the chart](#step-1--set-variables-and-get-the-chart)
4. [Step 2 – Pre-flight checks](#step-2--pre-flight-checks)
5. [Step 3 – Namespaces, SCC grant and MySQL check](#step-3--namespaces-scc-grant-and-mysql-check)
6. [Step 4 – Create the values file](#step-4--create-the-values-file)
7. [Step 5 – Validate and install](#step-5--validate-and-install)
8. [Step 6 – Verify](#step-6--verify)
9. [Day-2 operations](#day-2-operations)
10. [Uninstall](#uninstall)
11. [Troubleshooting](#troubleshooting)
12. [Values reference](#values-reference)
13. [Appendix – Plain Kubernetes (NodePort) variant](#appendix--plain-kubernetes-nodeport-variant)

**Flow at a glance**

| Step | What | Why |
|---|---|---|
| 1 | Set variables, get the chart from egs-poc at `3b63fe9` | Every later command reuses them. A pinned commit means you install exactly what was validated |
| 2 | Pre-flight checks | Confirms the cluster, cluster-admin rights, the Route API, the EGS gateway and DNS. Decides how the EGS admin Secret is handled |
| 3 | Namespaces, `anyuid` for the UI, MySQL check | The chart doesn't create `smart-scaler-controller`. The UI image must run as root |
| 4 | Create the values file | Keeps credentials out of `--set`. Turns on the Route and ClusterIP Services |
| 5 | Lint, dry run, then one `helm install` | The URL is known in advance, so there's no second pass |
| 6 | Verify | Pods and SCCs, Routes, HTTPS checks, sign-up |

---

## 1. What gets installed

The release name is `smart-scaler` and the release namespace is `smart-scaler-backend`. Keep both unless you have a reason to change them (see Step 1).

| Kind | Name | Namespace | Notes |
|---|---|---|---|
| Deployment | `smart-scaler-backend` | `smart-scaler-backend` | Go backend, port 5000. Runs under the `restricted-v2` SCC with the `default` ServiceAccount |
| Deployment | `smart-scaler-ui` | `smart-scaler-backend` | nginx UI, port 80. Runs as root under the `anyuid` SCC with its own ServiceAccount |
| ServiceAccount | `smart-scaler-ui` | `smart-scaler-backend` | For the UI only. No API token is mounted |
| Service (ClusterIP) | `smart-scaler-backend` | `smart-scaler-backend` | Port `http` 80 → 5000 |
| Service (ClusterIP) | `smart-scaler-ui` | `smart-scaler-backend` | Port `http` 80 → 80 |
| Route | `smart-scaler-ui` | `smart-scaler-backend` | `https://<APP_HOST>/` → UI. Edge TLS; `http://` redirects to `https://` |
| Route | `smart-scaler-backend` | `smart-scaler-backend` | `https://<APP_HOST>/api` → backend. Same host, edge TLS |
| Secret | `smart-scaler-backend-secrets` | `smart-scaler-backend` | MySQL credentials and the token/encryption secrets. Skipped if `backend.secrets.existingSecret` is set |
| ConfigMap | `smart-scaler-backend-role-config` | `smart-scaler-backend` | Fixed product roles (Admin, Editor, Event Manager, Viewer, Avesha Support). The backend won't start without it |
| Secret | `egs-admin-details` | `smart-scaler-controller` | **Only if `egs.manageAdminSecret=true`.** Holds the EGS admin token |
| Role and RoleBinding | `smart-scaler-read-egs-admin-secret`, `smart-scaler-backend-read-egs-admin-secret` | `smart-scaler-controller` | Lets the release namespace's `default` ServiceAccount (the backend) `get` `egs-admin-details` |

**Images.** `pullPolicy` is `IfNotPresent`, so each node pulls once.
- Backend: `harbor.saas1.smart-scaler.io/avesha/aveshadev/smart-scaler-backend:3.3.0-SNAPSHOT-63669b2e`
- UI: `harbor.saas1.smart-scaler.io/avesha/aveshadev/smart-scaler-ui:v3.0.1-RELEASE-c9120009`

**How it works:**
- **One hostname for everything.** Users open `https://<APP_HOST>`. The UI calls the backend at `https://<APP_HOST>/api/v1`, on the same host, so the browser sees one origin. No CORS is involved, and the login cookie stays on that host.
- **Routing.** The `/api` Route matches by path segment: `/api` and `/api/...` go to the backend. Everything else, including `/apiconfig.json`, goes to the UI.
- **Backend to EGS.** The backend calls EGS at `http://kubeslice-api-gw.kubeslice-controller.svc.cluster.local:8080`, inside the cluster.
- **EGS admin token.** The backend reads it from the Secret `egs-admin-details` in **`smart-scaler-controller`**. That namespace is hard-coded in the backend.
- **Sign-up.** A new sign-up starts an asynchronous EGS workspace (slice) creation named `tenant-<hash>`.

---

## 2. Prerequisites

**Workstation**
- `oc`, `helm` 3.x (validated with v3.15), `git`, `yq` v4, `openssl`, `jq` and `curl`.
- A **cluster-admin** kubeconfig for the EGS controller cluster. Step 3 grants an SCC, which needs cluster-admin.
- Read access to `https://github.com/kubeslice-ent/egs-poc`.

**Cluster**
- EGS controller and UI are installed and healthy. Service `kubeslice-api-gw` in `kubeslice-controller` listens on port 8080.
- The EGS project exists. The default is `avesha`, which gives namespace `kubeslice-avesha`.
- The default router serves `*.apps.<cluster-domain>`. For dell-poc, that's `*.apps.egs-dell-poc.ocp.aveshalabs.io`. Users' machines must resolve and reach it on ports 443 and 80.
- The nodes can reach `harbor.saas1.smart-scaler.io` over HTTPS. It's an anonymous pull, so no registry credentials are needed.

**MySQL (external).** The backend needs a MySQL database. **Nothing in EGS provides one, and there is none on the dell-poc cluster today.**
- It must be reachable **from the pods**, the database must already exist, and the user needs full rights on it.
- The EGS PostgreSQL (`kt-postgresql`) can't be used: the backend supports MySQL only.
- If you run MySQL inside OpenShift instead, use an image that runs as a random UID, for example Red Hat's `rhel9/mysql-80`. Otherwise its ServiceAccount needs its own SCC grant. That setup is outside this runbook.

**Values to have ready**

| Value | Where it comes from | Rules |
|---|---|---|
| MySQL host, port, user, password, database | Your DBA | See above |
| `ACCESS_TOKEN_SECRET`, `REFRESH_TOKEN_SECRET` | Generated in Step 4 | Any strings; they are HMAC signing keys |
| `ENCRYPTION_SECRET` | Generated in Step 4 | **Exactly 32 characters** (AES-256 key). The chart refuses any other length. **Keep it permanent:** changing it later makes data that's already encrypted unreadable |
| EGS admin token | Read in Step 2 | Long-lived ServiceAccount token from Secret `kubeslice-rbac-rw-admin` in `kubeslice-<project>` |

---

## Step 1 – Set variables and get the chart

Run every later step **in the same shell**.

```bash
# ============ CUSTOMIZE THESE VALUES ============
export KUBECONFIG="<absolute-path-to-controller-kubeconfig>"   # EGS controller cluster, cluster-admin
export RELEASE="smart-scaler"                                  # Helm release name
export NAMESPACE="smart-scaler-backend"                        # Release namespace
export EGS_PROJECT="avesha"                                    # EGS project -> namespace kubeslice-<project>
export WORKDIR="$HOME/smart-scaler-run"                        # Holds the values file (contains secrets)

# ============ CHART: egs-poc at the validated commit ============
export CHART_REPO="https://github.com/kubeslice-ent/egs-poc.git"
export CHART_REF="3b63fe9"                                     # egs-poc PR #8 merge, chart 0.2.0
export REPO_DIR="$WORKDIR/egs-poc"
export CHART="$REPO_DIR/charts/egs-saas-charts/smart-scaler-app"

mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR" && cd "$WORKDIR"
[ -d "$REPO_DIR/.git" ] || git clone --quiet "$CHART_REPO" "$REPO_DIR"
git -C "$REPO_DIR" fetch --quiet origin && git -C "$REPO_DIR" checkout --quiet --detach "$CHART_REF"
git -C "$REPO_DIR" log -1 --format='%h %s'          # expect: 3b63fe9 Merge pull request #8 ...
grep -E '^(version|appVersion):' "$CHART/Chart.yaml"  # expect: appVersion: 3.3.0 and version: 0.2.0

# ============ ONE HOSTNAME FOR UI AND API ============
export APP_HOST="smart-scaler.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
echo "$APP_HOST"    # dell-poc: smart-scaler.apps.egs-dell-poc.ocp.aveshalabs.io
```

> **Keep `NAMESPACE=smart-scaler-backend` unless you have a reason to change it.**
> - egs-poc's `openshift-scc-grants.sh` grants `anyuid` to `smart-scaler-backend:smart-scaler-ui` by name.
> - If you change the namespace, use the Step 3b command, which uses `$NAMESPACE`, instead of the script.
> - `APP_HOST` must stay one label under `*.apps`, so that the router's wildcard certificate covers it.

---

## Step 2 – Pre-flight checks

**2a. Confirm the cluster, your rights and the Route API.**
```bash
oc whoami
oc whoami --show-server                                   # API URL of the EGS controller cluster
oc auth can-i '*' '*' --all-namespaces                    # expect: yes (cluster-admin, needed for Step 3b)
oc get svc kubeslice-api-gw -n kubeslice-controller -o jsonpath='{.spec.ports[*].port}{"\n"}'   # expect: 8080
oc get ns "kubeslice-$EGS_PROJECT"                        # expect: Active
oc api-resources --api-group=route.openshift.io -o name   # expect: routes.route.openshift.io
```
Stop if any of these fails. You're on the wrong cluster, you lack rights, or EGS isn't installed.

**2b. Decide how the EGS admin Secret is handled.**
```bash
if oc get secret egs-admin-details -n smart-scaler-controller >/dev/null 2>&1; then
  oc get secret egs-admin-details -n smart-scaler-controller -o json \
    | jq -r '"EXISTS  helm-release=\(.metadata.annotations["meta.helm.sh/release-name"] // "none")  has-token-key=\(.data.token != null)"'
else
  echo "NOT FOUND"
fi
```
This never prints the token itself.

| Result | Path | Setting |
|---|---|---|
| `NOT FOUND` | **A: Helm owns the Secret** | `MANAGE_ADMIN_SECRET=true`, and an EGS admin token is required |
| `EXISTS …` (any `helm-release`) | **B: Reuse the existing Secret** | `MANAGE_ADMIN_SECRET=false`. `has-token-key` must be `true` |

```bash
export MANAGE_ADMIN_SECRET=true    # Path A (dell-poc today)
# export MANAGE_ADMIN_SECRET=false # Path B
```

> **Why path B exists.** If `egs-admin-details` already exists, created by hand or by another release, installing with `manageAdminSecret=true` fails with Helm's *"exists and cannot be imported into the current release: invalid ownership metadata"*. Path B reuses the Secret and only adds this release's read permission.

**2c. Read the EGS admin token.** You need it for path A. For path B it's only needed if the existing token has to be refreshed (see [Day-2](#day-2-operations)).
```bash
export EGS_ADMIN_TOKEN="$(oc get secret "kubeslice-rbac-rw-admin" -n "kubeslice-$EGS_PROJECT" \
  -o jsonpath='{.data.token}' | base64 -d)"
echo "token length: ${#EGS_ADMIN_TOKEN}"   # must be > 0
```

> Use this Secret-based token. It's long-lived and the same one the EGS UI login uses. **Don't** use `oc create token` or `kubectl create token`: those tokens expire (1 hour by default), and the backend then gets `401` from EGS.

**2d. Check that the app hostname resolves from your machine.**
```bash
getent hosts "$APP_HOST" || nslookup "$APP_HOST"   # expect: the address of the default router's load balancer
```
If it doesn't resolve, the `*.apps` wildcard DNS isn't visible from your network (VPN or DNS). Users' machines need the same.

---

## Step 3 – Namespaces, SCC grant and MySQL check

**3a. Create both namespaces.** This is idempotent. **The chart doesn't create `smart-scaler-controller`**, but it puts the Role and RoleBinding there (plus the Secret on path A).
```bash
for ns in "$NAMESPACE" smart-scaler-controller; do
  oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
done
```
Both namespaces are also in egs-poc's `namespace-input.yaml`, so `create-namespaces.sh` runs for EGS create them too.

**3b. Let the UI run as root (`anyuid`).** Without this the UI pod crash-loops; see [Troubleshooting → OpenShift](#openshift-the-ui-needs-anyuid).

> **Needs cluster-admin.** Run this as the cluster admin. The grant is made by ServiceAccount name, so it works before Helm creates the account in Step 5. It covers the UI's own ServiceAccount only. The backend stays on `restricted-v2`.

```bash
oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NAMESPACE:smart-scaler-ui"

# verify
oc get clusterrolebinding system:openshift:scc:anyuid \
  -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}/{.name}{"\n"}{end}' | grep smart-scaler-ui
# expect one line, e.g. ServiceAccount:smart-scaler-backend/smart-scaler-ui
```
With the default namespace, `"$REPO_DIR/openshift-scc-grants.sh" apply` makes the same grant, because egs-poc keeps every OpenShift grant in that script. It also re-applies all the EGS grants, which is harmless because they're idempotent.

**3c. Check that MySQL is reachable from a pod in the release namespace.**
```bash
oc run mysql-reach-check -n "$NAMESPACE" --rm -i --restart=Never --image=busybox:1.36 -- \
  nc -zv -w 5 "<mysql-host>" "<mysql-port>"     # expect: ... open
```
This pod runs under `restricted-v2` and needs no grant. Pod Security warnings printed by `oc run` are harmless. If the nodes can't pull `busybox` from Docker Hub, use any image they can pull that contains `nc`.

---

## Step 4 – Create the values file

The file is built with `yq` from environment variables. Passwords that contain `, = ' " \ $` are kept exactly; plain `helm --set` breaks on a comma.

```bash
# ============ CUSTOMIZE THESE VALUES ============
export MYSQL_HOST="<mysql-host>"
export MYSQL_PORT="3306"
export MYSQL_USER="<mysql-user>"
read -rsp "MySQL password: " MYSQL_PASSWORD && echo && export MYSQL_PASSWORD   # not echoed, not in shell history
export MYSQL_DB="<mysql-database>"
export DOMAIN_EXCLUSION_LIST="avesha.io"   # internal POC; for a customer: their domain(s), comma-separated, or ""

# ============ GENERATED ONCE - KEEP THESE ============
export ACCESS_TOKEN_SECRET="$(openssl rand -hex 32)"
export REFRESH_TOKEN_SECRET="$(openssl rand -hex 32)"
export ENCRYPTION_SECRET="$(openssl rand -hex 16)"     # exactly 32 characters

( umask 077; yq -n '
  .backend.mysql.hostname           = strenv(MYSQL_HOST)           |
  .backend.mysql.port               = env(MYSQL_PORT)              |
  .backend.mysql.username           = strenv(MYSQL_USER)           |
  .backend.mysql.password           = strenv(MYSQL_PASSWORD)       |
  .backend.mysql.dbname             = strenv(MYSQL_DB)             |
  .backend.secrets.accessTokenSecret  = strenv(ACCESS_TOKEN_SECRET)  |
  .backend.secrets.refreshTokenSecret = strenv(REFRESH_TOKEN_SECRET) |
  .backend.secrets.encryptionSecret   = strenv(ENCRYPTION_SECRET)    |
  .backend.domainExclusionList      = strenv(DOMAIN_EXCLUSION_LIST) |
  .backend.service.type             = "ClusterIP"                  |
  .ui.service.type                  = "ClusterIP"                  |
  .route.enabled                    = true                         |
  .route.host                       = strenv(APP_HOST)             |
  .egs.manageAdminSecret            = env(MANAGE_ADMIN_SECRET)     |
  .egs.adminToken                   = strenv(EGS_ADMIN_TOKEN)' > "$WORKDIR/smart-scaler-values.yaml" )

ls -l "$WORKDIR/smart-scaler-values.yaml"    # expect: -rw------- (600)
```

> **`smart-scaler-values.yaml` holds credentials.**
> - Keep it at mode `600`. Never commit it, and never paste it into chat or tickets.
> - Back it up somewhere secure. **Every later `helm upgrade` needs it**, especially `ENCRYPTION_SECRET`.

> **Why the external URLs aren't set.**
> - With `route.enabled=true`, the chart sets `backend.externalURL` and `ui.externalURL` to `https://$APP_HOST` itself, so both always use the same host over https.
> - Set them only if users reach the app through a different hostname. If you do, use `https://`, the same host for both, and no trailing `/`. The chart rejects a trailing `/`, and rejects `http://` behind the TLS Route.

---

## Step 5 – Validate and install

**5a. Lint and render offline.** Neither command changes the cluster.
```bash
helm lint "$CHART" -f "$WORKDIR/smart-scaler-values.yaml"      # expect: 1 chart(s) linted, 0 chart(s) failed
helm template "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$WORKDIR/smart-scaler-values.yaml" \
  --api-versions route.openshift.io/v1/Route | grep -c '^kind: Route'   # expect: 2
```
`helm lint` can't see the cluster's APIs, so it also prints `[INFO] Fail: route.enabled=true but the route.openshift.io/v1 Route API is not available …`. That line is expected. Only the last line, `0 chart(s) failed`, matters. Step 5b checks the Route against the real cluster.

**5b. Server-side dry run.** This validates against the live cluster, including the Route API, without changing anything.
```bash
helm install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$WORKDIR/smart-scaler-values.yaml" --dry-run=server >/dev/null \
  && echo "dry run OK"
```
The chart stops with a clear message in these cases:
- a MySQL or secret value is missing;
- `encryptionSecret` isn't exactly 32 characters;
- path A is chosen with no token;
- the Route API is missing, or `route.host` is empty;
- an external URL ends in `/`, or uses `http://` behind the TLS Route.

**5c. Install.** This is a single install; there's no second pass for URLs.
```bash
helm install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$WORKDIR/smart-scaler-values.yaml"
oc rollout status deploy/"$RELEASE-backend" -n "$NAMESPACE" --timeout=5m
oc rollout status deploy/"$RELEASE-ui"      -n "$NAMESPACE" --timeout=5m
```
The output lists the app URL, the health-check URL and the commands for Step 6. **Note in your change record** that you installed egs-poc `3b63fe9` (chart 0.2.0).

> **"Rolled out" doesn't mean "serving yet".** The chart has no readiness probes, so a pod counts as ready as soon as it starts. On a test cluster the UI's nginx took 2–4 minutes to start serving under its 200m CPU limit; until then the Route returns *Application is not available*. Step 6c waits for it.

---

## Step 6 – Verify

**6a. Pods and their SCCs**
```bash
oc get pods -n "$NAMESPACE" -o custom-columns='POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc,SA:.spec.serviceAccountName,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'
# expect: smart-scaler-ui-...       anyuid         smart-scaler-ui   Running   0
#         smart-scaler-backend-...  restricted-v2  default           Running   0
oc get role,rolebinding -n smart-scaler-controller | grep "$RELEASE"
oc logs deploy/"$RELEASE-backend" -n "$NAMESPACE" --tail=50
```

**6b. Routes**
```bash
oc get route -n "$NAMESPACE" -o custom-columns='NAME:.metadata.name,HOST:.spec.host,PATH:.spec.path,SERVICE:.spec.to.name,TLS:.spec.tls.termination,ADMITTED:.status.ingress[0].conditions[0].status'
# expect: smart-scaler-ui       <APP_HOST>  <none>  smart-scaler-ui       edge  True
#         smart-scaler-backend  <APP_HOST>  /api    smart-scaler-backend  edge  True
```

**6c. HTTPS checks from your machine.** The default router certificate is signed by the cluster's own ingress CA, so `curl` uses that CA.
```bash
oc get configmap default-ingress-cert -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' > "$WORKDIR/ingress-ca.crt"

for path in /api/v1/health-check /; do
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$WORKDIR/ingress-ca.crt" "https://$APP_HOST$path")
    [ "$code" = 200 ] && break; sleep 5
  done
  echo "$path -> $code"                     # expect: 200 for both (waits up to 5 minutes each)
done

curl -s --cacert "$WORKDIR/ingress-ca.crt" "https://$APP_HOST/apiconfig.json"   # expect: "VITE_BASE_URL": "https://<APP_HOST>/api/v1"
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "http://$APP_HOST/"     # expect: 302 https://<APP_HOST>/
```
If the cluster uses a publicly trusted certificate instead, drop `--cacert`. For a quick check only, `curl -k` skips verification.

**6d. Check the values the pods received**
```bash
oc get deploy "$RELEASE-backend" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.value)]}{.name}={.value}{"\n"}{end}' \
  | grep -E 'UI_URL|ALLOWED_ORIGINS|GATEWAY_URL|COOKIE_DOMAIN|EGS_BACKEND_URL'
# expect: UI_URL, ALLOWED_ORIGINS and GATEWAY_URL = https://<APP_HOST>; COOKIE_DOMAIN = <APP_HOST>
oc get deploy "$RELEASE-ui" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VITE_BASE_URL")].value}{"\n"}'
# expect: https://<APP_HOST>/api/v1
```

**6e. End-to-end test**
1. Open `https://<APP_HOST>` in a browser. With the default router certificate, the browser warns once until a trusted certificate is installed.
2. **Sign up** with a real email and password. No SMTP is configured, so `SKIP_EMAIL_VERIFICATION=true` marks the account as verified automatically. Google and GitHub sign-in are deliberately disabled; use the email form.
3. After about a minute, check that a `tenant-<hash>` workspace appeared in EGS:
   ```bash
   oc get sliceconfig -n "kubeslice-$EGS_PROJECT"
   ```
4. Sign in and deploy a model from the panel.

> **First install on dell-poc:** save the output of 6a, 6b and 6c. It replaces the expected values in [Troubleshooting → OpenShift](#openshift-the-ui-needs-anyuid) and the validation status at the top.

---

## Day-2 operations

Always change **`smart-scaler-values.yaml`** and run `helm upgrade` with it. That file is the single source of truth.

| Task | How |
|---|---|
| Change any value | Edit the value with `yq -i`, then `helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$WORKDIR/smart-scaler-values.yaml"` |
| **After changing MySQL or secret values** | The chart doesn't restart pods when a Secret changes. Run `oc rollout restart deploy/"$RELEASE-backend" -n "$NAMESPACE"` |
| Move to a newer chart commit | Set `CHART_REF` to the new egs-poc commit, re-run the `git checkout` from Step 1, then Step 5a, Step 5b with `helm upgrade … --dry-run=server`, and `helm upgrade` with the values file |
| Refresh the EGS admin token, path A | Re-read the token (Step 2c). Then run `yq -i '.egs.adminToken = strenv(EGS_ADMIN_TOKEN)' …`, `helm upgrade …`, and restart the backend |
| Refresh the EGS admin token, path B, Secret not owned by Helm | `oc create secret generic egs-admin-details -n smart-scaler-controller --from-literal=token="$EGS_ADMIN_TOKEN" --dry-run=client -o yaml \| oc apply -f -`, then restart the backend |
| Refresh the EGS admin token, path B, Secret owned by another release | Refresh it through **that** release |
| History and rollback | `helm history "$RELEASE" -n "$NAMESPACE"`, then `helm rollback "$RELEASE" <revision> -n "$NAMESPACE"`. **On OpenShift, don't roll back to a 0.1.0 revision:** 0.1.0 has no Routes, and its UI runs on the `default` ServiceAccount without `anyuid`, so the app becomes unreachable |
| Status and URLs again | `helm status "$RELEASE" -n "$NAMESPACE"` |
| Use your own certificate | Add `certificate`, `key` and `caCertificate` under `route.tls` in the values file and upgrade, or replace the cluster's default ingress certificate |

> Don't change `ENCRYPTION_SECRET` after the first install.

---

## Uninstall

```bash
helm uninstall "$RELEASE" -n "$NAMESPACE"
oc adm policy remove-scc-from-user anyuid "system:serviceaccount:$NAMESPACE:smart-scaler-ui"
```

> **Never run `openshift-scc-grants.sh revoke` to uninstall Smart Scaler.** It removes **every** EGS SCC grant: monitoring, `kubeslice-system`, `spire`, the NSM webhook and the ovpn-manager. That breaks EGS. Remove only the UI grant, as shown above.

**What `helm uninstall` removes:**
- the Deployments, Services, Routes and UI ServiceAccount;
- the ConfigMap and the backend Secret;
- the Role and RoleBinding in `smart-scaler-controller`;
- **on path A only, the `egs-admin-details` Secret.** If any other Smart Scaler release in this cluster reuses that Secret (path B), it loses EGS access.

**What it leaves:**
- both namespaces;
- the `anyuid` grant, until you remove it as shown above. A later `openshift-scc-grants.sh apply` adds it again, which is harmless without the release;
- the MySQL database;
- the EGS `tenant-*` workspaces created by sign-ups;
- on path B, `egs-admin-details`.

To remove everything, after confirming nothing else uses them:
```bash
oc delete namespace "$NAMESPACE"
# Only if no other release uses it:
# oc delete namespace smart-scaler-controller
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error: … is required` during install | A required value is missing from the values file | Re-run Step 4 with every variable set |
| `encryptionSecret must be exactly 32 characters, got N` | Wrong key length | `export ENCRYPTION_SECRET="$(openssl rand -hex 16)"`, then rebuild the values file |
| `egs.adminToken is required` | Path A without a token | Step 2c, or use path B if the Secret already exists |
| `Secret "egs-admin-details" … exists and cannot be imported into the current release` | Path A was used, but the Secret already exists | Use path B (`MANAGE_ADMIN_SECRET=false`) |
| `namespaces "smart-scaler-controller" not found` | The chart doesn't create that namespace | Step 3a |
| `route.enabled=true but the route.openshift.io/v1 Route API is not available` | Not an OpenShift cluster, or an offline `helm template` without the API | Check Step 2a. For offline rendering add `--api-versions route.openshift.io/v1/Route`. On plain Kubernetes use the [Appendix](#appendix--plain-kubernetes-nodeport-variant) |
| `route.host is required when route.enabled=true` | `APP_HOST` was empty when the values file was built | Step 1, then rebuild the values file |
| `… is "http://…" but the Route terminates TLS` or `… must not end with '/'` | An external URL was set by hand | Remove both external URLs from the values file (Step 4 note) |
| `failed parsing --set data: key "…" has no value` | A value passed with `--set` contains a comma | Use the values file from Step 4 instead of `--set` |
| Browser or curl: *Application is not available* (router 503) | The Route isn't admitted, the Service has no ready endpoints, or the UI is still starting | `oc get route,endpoints -n "$NAMESPACE"`. Wait up to 5 minutes after an install or restart (Step 5c note). Check that both Routes target port `http` |
| Browser certificate warning, or curl `SSL certificate problem` | The default router certificate is signed by the cluster's ingress CA | Use `--cacert` (Step 6c). For users, install a trusted certificate (Day-2) |
| `APP_HOST` doesn't resolve, or the connection times out | No wildcard DNS for `*.apps` on that network, or the router isn't reachable | Step 2d. Check DNS and VPN, and firewall rules for ports 443/80 |
| UI loads but sign-in or API calls fail (mixed content or CORS errors in the browser console) | An external URL was set to `http://` or to a different host than the page | Remove the external URLs so both default to `https://$APP_HOST` (Step 4 note) |
| Pods in `ImagePullBackOff` or `ErrImagePull` | The nodes can't reach `harbor.saas1.smart-scaler.io`: egress firewall, proxy or DNS. It's an anonymous pull, so credentials aren't the cause | `oc describe pod -n "$NAMESPACE" <pod>` shows the pull error. Open egress to the registry on 443, or set the cluster proxy |
| Backend `CrashLoopBackOff` right after start | Wrong MySQL details or MySQL not reachable, wrong secret length, or missing role ConfigMap | `oc logs deploy/"$RELEASE-backend" -n "$NAMESPACE" --previous`; check Step 3c |
| UI `CrashLoopBackOff`, exit code 1 | The `anyuid` grant is missing | [OpenShift](#openshift-the-ui-needs-anyuid), below |
| Backend logs show `401` from EGS | The EGS admin token has expired or rotated | Refresh the token (Day-2) and restart the backend |
| Backend can't reach `kubeslice-api-gw` | Wrong cluster, EGS not installed, or a NetworkPolicy blocks it | Step 2a. Allow traffic from `$NAMESPACE` to `kubeslice-controller` on port 8080 |
| Sign-up rejected for an email domain that already has an organization | One organization per email domain, by design | Add the domain to `backend.domainExclusionList` (comma-separated), then upgrade |
| No `tenant-*` workspace after sign-up | The backend can't reach EGS, or the token is invalid | Backend logs. Check the token and `kubeslice-api-gw` |

### OpenShift: the UI needs `anyuid`

**Cause**
- **The UI image is the stock nginx image with no `USER`.** It runs as root and listens on port 80.
- **Its start-up script writes into a root-owned folder.** `/docker-entrypoint.d/init.sh` writes `apiconfig.json` into `/usr/share/nginx/html`, and nginx then chowns `/var/cache/nginx`. Under the default `restricted-v2` SCC the pod runs as a random UID, so the container stops before nginx starts.

**Symptom.** Without the Step 3b grant, the UI pod restarts with exit code 1, and its log ends with:
```text
/docker-entrypoint.d/init.sh: line 4: can't create /usr/share/nginx/html/apiconfig.json: Permission denied
```
The backend isn't affected. It runs normally under `restricted-v2`.

**Confirm**
```bash
oc logs deploy/"$RELEASE-ui" -n "$NAMESPACE" --previous --tail=5
oc get pods -n "$NAMESPACE" -o custom-columns='POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc,SA:.spec.serviceAccountName,RESTARTS:.status.containerStatuses[0].restartCount'
# UI pod: SCC = restricted-v2 and restarts climbing -> the grant is missing
```

**Fix.** Make the Step 3b grant, then restart the UI so that SCC admission runs again:
```bash
oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NAMESPACE:smart-scaler-ui"
oc rollout restart deploy/"$RELEASE-ui" -n "$NAMESPACE"
oc rollout status deploy/"$RELEASE-ui" -n "$NAMESPACE" --timeout=5m
```

**Verify.** Run the `custom-columns` command again. The UI pod shows `anyuid` with ServiceAccount `smart-scaler-ui`, and the backend still shows `restricted-v2`. Then continue with Step 6.

**Why it's set up this way**
- **`anyuid` is the smallest grant that works.** It only lets the container keep its image's UID. There's no privileged mode and no host access. `nonroot-v2` refuses images that run as root.
- **The grant goes to the UI's own ServiceAccount** (`ui.serviceAccount`), so the backend doesn't run as root.
- **Don't set `seccompProfile` on the UI pod.** `anyuid` on the EGS clusters has no seccomp profiles and rejects the pod (see the comment in `openshift-scc-grants.sh`).
- **Don't drop ALL capabilities on the UI container.** nginx then exits with `chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)`.
- **Long-term fix:** a UI image that runs as non-root on port 8080 and writes `apiconfig.json` to an `emptyDir`. Then no SCC grant is needed.

---

## Values reference

Only the values you're likely to set. The defaults are those of chart 0.2.0 at egs-poc `3b63fe9`.

| Key | Default | Notes |
|---|---|---|
| `backend.mysql.hostname`, `.username`, `.password`, `.dbname` | `""` | **Required** |
| `backend.mysql.port` | `3306` | |
| `backend.secrets.accessTokenSecret`, `.refreshTokenSecret` | `""` | **Required**; any strings |
| `backend.secrets.encryptionSecret` | `""` | **Required**, exactly 32 characters, permanent |
| `backend.secrets.existingSecret` | `""` | Name of a Secret you manage yourself. It must contain all 8 keys: `MYSQL_USERNAME`, `MYSQL_PASSWORD`, `MYSQL_HOSTNAME`, `MYSQL_PORT`, `MYSQL_DBNAME`, `ACCESS_TOKEN_SECRET`, `REFRESH_TOKEN_SECRET`, `ENCRYPTION_SECRET`. The chart's own Secret is then skipped |
| `route.enabled` | `false` | `true` on OpenShift (Step 4). Creates the two Routes |
| `route.host` | `""` | **Required when `route.enabled`.** `smart-scaler.apps.<cluster-domain>` |
| `route.tls` | `termination: edge`, `insecureEdgeTerminationPolicy: Redirect` | Add `certificate`, `key` and `caCertificate` for your own certificate. `null` gives plain-HTTP Routes and `http://` URLs |
| `route.annotations` | `{}` | For example `haproxy.router.openshift.io/timeout: 120s` |
| `backend.externalURL`, `ui.externalURL` | `""` | With `route.enabled`, both default to `https://<route.host>`. Otherwise use the same host for both, with no trailing `/` |
| `backend.service.type`, `ui.service.type` | `NodePort` | `ClusterIP` on OpenShift (Step 4) |
| `ui.serviceAccount.create`, `.name` | `true`, `""` (gives `smart-scaler-ui`) | The UI's own ServiceAccount, which gets `anyuid` |
| `backend.podSecurityContext`, `backend.securityContext`, `ui.podSecurityContext`, `ui.securityContext` | `{}` | Rendered only when set. On OpenShift, don't set `runAsUser` or `fsGroup`. For the UI, see "Why it's set up this way" above |
| `egs.manageAdminSecret` | `true` | `false` reuses an existing `egs-admin-details` (path B) |
| `egs.adminToken` | `""` | **Required when `manageAdminSecret=true`** |
| `egs.namespace` | `kubeslice-controller` | Where `kubeslice-api-gw` runs |
| `egs.adminNamespace` | `smart-scaler-controller` | Fixed in the backend code. **Don't change it** |
| `backend.ginMode`, `backend.appEnv` | `debug`, `development` | POC defaults. Other values are untested |
| `backend.skipEmailVerification` | `true` | No SMTP in this setup |
| `backend.domainExclusionList` | `avesha.io` (chart) | Domains allowed to have several organizations. Step 4 sets it explicitly; for a customer, use their domain(s) or `""` |
| `backend.adminEmailId` | `admin@example.com` | |
| `backend.image.*`, `ui.image.*` | see section 1 | `pullPolicy: IfNotPresent` |
| `backend.resources` | 200m / 512Mi request, 1 CPU / 1Gi limit | |
| `ui.resources` | 50m / 128Mi request, 200m / 256Mi limit | |

---

## Appendix – Plain Kubernetes (NodePort) variant

Use this on a cluster without OpenShift Routes. Follow the main steps, using `kubectl` instead of `oc`, with these changes:

| Step | Change |
|---|---|
| 1 | Skip `APP_HOST` |
| 2 | In 2a, skip `oc whoami` and the Route API check. Skip 2d |
| 3 | Skip 3b (no SCCs). In 3c, `kubectl run` in `$NAMESPACE` works the same |
| 4 | Remove the four lines `.backend.service.type`, `.ui.service.type`, `.route.enabled` and `.route.host` from the `yq` command. The chart defaults are NodePort Services and no Route |
| 5 | Install as in 5a–5c. The external URLs stay empty until the NodePorts exist; set them as shown below |
| 6 | Use the NodePort URLs instead of `https://$APP_HOST`, plain `http://`, no `--cacert`. There's no SCC column |

The NodePort range (TCP 30000–32767) on at least one node must be reachable from users' browsers.

**Set the external URLs after the first install**
```bash
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
[ -z "$NODE_IP" ] && NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
# Override if users reach the cluster through another IP or DNS name:  NODE_IP="<reachable-ip-or-hostname>"
export BACKEND_URL="http://$NODE_IP:$(kubectl get svc "$RELEASE-backend" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')"
export UI_URL="http://$NODE_IP:$(kubectl get svc "$RELEASE-ui" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')"
echo "backend: $BACKEND_URL   ui: $UI_URL"     # neither may contain an empty host or port

yq -i '.backend.externalURL = strenv(BACKEND_URL) | .ui.externalURL = strenv(UI_URL)' "$WORKDIR/smart-scaler-values.yaml"
helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$WORKDIR/smart-scaler-values.yaml"
curl -s -o /dev/null -w '%{http_code}\n' "$BACKEND_URL/api/v1/health-check"   # expect: 200
```

> **Rules for the two NodePort URLs:**
> - **Use the same host for both.** The backend sets its login cookie for the UI's host.
> - **Leave off the trailing `/`.**
> - **Both must open from a user's browser**, not just from inside the cluster. Nodes without an `ExternalIP` fall back to the `InternalIP`, which often opens only inside the VPC.
