#!/bin/bash
set -e

cd "$(dirname "$0")/.."   # always run from bonus/ regardless of caller's cwd

# --- Docker / K3d / kubectl / Helm ---
command -v docker >/dev/null 2>&1 || { curl -fsSL https://get.docker.com | sh; sudo usermod -aG docker "$USER"; }
command -v k3d >/dev/null 2>&1 || curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
command -v kubectl >/dev/null 2>&1 || {
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
}
command -v helm >/dev/null 2>&1 || curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Cluster ---
k3d cluster list | grep -q iot-cluster || \
  k3d cluster create iot-cluster --servers 1 --agents 0 -p "8888:8888@loadbalancer"

# --- Namespaces ---
for ns in argocd dev gitlab dev-gitlab; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Argo CD ---
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s

# --- Part 3 Application (GitHub-backed) ---
kubectl apply -f confs/argocd-application.yaml

# --- GitLab (Helm) ---
helm repo add gitlab https://charts.gitlab.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install gitlab gitlab/gitlab -n gitlab --version 9.11.10 \
  -f confs/gitlab-values.yaml --timeout 900s

kubectl -n gitlab wait --for=condition=ready pod -l app=webservice --timeout=1200s
kubectl -n gitlab wait --for=condition=ready pod -l app=sidekiq --timeout=1200s

# --- Background UI access (Argo CD + GitLab) ---
pgrep -f "port-forward svc/argocd-server" >/dev/null || {
  nohup kubectl -n argocd port-forward svc/argocd-server 8080:443 --address 0.0.0.0 \
    > /tmp/argocd-port-forward.log 2>&1 & disown
}
pgrep -f "port-forward svc/gitlab-webservice-default" >/dev/null || {
  nohup kubectl -n gitlab port-forward svc/gitlab-webservice-default 8090:8181 --address 0.0.0.0 \
    > /tmp/gitlab-port-forward.log 2>&1 & disown
}
sleep 3   # give the tunnels a moment to actually bind

# --- Programmatically create a GitLab API token for root ---
GITLAB_TOKEN_FILE="confs/.gitlab-root-token"
if [ ! -s "$GITLAB_TOKEN_FILE" ]; then
  TOKEN=$(kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner "
    u = User.find_by_username('root')
    existing = u.personal_access_tokens.find_by(name: 'automation')
    if existing
      puts 'EXISTING_TOKEN_CANNOT_BE_READ'
    else
      t = u.personal_access_tokens.create!(scopes: [:api, :write_repository], name: 'automation', expires_at: 365.days.from_now)
      puts t.token
    end
  " | grep '^glpat-')
  if [ -z "$TOKEN" ]; then
    echo "ERROR: failed to create GitLab token" >&2
    exit 1
  fi
  echo "$TOKEN" > "$GITLAB_TOKEN_FILE"
else
  TOKEN=$(cat "$GITLAB_TOKEN_FILE")
fi

# --- Create the GitLab project via API, if it doesn't already exist ---
PROJECT_EXISTS=$(curl -s --header "PRIVATE-TOKEN: $TOKEN" \
  "http://localhost:8090/api/v4/projects/root%2Fiot-bonus-manifests" | grep -c '"id"' || true)

if [ "$PROJECT_EXISTS" -eq 0 ]; then
  curl -s --header "PRIVATE-TOKEN: $TOKEN" -X POST \
    "http://localhost:8090/api/v4/projects?name=iot-bonus-manifests&visibility=public" > /dev/null
fi

# --- Push manifests into the GitLab repo ---
WORKDIR=$(mktemp -d)
git clone "http://root:${TOKEN}@localhost:8090/root/iot-bonus-manifests.git" "$WORKDIR" 2>/dev/null || true
mkdir -p "$WORKDIR/manifests"
cp confs/gitlab-app-deployment.yaml "$WORKDIR/manifests/deployment.yaml"
cp confs/gitlab-app-service.yaml "$WORKDIR/manifests/service.yaml"
cd "$WORKDIR"
git add manifests/
if ! git diff --cached --quiet; then
  git -c user.email="root@gitlab.local" -c user.name="root" commit -m "sync manifests" >/dev/null
  git push >/dev/null
fi
cd - >/dev/null
rm -rf "$WORKDIR"

# --- Argo CD Application pointing at the internal GitLab repo ---
kubectl apply -f confs/argocd-application-gitlab.yaml

echo ""
echo "Done."
echo "Argo CD UI:  https://localhost:8080  (admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
echo "GitLab UI:   http://localhost:8090   (root / $(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d))"