#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != *@sha256:* ]]; then
  echo "Usage: $0 REGISTRY/ORGANIZATION/IMAGE@sha256:DIGEST" >&2
  exit 2
fi

OC_BIN="${OC_BIN:-oc}"
NAMESPACE="${NAMESPACE:-customer-cicd}"
OIDC_ISSUER="${OIDC_ISSUER:-https://kubernetes.default.svc}"
CERTIFICATE_IDENTITY_REGEXP="${CERTIFICATE_IDENTITY_REGEXP:-^https://kubernetes.io/namespaces/${NAMESPACE}/serviceaccounts/pipeline$}"
TUF_URL="${TUF_URL:-https://$("$OC_BIN" get route -n trusted-artifact-signer -l app.kubernetes.io/component=tuf -o jsonpath='{.items[0].spec.host}')}"
RHTAS_CLIENT_IMAGE="${RHTAS_CLIENT_IMAGE:-$("$OC_BIN" get deployment cli-server -n trusted-artifact-signer -o jsonpath='{.spec.template.spec.containers[0].image}')}"
POD="verify-rhtas-signature-$(date +%s)"

cleanup() {
  "$OC_BIN" delete pod "$POD" -n "$NAMESPACE" --ignore-not-found=true >/dev/null
}
trap cleanup EXIT

cat <<EOF | "$OC_BIN" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: verify
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
          curl -fsSL http://cli-server.trusted-artifact-signer.svc:8080/clients/linux/cosign-amd64.gz -o /tmp/verify-cosign.gz
          gzip -d /tmp/verify-cosign.gz
          chmod +x /tmp/verify-cosign
          /tmp/verify-cosign initialize --mirror="${TUF_URL}" --root="${TUF_URL}/root.json"
          /tmp/verify-cosign verify --certificate-identity-regexp="${CERTIFICATE_IDENTITY_REGEXP}" --certificate-oidc-issuer="${OIDC_ISSUER}" "$1"
      volumeMounts:
        - name: registry-auth
          mountPath: /registry-auth
          readOnly: true
  volumes:
    - name: registry-auth
      secret:
        secretName: registry-auth
EOF

for _ in {1..90}; do
  phase="$("$OC_BIN" get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
  case "$phase" in
    Succeeded)
      "$OC_BIN" logs "$POD" -n "$NAMESPACE"
      exit 0
      ;;
    Failed)
      "$OC_BIN" logs "$POD" -n "$NAMESPACE" || true
      exit 1
      ;;
  esac
  sleep 2
done

"$OC_BIN" logs "$POD" -n "$NAMESPACE" || true
echo "Timed out waiting for signature verification" >&2
exit 1
