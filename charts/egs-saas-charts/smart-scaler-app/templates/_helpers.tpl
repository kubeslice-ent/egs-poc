{{/*
Name of the backend secret to reference - either the one this chart creates, or an
existing one the caller already manages.
*/}}
{{- define "smart-scaler-app.backendSecretName" -}}
{{- if .Values.backend.secrets.existingSecret -}}
{{ .Values.backend.secrets.existingSecret }}
{{- else -}}
{{ .Release.Name }}-backend-secrets
{{- end -}}
{{- end -}}

{{/*
mysql and dbMigration (added in 0.3.0) are read nil-safe too: with `--reuse-values` from an
older release both keys are absent, so both stay off and the backend keeps using
backend.mysql.* exactly as before.
*/}}

{{/*
"true" when the chart runs its own MySQL, else "".
*/}}
{{- define "smart-scaler-app.mysqlEnabled" -}}
{{- if (.Values.mysql | default dict).enabled }}true{{ end -}}
{{- end -}}

{{/*
In-cluster MySQL Service name and DNS name.
*/}}
{{- define "smart-scaler-app.mysqlName" -}}
{{ .Release.Name }}-mysql
{{- end -}}

{{- define "smart-scaler-app.mysqlHost" -}}
{{ include "smart-scaler-app.mysqlName" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/*
The five MYSQL_* env vars, shared by the backend and its dbMigration init container. With the
in-cluster MySQL, host and port are set here rather than read from the Secret, so an
existingSecret does not need (and cannot get wrong) MYSQL_HOSTNAME/MYSQL_PORT.
*/}}
{{- define "smart-scaler-app.mysqlEnv" -}}
{{- $secret := include "smart-scaler-app.backendSecretName" . -}}
- name: MYSQL_USERNAME
  valueFrom: { secretKeyRef: { name: {{ $secret }}, key: MYSQL_USERNAME } }
- name: MYSQL_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ $secret }}, key: MYSQL_PASSWORD } }
{{- if include "smart-scaler-app.mysqlEnabled" . }}
- name: MYSQL_HOSTNAME
  value: {{ include "smart-scaler-app.mysqlHost" . | quote }}
- name: MYSQL_PORT
  value: "3306"
{{- else }}
- name: MYSQL_HOSTNAME
  valueFrom: { secretKeyRef: { name: {{ $secret }}, key: MYSQL_HOSTNAME } }
- name: MYSQL_PORT
  valueFrom: { secretKeyRef: { name: {{ $secret }}, key: MYSQL_PORT } }
{{- end }}
- name: MYSQL_DBNAME
  valueFrom: { secretKeyRef: { name: {{ $secret }}, key: MYSQL_DBNAME } }
{{- end -}}

{{/*
Rejects MySQL settings that contradict each other. Renders nothing.
*/}}
{{- define "smart-scaler-app.validateMySQL" -}}
{{- if include "smart-scaler-app.mysqlEnabled" . -}}
{{- if .Values.backend.mysql.hostname -}}
{{- fail (printf "backend.mysql.hostname is %q but mysql.enabled=true runs MySQL in the cluster: leave hostname empty, or set mysql.enabled=false to use that MySQL" .Values.backend.mysql.hostname) -}}
{{- end -}}
{{- if and (not .Values.backend.secrets.existingSecret) (eq (lower (toString .Values.backend.mysql.username)) "root") -}}
{{- fail "backend.mysql.username must not be \"root\" with mysql.enabled=true: the MySQL image creates it as an extra application user, and root already exists" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Every value added in 0.2.0 is read nil-safe (`| default dict`, `| default "<0.1.0 value>"`):
`helm upgrade --reuse-values` from a 0.1.0 release reuses the old values, which have no
route/ui.serviceAccount/ginMode/appEnv keys, and must behave like 0.1.0 (default
ServiceAccount for the UI, GIN_MODE=debug, APP_ENV=development, no Route).
*/}}

{{/*
UI ServiceAccount name. create=true: ui.serviceAccount.name, else "smart-scaler-ui" (fixed,
not release-derived, so openshift-scc-grants.sh can grant it). create=false, or no
ui.serviceAccount at all (0.1.0 values): the given name, else the namespace's "default".
*/}}
{{- define "smart-scaler-app.uiServiceAccountName" -}}
{{- $sa := .Values.ui.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{ $sa.name | default "smart-scaler-ui" }}
{{- else -}}
{{ $sa.name | default "default" }}
{{- end -}}
{{- end -}}

{{/*
Route host; required when route.enabled.
*/}}
{{- define "smart-scaler-app.routeHost" -}}
{{- $route := .Values.route | default dict -}}
{{- if $route.enabled -}}
{{ required "route.host is required when route.enabled=true (e.g. smart-scaler.apps.<cluster-domain>)" $route.host }}
{{- end -}}
{{- end -}}

{{/*
Route spec.tls as YAML; "" = plain HTTP. Empty when route.tls is null, because Helm drops
null keys, so an absent key cannot be told apart from an explicit null.
*/}}
{{- define "smart-scaler-app.routeTLS" -}}
{{- with (.Values.route | default dict).tls }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
External (browser-facing) URL. Explicit value wins; with route.enabled and no value it
is <scheme>://<route.host> (https when route.tls is set). Rejects a trailing "/" and an
http:// URL behind a TLS Route (browsers block that as mixed content).
Call with (dict "url" <value> "key" "<values key>" "root" $).
*/}}
{{- define "smart-scaler-app.externalURL" -}}
{{- $route := .root.Values.route | default dict -}}
{{- $tls := include "smart-scaler-app.routeTLS" .root -}}
{{- $url := .url -}}
{{- if and (not $url) $route.enabled -}}
{{- $url = printf "%s://%s" (ternary "https" "http" (ne $tls "")) (include "smart-scaler-app.routeHost" .root) -}}
{{- end -}}
{{- if hasSuffix "/" $url -}}
{{- fail (printf "%s must not end with '/' (got %q)" .key $url) -}}
{{- end -}}
{{- if and $route.enabled (ne $tls "") (hasPrefix "http://" $url) -}}
{{- fail (printf "%s is %q but the Route terminates TLS: use https://, or browsers block the API calls as mixed content" .key $url) -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{- define "smart-scaler-app.uiExternalURL" -}}
{{- include "smart-scaler-app.externalURL" (dict "url" .Values.ui.externalURL "key" "ui.externalURL" "root" .) -}}
{{- end -}}

{{- define "smart-scaler-app.backendExternalURL" -}}
{{- include "smart-scaler-app.externalURL" (dict "url" .Values.backend.externalURL "key" "backend.externalURL" "root" .) -}}
{{- end -}}
