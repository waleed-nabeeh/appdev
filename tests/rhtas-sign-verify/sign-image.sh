#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 REGISTRY/PROJECT/IMAGE@sha256:DIGEST" >&2
  exit 2
fi

IMAGE="$1"
NAMESPACE="${NAMESPACE:-infra-platforms}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-pipeline}"
REGISTRY_SECRET="${REGISTRY_SECRET:-registry-auth}"
APPS_DOMAIN="${APPS_DOMAIN:-apps.hub-visa-ocp.mofa.gov.sa}"
RHTAS_CLIENT_IMAGE="${RHTAS_CLIENT_IMAGE:-quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/rhtas-client-server:1.4.3}"
POD="rhtas-sign-test-$(date +%s)"

cleanup() {
  oc delete pod "${POD}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null
}
trap cleanup EXIT

cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  serviceAccountName: ${SERVICE_ACCOUNT}
  containers:
    - name: cosign
      image: ${RHTAS_CLIENT_IMAGE}
      env:
        - name: HOME
          value: /tmp/home
        - name: DOCKER_CONFIG
          value: /registry-auth
      command: [bash, -c]
      args:
        - |
          set -euo pipefail
          mkdir -p "\$HOME"
          curl -fsSL \
            http://cli-server.trusted-artifact-signer.svc:8080/clients/linux/cosign-amd64.gz \
            -o /tmp/cosign.gz
          gzip -d /tmp/cosign.gz
          chmod +x /tmp/cosign
          /tmp/cosign version
          /tmp/cosign initialize \
            --mirror="https://tuf-trusted-artifact-signer.${APPS_DOMAIN}" \
            --root="https://tuf-trusted-artifact-signer.${APPS_DOMAIN}/root.json"
          TOKEN=\$(cat /var/run/sigstore/token)
          /tmp/cosign sign --yes \
            --use-signing-config=false \
            --identity-token="\${TOKEN}" \
            --fulcio-url="https://fulcio-server-trusted-artifact-signer.${APPS_DOMAIN}" \
            --rekor-url="https://rekor-server-trusted-artifact-signer.${APPS_DOMAIN}" \
            "${IMAGE}"
      volumeMounts:
        - name: oidc-token
          mountPath: /var/run/sigstore
          readOnly: true
        - name: registry-auth
          mountPath: /registry-auth
          readOnly: true
  volumes:
    - name: oidc-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: trusted-artifact-signer
              expirationSeconds: 600
    - name: registry-auth
      secret:
        secretName: ${REGISTRY_SECRET}
EOF

oc wait pod/${POD} -n "${NAMESPACE}" \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=180s
oc logs "${POD}" -n "${NAMESPACE}"
