# Kargo GitOps Demo

A multi-cluster GitOps demo using **Argo CD**, **Kargo**, and **Kro** to manage progressive delivery of a Socket.IO application across dev, test, and prod environments running on Kind clusters.

## Architecture

```
                    Management Cluster (kind-kargo)
        ┌──────────────────────────────────────────────┐
        │  Argo CD          Kargo          cert-manager │
        │  (argo-cd ns)     (kargo ns)     (dev only)   │
        └──────┬───────────────┬───────────────────────┘
               │               │
    ┌──────────┼───────────────┼──────────┐
    │          │               │          │
    ▼          ▼               ▼          ▼
┌────────┐ ┌────────┐    ┌────────┐
│  dev   │ │  test  │    │  prod  │    Workload Clusters
│ :6444  │ │ :6445  │    │ :6446  │
├────────┤ ├────────┤    ├────────┤
│ Kro    │ │ Kro    │    │ Kro    │    Kro operator per cluster
│ Socket │ │ Socket │    │ Socket │    SocketIOApp instances
│ IO App │ │ IO App │    │ IO App │    (socket-io namespace)
│ (1 rep)│ │ (2 rep)│    │ (3 rep)│
└────────┘ └────────┘    └────────┘
```

## Promotion Flow (Kargo)

```
Warehouse (watches ximran96/node-socket)
    │
    ▼  auto-promote
   dev ──► updates products/dev/socket-io/socket-io-instance.yaml
    │
    ▼  manual
  test ──► updates products/test/socket-io/socket-io-instance.yaml
    │
    ▼  manual
  prod ──► updates products/prod/socket-io/socket-io-instance.yaml
```

## Cluster Ports

Each environment runs on a separate Kind cluster with its own API server port:

| Cluster | Context | API Server Port | Argo CD Server URL |
|---|---|---|---|
| Management | `kind-kargo` | 6443 (default) | — |
| Dev | `kind-dev` | 6444 | `https://dev-control-plane:6443` |
| Test | `kind-test` | 6445 | `https://test-control-plane:6443` |
| Prod | `kind-prod` | 6446 | `https://prod-control-plane:6443` |

> **Host ports** (6444/6445/6446) are for `kubectl` access from your machine.
> **Argo CD** uses Docker-internal DNS (`<cluster>-control-plane:6443`) to reach the workload clusters since it runs inside the Kind Docker network.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Argo CD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional)

## Quick Start

### 1. Create the management cluster

```bash
kind create cluster --name kargo
```

### 2. Install Argo CD on the management cluster

```bash
helm install argocd argo/argo-cd \
  --namespace argo-cd --create-namespace \
  --wait
```

### 3. Install Kargo

```bash
helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo --create-namespace \
  --set controller.argocd.namespace=argo-cd \
  --set api.adminAccount.passwordHash='<bcrypt-hash>' \
  --set api.adminAccount.tokenSigningKey='<signing-key>' \
  --wait
```

> The management cluster (`kind-kargo`) is created manually. The setup script below only creates the workload clusters.

### 4. Create workload clusters and register them with Argo CD

```bash
bash argo-cd/setup.sh
```

This creates the three workload clusters (dev, test, prod) and registers them with the Argo CD instance running on the management cluster.

### 5. Bootstrap the app-of-apps

```bash
kubectl apply -f app-of-apps/ --context kind-kargo
```

This deploys everything through GitOps:
- Platform addons (Kargo, cert-manager)
- Per-environment addons (Kro operator)
- ApplicationSets (RGD + product instances)
- Kargo pipeline (Project, Warehouse, Stages)

### 6. Set up Kargo git credentials

Kargo needs write access to push image updates to this repo:

```bash
kubectl create secret generic git-credentials \
  --namespace=socket-io \
  --context=kind-kargo \
  --from-literal=repoURL=https://github.com/iamimran96/kargo-gitops-demo.git \
  --from-literal=username=<your-github-username> \
  --from-literal=password=<your-github-pat>

kubectl label secret git-credentials \
  --namespace=socket-io \
  --context=kind-kargo \
  kargo.akuity.io/cred-type=git
```

### 7. Push a new image to trigger a promotion

```bash
docker build -t ximran96/node-socket:1.0.0 .
docker push ximran96/node-socket:1.0.0
```

Kargo detects the new semver tag, creates Freight, and auto-promotes to dev. Promote to test and prod manually via the Kargo UI or CLI.

## Repository Structure

