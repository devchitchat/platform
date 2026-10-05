#!/bin/bash
# Build and deploy the social-gate image out-of-band, bypassing the CI/GitOps pipeline.
#
# social-gate is intentionally excluded from mesh-gitops: deployment is managed
# here so the CI pipeline cannot overwrite secrets or reconfigure the namespace.
# Run this script from a Mac shell with kubectl access to rebuild and roll out.
#
# Usage (from anywhere):
#   ./platform/apps/social-gate/deploy.sh [/path/to/social-gate/src]
#
# The social-gate source defaults to ../../social-gate relative to this script
# (i.e. devchitchat/social-gate alongside devchitchat/platform).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$(cd "${SCRIPT_DIR}/../../../social-gate" 2>/dev/null && pwd)}"
DEPLOY_YAML="${SCRIPT_DIR}/deployment.yaml"
# Two addresses for the same in-cluster registry:
# REGISTRY       — used by Docker daemon commands (build, push). host.docker.internal
#                  resolves to the Mac host from inside the Colima VM.
# REGISTRY_LOCAL — used by Mac-native commands (curl, verify). host.docker.internal
#                  does not resolve on the Mac host itself, so we use 127.0.0.1.
REGISTRY="host.docker.internal:5001"
REGISTRY_LOCAL="http://127.0.0.1:5001"

if [ ! -d "${SRC}" ]; then
  echo "ERROR: social-gate source not found at ${SRC}"
  echo "Usage: $0 [/path/to/social-gate/src]"
  exit 1
fi

SHA=$(git -C "${SRC}" rev-parse --short HEAD)
IMAGE="${REGISTRY}/social-gate:${SHA}"
echo "Building social-gate@${SHA} from ${SRC}"

# --- port-forward ----------------------------------------------------------

_ensure_registry_portforward() {
  if curl -sf "http://127.0.0.1:5001/v2/" >/dev/null 2>&1; then
    return 0
  fi
  local stale
  stale=$(lsof -ti tcp:5001 2>/dev/null || true)
  if [ -n "${stale}" ]; then
    echo "Killing stale process(es) on port 5001: ${stale}"
    echo "${stale}" | xargs kill 2>/dev/null || true
    sleep 1
  fi
  echo "Starting port-forward to registry..."
  kubectl port-forward --address 0.0.0.0 svc/registry -n mesh-system 5001:5000 \
    &>/tmp/pf-registry.log &
  local pf_pid=$!
  for i in $(seq 1 15); do
    sleep 1
    curl -sf "http://127.0.0.1:5001/v2/" >/dev/null 2>&1 && break
    if [ "${i}" -eq 15 ]; then
      echo "ERROR: registry port-forward did not become ready"
      kill "${pf_pid}" 2>/dev/null
      return 1
    fi
  done
  echo "Port-forward ready (PID ${pf_pid})"
}

# --- blob verification -----------------------------------------------------

_verify_push() {
  local image_name="$1" tag="$2"
  local registry="${REGISTRY_LOCAL}"
  local accepts="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  echo "Verifying push: ${image_name}:${tag}..."

  local manifest_json
  manifest_json=$(curl -sf -H "Accept: ${accepts}" \
    "${registry}/v2/${image_name}/manifests/${tag}") || {
    echo "ERROR: could not fetch manifest ${image_name}:${tag}"; return 1
  }

  local manifest_digests
  manifest_digests=$(echo "${manifest_json}" | python3 -c "
import sys, json
m = json.load(sys.stdin)
mt = m.get('mediaType', '') or str(m.get('schemaVersion', ''))
if 'index' in mt:
    for mf in m.get('manifests', []): print('manifest:' + mf['digest'])
else:
    print('single:')
")

  local failed=0
  _check_blobs() {
    local mfst="$1"
    local digests
    digests=$(echo "${mfst}" | python3 -c "
import sys, json
m = json.load(sys.stdin)
if 'config' in m: print(m['config']['digest'])
for l in m.get('layers', []): print(l['digest'])
")
    while IFS= read -r digest; do
      [ -z "${digest}" ] && continue
      local got
      got=$(curl -sfL -r 0-0 "${registry}/v2/${image_name}/blobs/${digest}" | wc -c | tr -d ' ')
      if [ -z "${got}" ] || [ "${got}" -eq 0 ] 2>/dev/null; then
        echo "  EMPTY blob: ${digest}"; failed=1
      fi
    done <<< "${digests}"
  }

  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    if [ "${entry%%:*}" = "manifest" ]; then
      local sub
      sub=$(curl -sf -H "Accept: ${accepts}" \
        "${registry}/v2/${image_name}/manifests/${entry#*:}") || { failed=1; continue; }
      _check_blobs "${sub}"
    else
      _check_blobs "${manifest_json}"
    fi
  done <<< "${manifest_digests}"

  if [ "${failed}" -ne 0 ]; then
    echo "ERROR: ${image_name}:${tag} has empty blobs — push was incomplete. Re-run to retry."
    return 1
  fi
  echo "OK: ${image_name}:${tag} — all blobs present"
}

# --- build + push ----------------------------------------------------------

_ensure_registry_portforward

docker build -t "${IMAGE}" "${SRC}"
docker push "${IMAGE}"
_verify_push "social-gate" "${SHA}"

# --- get digest ------------------------------------------------------------
# docker buildx imagetools inspect makes HTTP calls from the Mac host directly,
# where host.docker.internal does not resolve. Use the registry API via the
# port-forward (127.0.0.1:5001) to read the canonical digest instead.

DIGEST=$(curl -sf -I \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
  "${REGISTRY_LOCAL}/v2/social-gate/manifests/${SHA}" \
  | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}')
case "${DIGEST}" in
  sha256:*) ;;
  *) echo "ERROR: could not read digest for social-gate:${SHA} from registry"; exit 1 ;;
esac
echo "Digest: ${DIGEST}"

# --- update manifest -------------------------------------------------------

# Rewrite the image line in-place (works on both macOS and Linux).
# Matches both tag-pinned (registry.local:5000/social-gate:tag) and
# digest-pinned (registry.local:5000/social-gate@sha256:...) forms.
tmp=$(mktemp)
sed "s|registry.local:5000/social-gate[@:].*|registry.local:5000/social-gate@${DIGEST}|g" \
  "${DEPLOY_YAML}" > "${tmp}"
mv "${tmp}" "${DEPLOY_YAML}"
echo "Updated ${DEPLOY_YAML}"

# --- apply -----------------------------------------------------------------

kubectl apply -f "${DEPLOY_YAML}"
kubectl rollout status deployment/social-gate -n social-gate --timeout=120s
