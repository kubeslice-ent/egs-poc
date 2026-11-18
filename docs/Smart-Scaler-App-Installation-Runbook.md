# Smart Scaler App Installation Runbook

## 1. Overview

This runbook installs the Smart Scaler app on the EGS controller cluster. One installer script does the checks, the installation and the verification. You then create the first user in the browser.

| Item | Value |
|---|---|
| What it installs | Smart Scaler backend, Smart Scaler UI, and a MySQL database for them |
| Where | The EGS controller cluster on OpenShift |
| Chart | `smart-scaler-app` 0.3.0 (app version 3.3.0), from the egs-poc repository |
| Time needed | About 10 minutes. The installer itself took about 2 minutes on dell-poc |
| Result | The Smart Scaler UI at `https://smart-scaler.apps.<cluster-domain>` |
| Validated | Steps 1 to 4, and an uninstall followed by a reinstall that kept the users, on the dell-poc controller cluster (OpenShift 4.20.42), 18 November 2026 |

> **IMPORTANT** This is a proof-of-concept setup: debug mode, development images, and a single MySQL pod with no backups. Don't use it as-is for production or customer environments.

#### What you need

- A workstation with `oc`, `helm` 3.x, `git`, `yq` v4, `jq`, `openssl` and `curl`.
- A cluster-admin kubeconfig for the EGS controller cluster.
- EGS controller and UI installed and healthy, with at least one registered worker cluster.
- Read access to `https://github.com/kubeslice-ent/egs-poc`.

The installer checks everything else and tells you what is missing.

## 2. Installation

### Step 1 – Get the installer package

_Where: Workstation_

```bash
git clone https://github.com/kubeslice-ent/egs-poc.git
cd egs-poc
```

### Step 2 – Run the installer

_Where: Workstation, against the EGS controller cluster_

```bash
./smart-scaler-install.sh --kubeconfig <absolute-path-to-controller-kubeconfig>
```

The installer runs six stages and stops at the first problem, with a message that says what to fix.

| Stage | What it does |
|---|---|
| 1. Pre-flight checks | Confirms the tools, cluster-admin access, OpenShift, the EGS controller and the app hostname |
| 2. Prepare the cluster | Creates two namespaces and lets the UI pod run as root |
| 3. Values file | Generates the passwords and writes all settings to one file |
| 4. Validate | Checks the chart, then does a dry run against the cluster |
| 5. Install | Installs the Helm release `smart-scaler` and waits for the three pods |
| 6. Verify | Checks the pods, the database, the EGS admin Secret, the Routes and the HTTPS addresses |

**Expected result:** every line shows `OK`, and the run ends like this:

```text
[6/6] Verify
  OK    backend pod Running (SCC restricted-v2, restarts 0)
  OK    mysql pod Running (SCC restricted-v2, restarts 0)
  OK    ui pod Running (SCC anyuid, restarts 0)
  OK    database: 15 tables
  OK    EGS admin Secret egs-admin-details present in smart-scaler-controller
  OK    routes: 2 admitted on smart-scaler.apps.<cluster-domain>
  OK    https://smart-scaler.apps.<cluster-domain>/api/v1/health-check -> 200
  OK    https://smart-scaler.apps.<cluster-domain>/ -> 200

Smart Scaler is installed and verified.

  UI:           https://smart-scaler.apps.<cluster-domain>
  Values file:  /home/<you>/smart-scaler-run/smart-scaler-values.yaml
```

> **WARNING** Back up the values file that the installer names in its last lines. It holds the generated passwords and the EGS admin token. Every later upgrade or reinstall needs it. Never commit it or paste it into chat or tickets.

> **TIP** The installer is safe to run again. It keeps what is already done. To repeat only the checks, add `--verify-only`.

### Step 3 – Create the first account

_Where: Browser_

1. Open the UI address that the installer printed. Accept the certificate warning: the cluster's own certificate authority signed the certificate.
2. On the sign-in page, click **Create an account**.
3. Fill in Full Name, Email, Company Name and Password. The password needs at least 8 characters, with an upper-case letter, a lower-case letter, a digit and a special character.
4. Click **Create An Account**. Don't use the Google or GitHub buttons: they are switched off.
5. The page says "Please check your email". Ignore it. No email is sent, and the account is already active.
6. Go to the sign-in page and sign in with the same email and password. You are the admin of the new organization.

