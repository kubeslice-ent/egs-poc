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
UI ServiceAccount name. create=true: ui.serviceAccount.name, else "smart-scaler-ui" (fixed,
not release-derived, so openshift-scc-grants.sh can grant it). create=false: the given
name, else the namespace's "default" ServiceAccount.
*/}}
{{- define "smart-scaler-app.uiServiceAccountName" -}}
{{- if .Values.ui.serviceAccount.create -}}
{{ .Values.ui.serviceAccount.name | default "smart-scaler-ui" }}
{{- else -}}
{{ .Values.ui.serviceAccount.name | default "default" }}
{{- end -}}
{{- end -}}

{{/*
Route host; required when route.enabled.
*/}}
{{- define "smart-scaler-app.routeHost" -}}
{{- if .Values.route.enabled -}}
{{ required "route.host is required when route.enabled=true (e.g. smart-scaler.apps.<cluster-domain>)" .Values.route.host }}
{{- end -}}
{{- end -}}

{{/*
External (browser-facing) URL. Explicit value wins; with route.enabled and no value it
is <scheme>://<route.host> (https when route.tls is set). Rejects a trailing "/" and an
http:// URL behind a TLS Route (browsers block that as mixed content).
Call with (dict "url" <value> "key" "<values key>" "root" $).
*/}}
{{- define "smart-scaler-app.externalURL" -}}
{{- $v := .root.Values -}}
{{- $url := .url -}}
{{- if and (not $url) $v.route.enabled -}}
{{- $url = printf "%s://%s" (ternary "https" "http" (not (empty $v.route.tls))) (include "smart-scaler-app.routeHost" .root) -}}
{{- end -}}
{{- if hasSuffix "/" $url -}}
{{- fail (printf "%s must not end with '/' (got %q)" .key $url) -}}
{{- end -}}
{{- if and $v.route.enabled (not (empty $v.route.tls)) (hasPrefix "http://" $url) -}}
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