```
.
├── app-of-apps/                    # Top-level Argo CD Applications (bootstrap)
│   ├── addon-platform.yaml         #   -> syncs addon/platform/
│   ├── addon-dev.yaml              #   -> syncs addon/dev/
│   ├── addon-test.yaml             #   -> syncs addon/test/
│   ├── addon-prod.yaml             #   -> syncs addon/prod/
│   ├── application-sets.yaml       #   -> syncs application-sets/
│   └── kargo-apps.yaml             #   -> syncs kargo/apps/
│
├── addon/                          # Per-environment Argo CD Applications
│   ├── platform/                   #   Kargo + cert-manager (mgmt cluster)
│   ├── dev/                        #   Kro operator -> dev cluster
│   ├── test/                       #   Kro operator -> test cluster
│   ├── prod/                       #   Kro operator -> prod cluster
│   └── charts/                     #   Vendored Helm charts
│       ├── kargo/                  #     Kargo v1.10.2
│       ├── kro/                    #     Kro v0.4.1
│       └── cert-manager/           #     cert-manager v1.18.2
│
├── application-sets/               # Argo CD ApplicationSets
│   ├── socket-io-rgd-appset.yaml   #   Deploys Kro RGD to all clusters
│   └── socket-io-products-appset.yaml  # Deploys SocketIOApp per env
│
├── kro/                            # Kro ResourceGraphDefinitions
│   └── socket-io-rgd.yaml          #   Defines SocketIOApp -> Deployment + Service
│
├── products/                       # Product instances per environment
│   ├── dev/socket-io/              #   dev: 1 replica
│   ├── test/socket-io/             #   test: 2 replicas
│   └── prod/socket-io/             #   prod: 3 replicas
│
├── kargo/                          # Kargo release management
│   ├── apps/                       #   Argo CD Apps for Kargo pipelines
│   │   └── socket-io-release-management.yaml
│   └── products/socket-io/pipeline/  # Kargo pipeline resources
│       ├── project.yaml            #     Kargo Project
│       ├── project-config.yaml     #     Auto-promotion policy (dev)
│       ├── warehouse.yaml          #     Watches ximran96/node-socket
│       ├── stage-dev.yaml          #     Dev stage (auto-promote)
│       ├── stage-test.yaml         #     Test stage (manual)
│       ├── stage-prod.yaml         #     Prod stage (manual)
│       └── git-credentials.yaml    #     Git credentials template
│
└── argo-cd/                        # Cluster provisioning
    ├── setup.sh                    #   Creates Kind clusters + registers with Argo CD
    └── kind-clusters/              #   Kind cluster configs
        ├── dev-cluster.yaml        #     API on port 6444
        ├── test-cluster.yaml       #     API on port 6445
        └── prod-cluster.yaml       #     API on port 6446
```

## Key Technologies

| Technology | Version | Purpose |
|---|---|---|
| [Argo CD](https://argo-cd.readthedocs.io/) | latest | GitOps continuous delivery |
| [Kargo](https://kargo.io/) | v1.10.2 | Progressive delivery and promotion |
| [Kro](https://kro.run/) | v0.4.1 | Kubernetes Resource Orchestrator (custom APIs) |
| [cert-manager](https://cert-manager.io/) | v1.18.2 | TLS certificate management |
| [Kind](https://kind.sigs.k8s.io/) | latest | Local multi-cluster setup |

## How It Works

1. **Kro** defines a `ResourceGraphDefinition` that creates a `SocketIOApp` custom resource, which expands into a Deployment + Service.

2. **Argo CD ApplicationSets** deploy the Kro RGD and SocketIOApp instances to all three workload clusters, each in the `socket-io` namespace.

3. **Kargo** watches Docker Hub for new semver-tagged images of `ximran96/node-socket`. When a new tag is detected:
   - Freight is created
   - Dev is auto-promoted (clones repo, updates image in YAML, commits, pushes, syncs Argo CD)
   - Test and prod require manual promotion

4. **Argo CD** detects the Git changes and syncs the updated manifests to the target clusters.

## Adding a New Product

To add another product (e.g., `nginx-app`):

1. Create a Kro RGD in `kro/`
2. Add instance files in `products/{dev,test,prod}/nginx-app/`
3. Create an ApplicationSet in `application-sets/`
4. Create a Kargo pipeline in `kargo/products/nginx-app/pipeline/`
5. Add an Argo CD App in `kargo/apps/`

The Kargo Project, ProjectConfig, and git credentials are shared across products.