> **WARNING** Keep the password safe. This setup sends no email, so there is no password reset.

### Step 4 – Check the EGS workspace

_Where: Workstation, against the EGS controller cluster_

The sign-up creates an EGS workspace named `tenant-<8 characters>` on every registered worker cluster, within a few seconds.

```bash
export KUBECONFIG=<absolute-path-to-controller-kubeconfig>
oc logs deploy/smart-scaler-backend -n smart-scaler-backend -c backend | grep "EGS workspace"
oc get sliceconfig -n kubeslice-avesha
```

**Expected result:** the log shows `EGS workspace created successfully: tenant-xxxxxxxx`, and the list contains the same `tenant-xxxxxxxx`.

If the log shows `Error creating EGS workspace`, fix the cause using [4. Troubleshooting](#4-troubleshooting), then sign up again with a different email address. The workspace is not retried.

#### Adding more users

- Each person signs up for themselves, as in Step 3. Each sign-up creates its own organization and workspace.
- Only one organization is allowed per email domain. `avesha.io` and public domains such as `gmail.com` are exempt.

## 3. After the installation

Run these from the `egs-poc` directory, with `KUBECONFIG` set to the controller cluster.

| Task | Command |
|---|---|
| Repeat the checks | `./smart-scaler-install.sh --kubeconfig <path> --verify-only` |
| See the status and addresses | `helm status smart-scaler -n smart-scaler-backend` |
| Apply a changed setting | Edit `~/smart-scaler-run/smart-scaler-values.yaml`, then run `helm upgrade smart-scaler charts/egs-saas-charts/smart-scaler-app -n smart-scaler-backend -f ~/smart-scaler-run/smart-scaler-values.yaml` |
| Restart the backend | `oc rollout restart deploy/smart-scaler-backend -n smart-scaler-backend` |
| Back up the database | `oc exec -n smart-scaler-backend smart-scaler-mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --no-tablespaces --single-transaction "$MYSQL_DATABASE"' > smart-scaler-db.sql` |

> **WARNING** Never change the MySQL user, password, database name or `encryptionSecret` in the values file. The database was created with them, and the app can't read its data afterwards.

#### Uninstall

```bash
./smart-scaler-install.sh --kubeconfig <absolute-path-to-controller-kubeconfig> --uninstall
```

The script lists what it will remove and what it keeps, then asks you to type `yes`.

| Command | Removes | Keeps |
|---|---|---|
| `--uninstall` | The Smart Scaler pods, Services and Routes, and the UI's `anyuid` grant | The database volume with every user and organization, both namespaces, the values file |
| `--uninstall --delete-data` | The same, plus the `smart-scaler-backend` namespace and the database volume: every user and organization is lost | The `smart-scaler-controller` namespace, the values file |

After a plain `--uninstall`, run the installer again to get Smart Scaler back with the same users. It reuses the values file in `~/smart-scaler-run`.

Neither command touches EGS: the EGS releases and their grants stay as they are. The EGS `tenant-*` workspaces created by sign-ups also stay in EGS.

> **IMPORTANT** Never run `openshift-scc-grants.sh revoke` to uninstall Smart Scaler. It removes every EGS grant and breaks EGS.

## 4. Troubleshooting

#### The installer stops with FAIL

| Message | Fix |
|---|---|
| `'<tool>' is not installed on this workstation` | Install the tool, then run the installer again |
| `this user is not cluster-admin` | Use a cluster-admin kubeconfig |
| `no OpenShift Route API` | This installer is for OpenShift only |
| `service kubeslice-api-gw (port 8080) not found` | The kubeconfig doesn't point to the EGS controller cluster, or EGS isn't installed |
| `no default StorageClass` | Run `oc get storageclass`, then run the installer again with `--storage-class <name>` |
| `cannot read the EGS admin token` | Check that the EGS project is `avesha`. If not, add `--project <name>` |
| `release 'smart-scaler' is installed but … is missing` | Restore the values file from your backup to `~/smart-scaler-run/` |
| `a MySQL volume from an earlier install exists` | Restore the values file. Or run the script with `--uninstall --delete-data`, which deletes all Smart Scaler data |
| `expects an existing Secret egs-admin-details` or `Secret egs-admin-details … is missing` | The Secret that holds the EGS admin token is gone from namespace `smart-scaler-controller`. Create it again with the key `token`, or set `egs.manageAdminSecret: true` and `egs.adminToken` in the values file. Then run the installer again, or the `helm upgrade` from section 3 if Smart Scaler is already installed |
| `MySQL did not become ready` | Run `oc get pod,pvc -n smart-scaler-backend`. A volume in `Pending` means a storage problem. `ImagePullBackOff` means the nodes can't reach `harbor.saas1.smart-scaler.io` on port 443 |
| `the backend did not become ready` | Run `oc logs deploy/smart-scaler-backend -n smart-scaler-backend -c db-migration`. `Access denied` means the values file doesn't match the existing database volume |
| `https://… -> 000` or `503` in stage 6 | The hostname doesn't resolve from your workstation, or the UI is still starting. Check DNS and VPN, then run with `--verify-only` |

#### Sign-up and sign-in

| Symptom | Fix |
|---|---|
| "<domain> is already registered. Contact your org admin" | Only one organization per email domain. Run the installer for a new install with `--domain-exclusion <domain>`, or add the domain to `backend.domainExclusionList` in the values file and run the `helm upgrade` from section 3 |
| "Email address is already registered" | Sign in instead |
| "Invalid request body" | A field is empty, or the password is too weak. See Step 3 |
| "Invalid Credentials" | Wrong email or password. Passwords are case-sensitive |
| Backend log: `Error creating EGS workspace` | `no registered clusters found`: register a worker cluster in EGS. `401`: the EGS admin token is wrong. `dial tcp`: the EGS gateway isn't reachable. Then sign up again with a different email |

#### Log messages you can ignore

The backend log shows errors about Redis, sending email, the billing service, notifications, and two `forbidden` ConfigMaps (`gpu-pricing-config`, `saas-versions-config`). These parts aren't included in this setup. Sign-up, sign-in and workspace creation work without them.

## 5. Reference

#### Installer options

| Option | Meaning | Default |
|---|---|---|
| `--kubeconfig <path>` | Cluster-admin kubeconfig of the EGS controller cluster. Required | |
| `--project <name>` | EGS project | `avesha` |
| `--workdir <dir>` | Where the values file is kept | `~/smart-scaler-run` |
| `--storage-class <name>` | StorageClass for the MySQL volume | The cluster's default class |
| `--domain-exclusion <list>` | Email domains that may have several organizations. Comma-separated, no spaces | `avesha.io` |
| `--verify-only` | Only run the checks on an existing install | |
| `--uninstall` | Remove Smart Scaler and keep its data | |
| `--delete-data` | With `--uninstall`: also delete the `smart-scaler-backend` namespace and the database volume | |
| `--yes` | With `--uninstall`: don't ask for confirmation | |

#### What gets installed

| Component | Details |
|---|---|
| Backend | Deployment `smart-scaler-backend` in namespace `smart-scaler-backend`. Its `db-migration` init container creates the 15 database tables before the backend starts |
| UI | Deployment `smart-scaler-ui` in the same namespace. Runs as root, with the `anyuid` grant for its own ServiceAccount only |
| MySQL | StatefulSet `smart-scaler-mysql` (MySQL 8.4) with an 8Gi volume, `data-smart-scaler-mysql-0` |
| Routes | `https://<host>/` to the UI and `https://<host>/api` to the backend, on one hostname |
| EGS access | Secret `egs-admin-details` and the permission to read it, in namespace `smart-scaler-controller` |
| Images | Four images from `harbor.saas1.smart-scaler.io`, pulled without credentials |

## 6. Known limitations

1. **Backend errors about missing parts.** The backend logs errors for billing, notifications and two ConfigMaps it may not read (`gpu-pricing-config`, `saas-versions-config`). Which UI pages depend on them hasn't been checked.
2. **Upgrade and restore aren't validated on OpenShift.** They were tested on a plain Kubernetes test cluster only. The backup command was run on dell-poc and worked.
