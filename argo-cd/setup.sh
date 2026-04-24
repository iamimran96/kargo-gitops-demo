#!/bin/bash
#
# Provisions three Kind workload clusters (dev, test, prod) and registers them
# with the Argo CD instance running on the existing management cluster.
#
# Registration is done by creating the Argo CD cluster Secret directly (instead
# of `argocd cluster add`) so the server URL uses the Docker DNS hostname
# (<cluster>-control-plane:6443), which is reachable from Argo CD pods inside
# the mgmt cluster — `127.0.0.1`/host ports are not.

set -e

cd "$(dirname "$0")"

MGMT_CONTEXT="${MGMT_CONTEXT:-kind-kargo}"

create_cluster_if_not_exists() {
  local name=$1
  local config=$2
  if kind get clusters | grep -q "^${name}$"; then
    echo "==> Cluster '${name}' already exists, skipping..."
  else
    echo "==> Creating cluster '${name}'..."
    kind create cluster --config "$config"
  fi
}

register_cluster() {
  local display_name=$1
  local kind_name=$2

  echo "==> Registering cluster '${display_name}'..."

  # Server URL reachable from Argo CD pods inside kind-kargo (Docker DNS)
  local server="https://${kind_name}-control-plane:6443"

  # Clean up any existing binding (roleRef is immutable, can't be patched)
  kubectl --context "kind-${kind_name}" delete clusterrolebinding argocd-manager-role-binding --ignore-not-found

  # Step 1: create ServiceAccount, RBAC, and token in target cluster
  kubectl --context "kind-${kind_name}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

  # Wait for token controller to populate the secret
  echo "    waiting for token..."
  for i in {1..15}; do
    local t
    t=$(kubectl --context "kind-${kind_name}" -n kube-system \
      get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null || echo "")
    [ -n "$t" ] && break
    sleep 1
  done

  # Step 2: extract token from target cluster
  local token
  token=$(kubectl --context "kind-${kind_name}" -n kube-system \
    get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)

  # Step 3: switch to mgmt cluster and create the Argo CD cluster secret directly
  kubectl config use-context "$MGMT_CONTEXT" >/dev/null

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${display_name}
  namespace: argo-cd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${display_name}
  server: ${server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF

  echo "    Registered ${display_name} -> ${server}"
}

echo "==> Using existing management cluster: $MGMT_CONTEXT"
kubectl config use-context "$MGMT_CONTEXT"

echo "==> Creating workload clusters..."
create_cluster_if_not_exists "dev"  "kind-clusters/dev-cluster.yaml"
create_cluster_if_not_exists "test" "kind-clusters/test-cluster.yaml"
create_cluster_if_not_exists "prod" "kind-clusters/prod-cluster.yaml"

echo "==> Registering workload clusters with Argo CD..."
register_cluster "dev"  "dev"
register_cluster "test" "test"
register_cluster "prod" "prod"

echo "==> Switching back to management cluster..."
kubectl config use-context "$MGMT_CONTEXT"
echo ""
echo "Done! Clusters registered and apps deployed."
