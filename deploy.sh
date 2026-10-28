#!/bin/bash
# Apply platform Kubernetes manifests in dependency order.
#
# This script is the trusted path for bootstrapping or re-syncing the platform.
# It applies resources in the correct order so that dependencies (namespaces,
# CRDs, RBAC) exist before the workloads that need them. Idempotent — safe to
# re-run at any time.
#
# It does NOT build or push images. For that, use the per-app deploy scripts:
#   apps/agent/deploy.sh        — build + push + apply agent
#   apps/social-gate/deploy.sh  — build + push + apply social-gate
#
# Usage:
#   ./deploy.sh                          — apply everything (bootstrap / full re-sync)
#   ./deploy.sh --component <name>       — apply one component only
#
# Components:
#   namespaces       namespaces/namespaces.yaml + infra/ci-runner/namespace.yaml
#   crds             crds/
#   rbac             infra/apps-controller/rbac.yaml
#   registry         infra/registry/
#   buildkitd        infra/ci-runner/buildkitd.yaml (RBAC, cert-gen Job, Deployment, Service, NetworkPolicy)
#   ci-runner        infra/ci-runner/deployment.yaml + service.yaml
#   apps-controller  infra/apps-controller/deployment.yaml
#   cloudflared      infra/cloudflared/deployment.yaml
#   social-gate      apps/social-gate/deployment.yaml
#   agent            apps/agent/deployment.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_apply() {
  local file="${SCRIPT_DIR}/$1"
  echo "--- applying $1"
  kubectl apply -f "${file}"
}

# ---------------------------------------------------------------------------
# Component functions
# ---------------------------------------------------------------------------

_component_namespaces() {
  _apply namespaces/namespaces.yaml
  _apply infra/ci-runner/namespace.yaml
}

_component_crds() {
  _apply crds/joeyguerra.yaml
  _apply crds/fieldmappings.yaml
}

_component_rbac() {
  _apply infra/apps-controller/rbac.yaml
}

_component_registry() {
  _apply infra/registry/deployment.yaml
  _apply infra/registry/network-policy.yaml
}

_component_buildkitd() {
  # Apply before ci-runner: the mesh-ci-runner pod won't start without the
  # buildkitd-certs Secret that the cert-gen Job creates.
  _apply infra/ci-runner/buildkitd.yaml
}

_component_ci_runner() {
  _apply infra/ci-runner/deployment.yaml
  _apply infra/ci-runner/service.yaml
}

_component_apps_controller() {
  _apply infra/apps-controller/deployment.yaml
}

_component_cloudflared() {
  _apply infra/cloudflared/deployment.yaml
}

_component_social_gate() {
  _apply apps/social-gate/deployment.yaml
}

_component_agent() {
  _apply apps/agent/deployment.yaml
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

COMPONENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --component)
      shift
      COMPONENT="${1:-}"
      [ -z "${COMPONENT}" ] && { echo "ERROR: --component requires a value"; exit 1; }
      ;;
    --component=*)
      COMPONENT="${1#--component=}"
      ;;
    *)
      echo "ERROR: unknown argument '$1'"
      echo "Usage: ./deploy.sh [--component <name>]"
      exit 1
      ;;
  esac
  shift
done

if [ -n "${COMPONENT}" ]; then
  FN="_component_$(echo "${COMPONENT}" | tr '-' '_')"
  if ! declare -f "${FN}" > /dev/null 2>&1; then
    echo "ERROR: unknown component '${COMPONENT}'"
    echo ""
    echo "Known components:"
    echo "  namespaces  crds  rbac  registry  buildkitd  ci-runner"
    echo "  apps-controller  cloudflared  social-gate  agent"
    exit 1
  fi
  "${FN}"
  echo ""
  echo "Done: ${COMPONENT}"
else
  # Full bootstrap in dependency order.
  # NOTE: infra/ci-runner/secret-template.yaml is intentionally skipped;
  #       it is a documentation reminder, not a real manifest.
  _component_namespaces
  _component_crds
  _component_rbac
  _component_registry
  _component_buildkitd
  _component_ci_runner
  _component_apps_controller
  _component_cloudflared
  _component_social_gate
  _component_agent
  echo ""
  echo "All manifests applied."
fi
