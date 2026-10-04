# platform

Kubernetes manifests for the infrastructure layer of the devchitchat stack. Applied to the cluster by `mesh-gitops-controller`, which watches this repo and applies changes within 30s of a push.

## What this repo is

There are two GitOps controllers running in the cluster. Each watches a different repo and has a different permission scope:

| Controller | Watches | Scope |
|---|---|---|
| `mesh-gitops-controller` | **this repo** (`platform`) | ClusterRole — can create namespaces, CRDs, RBAC, and manage infra across all namespaces |
| `apps-controller` | `mesh-gitops` (`apps/`) | Namespaced Role — can only create/update resources in the `apps` namespace |

This repo is the higher-trust layer. Changes here can affect the cluster globally. The `mesh-gitops` repo is the lower-trust layer where app deployments live.

## What's here

```
apps/
  agent/
    deployment.yaml         agent pod + ServiceAccount + cross-namespace RBAC

crds/
  fieldmappings.yaml        CRDs for fieldmappings.com (ContactFormSubmission, etc.)
  joeyguerra.yaml           CRDs for joeyguerra.com (DiscoveryCallRequest, etc.)

infra/
  registry/
    deployment.yaml         in-cluster image registry (registry:2), NodePort 30500, daily GC sidecar

  ci-runner/
    namespace.yaml          ci namespace — privileged PodSecurity (needed for BuildKit SYS_ADMIN)
    service.yaml            mesh-ci-runner ClusterIP Service (port 7979 for mesh peering)
    deployment.yaml         CI runner pod: mesh + registry-proxy + registry-proxy-watchdog + buildkitd
    secret-template.yaml    instructions for creating registry-proxy-control-token (not committed)

  mesh-gitops-controller/
    rbac.yaml               ClusterRole + ClusterRoleBinding (broad — manages CRDs, namespaces, RBAC)
    deployment.yaml         controller pod: mesh-gitops-controller + mesh sidecar
    service.yaml            ClusterIP Service (port 7979 for mesh peering)

  apps-controller/
    rbac.yaml               Namespaced Role + RoleBinding (apps namespace only)
    deployment.yaml         controller pod: mesh-gitops-controller + mesh sidecar

namespaces/
  namespaces.yaml           apps and agent namespaces
```

## How changes get applied

```
push to platform repo
  → mesh-gitops-controller detects SHA change (polls every 30s)
    → kubectl apply on changed files within apps/, crds/, infra/, namespaces/
      → cluster state updated
```

The controller is self-hosting: once the initial bootstrap has deployed it, changes to `infra/mesh-gitops-controller/` are picked up and applied by the controller itself.

## Bootstrap vs steady state

During first-time setup, `local-k8s/bootstrap-mesh.sh` applies a subset of this repo manually (registry, ci-runner, mesh-gitops-controller). After that, `mesh-gitops-controller` takes over and this repo becomes the source of truth — push a change here and it lands in the cluster.

```
bootstrap-mesh.sh (one-time, run from local-k8s)
  kubectl apply infra/registry/deployment.yaml
  kubectl apply infra/mesh-gitops-controller/rbac.yaml
  kubectl apply infra/mesh-gitops-controller/deployment.yaml
  kubectl apply infra/ci-runner/namespace.yaml
  kubectl apply infra/ci-runner/service.yaml
  kubectl apply infra/ci-runner/deployment.yaml
  → after this, mesh-gitops-controller manages itself
```

## Secrets

Secrets are never committed. The only secret this repo depends on is `registry-proxy-control-token` in the `ci` namespace. See `infra/ci-runner/secret-template.yaml` for how to create it.

## Related repos

| Repo | Role |
|---|---|
| `local-k8s` | VM setup, CI/CD image sources, bootstrap script |
| `mesh-gitops` | App manifests (`apps/`) — watched by `apps-controller` |
| `platform` (this repo) | Infrastructure manifests — watched by `mesh-gitops-controller` |
