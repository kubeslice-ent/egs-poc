# Why gatewayapi-crds.yaml is not in crds/

On OpenShift the Ingress Operator owns the Gateway API CRDs and a
ValidatingAdmissionPolicy (`openshift-ingress-operator-gatewayapi-crd-admission`)
rejects any change to them, so `helm install` fails when this chart tries to
create them from `crds/gatewayapi-crds.yaml`.

The file was moved here so Helm only installs the Envoy Gateway CRDs in
`crds/generated/`. On a cluster WITHOUT managed Gateway API CRDs, move it back
to `crds/gatewayapi-crds.yaml` (or `kubectl apply --server-side` it first).
