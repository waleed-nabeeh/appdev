#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"
NAMESPACE="${RHTAS_NAMESPACE:-trusted-artifact-signer}"
WORK_DIR="${1:-}"

if [[ -z "${WORK_DIR}" ]]; then
  echo "Usage: $0 /secure/path/rhtas-tsa" >&2
  exit 2
fi

if [[ -e "${WORK_DIR}/tsa.key.pem" || -e "${WORK_DIR}/tsa-password" ]]; then
  echo "Refusing to overwrite existing TSA material in ${WORK_DIR}" >&2
  exit 1
fi

umask 077
mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"

openssl genrsa -out "${WORK_DIR}/rootCA.key.pem" 4096
openssl req -x509 -new -key "${WORK_DIR}/rootCA.key.pem" -sha256 -days 3650 \
  -subj "/C=SA/O=Customer Demo/CN=Customer TSA Root CA" \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "${WORK_DIR}/rootCA.crt.pem"

openssl genrsa -out "${WORK_DIR}/intCA.key.pem" 4096
openssl req -new -key "${WORK_DIR}/intCA.key.pem" \
  -subj "/C=SA/O=Customer Demo/CN=Customer TSA Intermediate CA" \
  -out "${WORK_DIR}/intCA.csr.pem"
openssl x509 -req -in "${WORK_DIR}/intCA.csr.pem" \
  -CA "${WORK_DIR}/rootCA.crt.pem" -CAkey "${WORK_DIR}/rootCA.key.pem" \
  -CAcreateserial -out "${WORK_DIR}/intCA.crt.pem" -days 1825 -sha256 \
  -extfile <(printf '%s\n' 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    'extendedKeyUsage=critical,timeStamping' \
    'keyUsage=critical,keyCertSign,cRLSign')

openssl rand -base64 32 | tr -d '\r\n' >"${WORK_DIR}/tsa-password"
openssl genrsa -aes256 -passout "file:${WORK_DIR}/tsa-password" \
  -out "${WORK_DIR}/tsa.key.pem" 3072
openssl req -new -key "${WORK_DIR}/tsa.key.pem" \
  -passin "file:${WORK_DIR}/tsa-password" \
  -subj "/C=SA/O=Customer Demo/CN=Customer TSA" \
  -out "${WORK_DIR}/tsa.csr.pem"
openssl x509 -req -in "${WORK_DIR}/tsa.csr.pem" \
  -CA "${WORK_DIR}/intCA.crt.pem" -CAkey "${WORK_DIR}/intCA.key.pem" \
  -CAcreateserial -out "${WORK_DIR}/tsa.crt.pem" -days 730 -sha256 \
  -extfile <(printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
    'extendedKeyUsage=critical,timeStamping' \
    'keyUsage=critical,digitalSignature' \
    'subjectKeyIdentifier=hash')

cat "${WORK_DIR}/tsa.crt.pem" "${WORK_DIR}/intCA.crt.pem" \
  "${WORK_DIR}/rootCA.crt.pem" >"${WORK_DIR}/tsa.certchain.pem"

${OC_BIN} create secret generic tsa-signer-key -n "${NAMESPACE}" \
  --from-file=tsa.key.pem="${WORK_DIR}/tsa.key.pem" \
  --dry-run=client -o yaml | ${OC_BIN} apply -f -
${OC_BIN} create secret generic tsa-password -n "${NAMESPACE}" \
  --from-file=password="${WORK_DIR}/tsa-password" \
  --dry-run=client -o yaml | ${OC_BIN} apply -f -
${OC_BIN} create secret generic tsa-cert-chain -n "${NAMESPACE}" \
  --from-file=tsa.certchain.pem="${WORK_DIR}/tsa.certchain.pem" \
  --dry-run=client -o yaml | ${OC_BIN} apply -f -

echo "Created TSA secrets in namespace ${NAMESPACE}; private material remains in ${WORK_DIR}."
