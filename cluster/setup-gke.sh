#!/usr/bin/env bash
# setup-gke.sh — Deploy the k8s-security-lab to Google Kubernetes Engine (GKE)
#
# Prerequisites:
#   gcloud CLI installed and authenticated
#   kubectl installed
#   Docker Hub token for pull secrets
#
# Usage:
#   export DOCKERHUB_TOKEN=<your-token>
#   ./cluster/setup-gke.sh --project my-gcp-project --region us-central1

set -euo pipefail

PROJECT="${PROJECT:-}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="k8s-security-lab"
ARGOCD_VERSION="v2.13.3"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-anshumaan10}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --project)  PROJECT="$2";  shift 2 ;;
    --region)   REGION="$2";   shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${PROJECT}" ]]; then
  echo "Error: --project is required"
  echo "Usage: $0 --project my-gcp-project [--region us-central1]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       k8s-security-lab — GKE setup                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Project:  ${PROJECT}"
echo "  Region:   ${REGION}"
echo "  Cluster:  ${CLUSTER_NAME}"
echo ""

# ── 1. Create GKE cluster ────────────────────────────────────────
echo "[1/5] Creating GKE Autopilot cluster..."
gcloud container clusters create-auto "${CLUSTER_NAME}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --release-channel=regular

gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --project="${PROJECT}" \
  --region="${REGION}"

# ── 2. Install ArgoCD ────────────────────────────────────────────
echo ""
echo "[2/5] Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s

# ── 3. Create namespaces and pull secrets ────────────────────────
echo ""
echo "[3/5] Creating namespaces and pull secrets..."
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
fi

# ── 4. Bootstrap App-of-Apps ─────────────────────────────────────
echo ""
echo "[4/5] Bootstrapping ArgoCD App-of-Apps..."
kubectl apply -f "${REPO_ROOT}/argocd/app-of-apps.yaml"

# ── 5. Print access info ─────────────────────────────────────────
echo ""
echo "[5/5] Getting ArgoCD admin password..."
sleep 10
ARGOCD_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

ARGOCD_IP=""
for i in $(seq 1 30); do
  ARGOCD_IP=$(kubectl get svc -n argocd argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${ARGOCD_IP}" ]]; then break; fi
  echo "  Waiting for ArgoCD LoadBalancer IP..."
  sleep 10
done

PHOENIX_IP=""
for i in $(seq 1 30); do
  PHOENIX_IP=$(kubectl get svc -n web phoenix-app \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${PHOENIX_IP}" ]]; then break; fi
  sleep 10
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  ArgoCD UI:      https://${ARGOCD_IP:-<pending>}"
echo "  Username:       admin"
echo "  Password:       ${ARGOCD_PASSWORD}"
echo ""
echo "  Phoenix app:    http://${PHOENIX_IP:-<pending>}/"
echo "  Phoenix RCE:    http://${PHOENIX_IP:-<pending>}/debug/ (POST cmd=id)"
echo ""
echo "  To delete everything:"
echo "    gcloud container clusters delete ${CLUSTER_NAME} --project=${PROJECT} --region=${REGION}"
echo ""
