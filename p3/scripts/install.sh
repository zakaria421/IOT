#!/bin/bash
set -e

# --- Docker ---
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
fi

# --- K3d ---
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# --- kubectl ---
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi

# --- Cluster ---
if ! k3d cluster list | grep -q iot-cluster; then
  k3d cluster create iot-cluster --servers 1 --agents 0 -p "8888:8888@loadbalancer"
fi

# --- Namespaces (idempotent) ---
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# --- Argo CD install (server-side apply: idempotent + avoids CRD size limit) ---
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# --- Wait for Argo CD to actually be ready before applying the Application ---
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s

# --- Deploy the Application pointing at your GitHub repo ---
kubectl apply -f confs/argocd-application.yaml

# --- Argo CD UI (background port-forward) ---
if ! pgrep -f "port-forward svc/argocd-server" >/dev/null; then
  nohup kubectl -n argocd port-forward svc/argocd-server 8080:443 --address 0.0.0.0 > /tmp/argocd-port-forward.log 2>&1 &
  disown
fi

echo "Argo CD UI: https://localhost:8080"

echo "Done. Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""