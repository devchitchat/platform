#!/bin/bash
# Apply all platform Kubernetes manifests in dependency order.
#
# This script is the trusted path for bootstrapping or re-syncing the full
# platform from scratch. It applies resources in the correct order so that
# dependencies (namespaces, CRDs, RBAC) exist before the workloads that need
# them. It is idempotent — safe to re-run at any time.
#
# It does NOT build or push images. For that, use the per-app deploy scripts:
#   apps/agent/deploy.sh
#   apps/social-gate/deploy.sh
#
# Usage (from anywhere):
#   ./platform/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_apply() {
  local file="${SCRIPT_DIR}/$1"
  echo "--- applying $1"
  kubectl apply -f "${file}"
}

# ---------------------------------------------------------------------------
# 1. Namespaces — must exist before anything else
# ---------------------------------------------------------------------------
_apply namespaces/namespaces.yaml
_apply infra/ci-runner/namespace.yaml

# ---------------------------------------------------------------------------
# 2. CRDs — must exist before controllers that watch these resources
# ---------------------------------------------------------------------------
_apply crds/joeyguerra.yaml
_apply crds/fieldmappings.yaml

# ---------------------------------------------------------------------------
# 3. RBAC — ServiceAccounts, Roles, ClusterRoles, bindings
#    mesh-system namespace is created inside mesh-gitops-controller/rbac.yaml
# ---------------------------------------------------------------------------
_apply infra/mesh-gitops-controller/rbac.yaml
_apply infra/apps-controller/rbac.yaml

# ---------------------------------------------------------------------------
# 4. Infrastructure workloads
# ---------------------------------------------------------------------------

# Registry — other infra components pull images through it
_apply infra/registry/deployment.yaml
_apply infra/registry/network-policy.yaml

# CI runner — depends on registry being present
_apply infra/ci-runner/deployment.yaml
_apply infra/ci-runner/service.yaml

# Controllers — depend on CRDs and RBAC being in place
_apply infra/apps-controller/deployment.yaml
_apply infra/mesh-gitops-controller/deployment.yaml
_apply infra/mesh-gitops-controller/service.yaml

# ---------------------------------------------------------------------------
# 5. Apps — deployed out-of-band (images must already be in the registry)
#    NOTE: infra/ci-runner/secret-template.yaml is intentionally skipped;
#          it is a documentation reminder, not a real manifest.
# ---------------------------------------------------------------------------
_apply apps/social-gate/deployment.yaml
_apply apps/agent/deployment.yaml

echo ""
echo "All manifests applied."
