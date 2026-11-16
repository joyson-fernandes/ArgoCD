#!/usr/bin/env bash
# Seals the RMM keys for cluster mode (always-on). Run by the operator during the
# cut-over, before cluster copies start. The stand-alone server may be running or
# already scaled to 0; /data is read from its volume, read-only.
#
# Writes (overwrites) these files in manifests/rmm/, ready to commit:
#   rmm-ca-sealedsecret.yaml          CA certificate and key from /data/ca   (tls.crt, tls.key)
#   rmm-secrets-key-sealedsecret.yaml stored-secrets key from /data          (secrets.key)
#   rmm-nats-keys-sealedsecret.yaml   NEW callout account seed + RMM service user seed
#   rmm-nats-auth-sealedsecret.yaml   the two matching public keys (read by NATS)
# Offsite database backups come later (R2 bucket).
#
# Secret material is read from the cluster into a private temp folder, piped to
# kubeseal and deleted on exit. Nothing is printed except fingerprints and
# public keys. Nothing is committed, pushed or applied.
#
# Needs: kubectl (context pointing at the production cluster), kubeseal, openssl,
# and either nk on PATH or Go (go run github.com/nats-io/nkeys/nk).
#
# Usage: scripts/seal-rmm-keys.sh            (prompts for nothing)
set -euo pipefail
umask 077

NS=rmm
OUT="$(cd "$(dirname "$0")/.." && pwd)/manifests/rmm"
HELPER=rmm-seal-helper
NK_VERSION=v0.4.17
SEAL=(kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml)

die() { echo "seal-rmm-keys: $*" >&2; exit 1; }
for t in kubectl kubeseal openssl; do command -v "$t" >/dev/null || die "$t is not installed"; done
if command -v nk >/dev/null; then NK=(nk); elif command -v go >/dev/null; then NK=(go run "github.com/nats-io/nkeys/nk@${NK_VERSION}"); else die "install nk or Go"; fi

echo "kubectl context: $(kubectl config current-context)"
kubeseal "${SEAL[@]:1:4}" --fetch-cert >/dev/null || die "the sealed-secrets controller is not reachable"

TMP="$(mktemp -d)"
cleanup() {
  kubectl -n "$NS" delete pod "$HELPER" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # Overwrite before removing; best effort on copy-on-write filesystems.
  find "$TMP" -type f -exec sh -c 'dd if=/dev/zero of="$1" bs=1k count=8 conv=notrunc 2>/dev/null' _ {} \; 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- 1. Read /data from the stand-alone server's volume (read-only) -----------
# Works whether the stand-alone server is running or already scaled to 0: the
# node comes from the local-path volume, not from the server pod.
PV="$(kubectl -n "$NS" get pvc rmm-data -o jsonpath='{.spec.volumeName}')"
[ -n "$PV" ] || die "the rmm-data volume claim is missing or not bound"
NODE="$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')"
[ -n "$NODE" ] || die "could not find the node that holds the rmm-data volume"

# A read-only helper on the same node (local-path volumes are node-bound; RWO
# allows several pods on one node). The server image has no shell.
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HELPER
  namespace: $NS
  labels: {app: rmm-seal-helper, team: platform, env: production}
spec:
  nodeName: $NODE
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: read
      image: ghcr.io/cloudnative-pg/postgresql:16.4
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
      volumeMounts: [{name: data, mountPath: /data, readOnly: true}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: rmm-data, readOnly: true}
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$HELPER" --timeout=120s >/dev/null

mkdir -p "$TMP/ca"
kubectl -n "$NS" exec "$HELPER" -- cat /data/ca/ca.crt >"$TMP/ca/ca.crt"
kubectl -n "$NS" exec "$HELPER" -- cat /data/ca/ca.key >"$TMP/ca/ca.key"
kubectl -n "$NS" exec "$HELPER" -- cat /data/secrets.key >"$TMP/secrets.key"

openssl x509 -in "$TMP/ca/ca.crt" -noout >/dev/null 2>&1 || die "/data/ca/ca.crt is not a certificate"
# The key must belong to the certificate.
[ "$(openssl x509 -in "$TMP/ca/ca.crt" -noout -pubkey)" = "$(openssl pkey -in "$TMP/ca/ca.key" -pubout 2>/dev/null)" ] \
  || die "/data/ca/ca.key does not match /data/ca/ca.crt"
[ "$(wc -c <"$TMP/secrets.key" | tr -d ' ')" = 32 ] || die "/data/secrets.key is not a 32-byte key"

# --- 2. New NATS keys: callout issuer (account) and RMM service user ----------
"${NK[@]}" -gen account -pubout >"$TMP/issuer" 2>/dev/null
"${NK[@]}" -gen user -pubout >"$TMP/service" 2>/dev/null
sed -n 1p "$TMP/issuer" >"$TMP/callout.seed"
sed -n 1p "$TMP/service" >"$TMP/service.nk"
ISSUER_PUB="$(sed -n 2p "$TMP/issuer")"
SERVICE_PUB="$(sed -n 2p "$TMP/service")"
case "$ISSUER_PUB" in A*) ;; *) die "nk did not produce an account key" ;; esac
case "$SERVICE_PUB" in U*) ;; *) die "nk did not produce a user key" ;; esac

# --- 3. Seal ------------------------------------------------------------------
seal() { # name file
  "${SEAL[@]}" >"$OUT/$2.tmp"
  { echo "# Sealed by scripts/seal-rmm-keys.sh on $(date -u +%Y-%m-%d)."; cat "$OUT/$2.tmp"; } >"$OUT/$2"
  rm -f "$OUT/$2.tmp"
  echo "wrote manifests/rmm/$2"
}
labels() { kubectl label --local --dry-run=client -o yaml -f - app=rmm team=platform env=production; }

kubectl -n "$NS" create secret tls rmm-ca --cert="$TMP/ca/ca.crt" --key="$TMP/ca/ca.key" --dry-run=client -o yaml \
  | labels | seal rmm-ca rmm-ca-sealedsecret.yaml
kubectl -n "$NS" create secret generic rmm-secrets-key --from-file=secrets.key="$TMP/secrets.key" --dry-run=client -o yaml \
  | labels | seal rmm-secrets-key rmm-secrets-key-sealedsecret.yaml
kubectl -n "$NS" create secret generic rmm-nats-keys --from-file=callout.seed="$TMP/callout.seed" \
  --from-file=service.nk="$TMP/service.nk" --dry-run=client -o yaml \
  | labels | seal rmm-nats-keys rmm-nats-keys-sealedsecret.yaml
kubectl -n "$NS" create secret generic rmm-nats-auth --from-literal=CALLOUT_ISSUER="$ISSUER_PUB" \
  --from-literal=RMM_SERVICE_USER="$SERVICE_PUB" --dry-run=client -o yaml \
  | labels | seal rmm-nats-auth rmm-nats-auth-sealedsecret.yaml

echo
echo "CA fingerprint (must match the agents' pinned CA):"
openssl x509 -in "$TMP/ca/ca.crt" -noout -fingerprint -sha256
echo "callout issuer public key: $ISSUER_PUB"
echo "RMM service user public key: $SERVICE_PUB"
echo
echo "Next: review 'git diff manifests/rmm', commit, and continue the cut-over runbook."
