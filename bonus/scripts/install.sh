#!/bin/bash
set -e

cd "$(dirname "$0")/.."   # always run from bonus/ regardless of caller's cwd

GITLAB_HOST="localhost:8090"
GITLAB_PROJECT_NS="root"
GITLAB_PROJECT_NAME="iot-bonus-manifests"
GITLAB_PROJECT_PATH="${GITLAB_PROJECT_NS}%2F${GITLAB_PROJECT_NAME}"   # URL-encoded for API
GITLAB_PROJECT_SLUG="${GITLAB_PROJECT_NS}/${GITLAB_PROJECT_NAME}"     # for clone URL

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

# --- Remove old GitHub-backed Application (part 3 now lives on GitLab) ---
if kubectl get application playground -n argocd >/dev/null 2>&1; then
  echo "Removing old GitHub-backed 'playground' Application (superseded by GitLab-backed one)..."
  kubectl delete application playground -n argocd
fi

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

# Wait for GitLab to actually respond through the tunnel, not just "sleep 3"
# NOTE: /api/v4/version requires auth (401 without a token), so we can't use
# curl -f against it pre-token. Hit the unauthenticated sign-in page instead
# and just check we get *any* HTTP response (2xx/3xx/401/etc), not a connection error.
echo "Waiting for GitLab to become reachable..."
for i in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${GITLAB_HOST}/users/sign_in" 2>/dev/null || echo "000")
  if [ "$CODE" != "000" ]; then
    echo "GitLab responding (HTTP $CODE)."
    break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    echo "ERROR: GitLab never responded at http://${GITLAB_HOST} (connection never succeeded)" >&2
    exit 1
  fi
done

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

# --- Ensure the GitLab project exists (create if missing) ---
HTTP_CODE=$(curl -s -o /tmp/project-check.json -w "%{http_code}" \
  --header "PRIVATE-TOKEN: $TOKEN" \
  "http://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT_PATH}")

if [ "$HTTP_CODE" = "200" ]; then
  echo "GitLab project '${GITLAB_PROJECT_SLUG}' already exists."
elif [ "$HTTP_CODE" = "404" ]; then
  echo "Creating GitLab project '${GITLAB_PROJECT_SLUG}'..."
  CREATE_CODE=$(curl -s -o /tmp/project-create.json -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $TOKEN" -X POST \
    "http://${GITLAB_HOST}/api/v4/projects?name=${GITLAB_PROJECT_NAME}&visibility=public")
  if [ "$CREATE_CODE" != "201" ]; then
    echo "ERROR: failed to create GitLab project (HTTP $CREATE_CODE)" >&2
    echo "Response:" >&2
    cat /tmp/project-create.json >&2
    echo "" >&2
    echo "Hint: if you previously deleted this project, GitLab may have the" >&2
    echo "path reserved under 'adjourned deletion'. Either wait for purge," >&2
    echo "hard-delete it via the admin API/UI, or change GITLAB_PROJECT_NAME above." >&2
    exit 1
  fi
else
  echo "ERROR: unexpected response checking project existence (HTTP $HTTP_CODE)" >&2
  cat /tmp/project-check.json >&2
  exit 1
fi

# --- Push manifests into the GitLab repo (works on empty OR existing repo) ---
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if ! git clone "http://root:${TOKEN}@${GITLAB_HOST}/${GITLAB_PROJECT_SLUG}.git" "$WORKDIR"; then
  echo "ERROR: git clone failed for http://${GITLAB_HOST}/${GITLAB_PROJECT_SLUG}.git" >&2
  echo "The project exists via API but clone failed - check GitLab is fully up and token has repo access." >&2
  exit 1
fi

mkdir -p "$WORKDIR/manifests"
cp confs/gitlab-app-deployment.yaml "$WORKDIR/manifests/deployment.yaml"
cp confs/gitlab-app-service.yaml "$WORKDIR/manifests/service.yaml"

cd "$WORKDIR"
git add manifests/
if ! git diff --cached --quiet; then
  git -c user.email="root@gitlab.local" -c user.name="root" commit -m "sync manifests" >/dev/null
  git push origin HEAD:main 2>/dev/null || git push origin HEAD:master
  echo "Manifests pushed to GitLab."
else
  echo "No manifest changes to push (already in sync)."
fi
cd - >/dev/null

# --- Argo CD Application pointing at the internal GitLab repo ---
kubectl apply -f confs/argocd-application-gitlab.yaml

echo ""
echo "Done."
echo "Argo CD UI:  https://localhost:8080  (admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
echo "GitLab UI:   http://localhost:8090   (root / $(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d))"
echo "GitLab repo: http://${GITLAB_HOST}/${GITLAB_PROJECT_SLUG}"