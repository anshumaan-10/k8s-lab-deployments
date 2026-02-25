#!/usr/bin/env bash
# setup-kind.sh — Spin up the full k8s-security-lab on kind (local)
#
# Prerequisites:
#   brew install kind kubectl
#   Docker Desktop running
#
# Usage:
#   ./cluster/setup-kind.sh [--dockerhub-token <token>]
#
# What this does:
#   1. Creates a kind cluster (k8s-security-lab)
#   2. Installs ArgoCD
#   3. Creates namespaces + Docker Hub pull secret
#   4. Bootstraps the App-of-Apps → deploys phoenix, payment-api, checkout
#   5. Prints ArgoCD admin password and access URL

set -euo pipefail

CLUSTER_NAME="k8s-security-lab"
ARGOCD_VERSION="v2.13.3"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-anshumaan10}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"

# ── Parse flags ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dockerhub-token) DOCKERHUB_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       k8s-security-lab — local kind setup               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Create kind cluster ───────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[1/6] kind cluster '${CLUSTER_NAME}' already exists — skipping"
else
  echo "[1/6] Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Install ArgoCD ────────────────────────────────────────────
echo ""
echo "[2/6] Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "      Waiting for ArgoCD pods to be ready (up to 3 min)..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=180s

# ── 3. Patch ArgoCD server to NodePort for kind access ──────────
echo ""
echo "[3/6] Patching ArgoCD server to NodePort 30443..."
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30443}]}}'

# ── 4. Create namespaces and pull secrets ────────────────────────
echo ""
echo "[4/6] Creating namespaces and Docker Hub pull secrets..."

kubectl apply -f "${REPO_ROOT}/namespaces.yaml"

if [[ -n "${DOCKERHUB_TOKEN}" ]]; then
  for NS in web payments; do
    kubectl create secret docker-registry dockerhub-secret \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="${DOCKERHUB_USERNAME}" \
      --docker-password="${DOCKERHUB_TOKEN}" \
      --namespace "${NS}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  echo "      Pull secrets created."
else
  echo "      WARN: --dockerhub-token not provided."
  echo "      Images are public so pods will still work, but if you"
  echo "      push private images you will need to create the secret manually:"
  echo ""
  echo "        kubectl create secret docker-registry dockerhub-secret \\"
  echo "          --docker-server=https://index.docker.io/v1/ \\"
  echo "          --docker-username=anshumaan10 \\"
  echo "          --docker-password=<token> \\"
  echo "          --namespace web"
  echo ""
fi

# ── 5. Bootstrap App-of-Apps ─────────────────────────────────────
echo ""
echo "[5/6] Bootstrapping ArgoCD App-of-Apps..."
kubectl apply -f "${REPO_ROOT}/argocd/app-of-apps.yaml"

# ── 6. Print access info ─────────────────────────────────────────
echo ""
echo "[6/6] Getting ArgoCD admin password..."
ARGOCD_PASSWORD=""
for i in $(seq 1 30); do
  ARGOCD_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "${ARGOCD_PASSWORD}" ]]; then break; fi
  sleep 2
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  ArgoCD UI:      https://localhost:8443"
echo "  Username:       admin"
echo "  Password:       ${ARGOCD_PASSWORD:-<check: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d>}"
echo ""
echo "  Phoenix app:    http://localhost:8080/"
echo "  Phoenix RCE:    http://localhost:8080/debug/ (POST cmd=id)"
echo "  Payment API:    http://localhost:8080/ (via NodePort)"
echo ""
echo "  Tip: wait ~60s for all pods to reach Running state:"
echo "    kubectl get pods -A -w"
echo ""
echo "  To delete everything:"
echo "    kind delete cluster --name ${CLUSTER_NAME}"
echo ""
