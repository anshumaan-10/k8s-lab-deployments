# k8s-lab-deployments

Kubernetes manifests and ArgoCD configuration for the [k8s-security-lab](https://github.com/anshumaan-10/k8s-security-lab).

ArgoCD watches this repo. When a GitHub Actions CI build in [phoenix](https://github.com/anshumaan-10/phoenix), [payment-api](https://github.com/anshumaan-10/payment-api) or [checkout](https://github.com/anshumaan-10/checkout) completes, it updates the image SHA in the relevant `deployment.yaml` here and commits. ArgoCD picks up the change and rolls out the update.

---

## Repository Structure

```
k8s-lab-deployments/
│
├── namespaces.yaml                    ← Create web + payments namespaces
│
├── deployments/
│   ├── phoenix/
│   │   ├── deployment.yaml            ← ⚠ VULN-01 (privileged+hostPID+hostPath)
│   │   ├── service.yaml               ← LoadBalancer (cloud) / NodePort (kind)
│   │   ├── configmap.yaml             ← DEBUG_PATH setting
│   │   └── rbac.yaml                  ← ⚠ VULN-06 (wildcard RBAC)
│   ├── payment-api/
│   │   ├── deployment.yaml            ← Hardened (non-root, read-only fs)
│   │   └── service.yaml
│   └── checkout/
│       └── deployment.yaml            ← Hardened (non-root, read-only fs)
│
├── argocd/
│   ├── app-of-apps.yaml               ← Bootstrap: apply this once, ArgoCD manages the rest
│   └── apps/
│       ├── phoenix.yaml               ← ArgoCD Application for phoenix
│       ├── payment-api.yaml           ← ArgoCD Application for payment-api
│       └── checkout.yaml             ← ArgoCD Application for checkout
│
└── cluster/
    ├── kind-config.yaml               ← kind cluster config
    ├── setup-kind.sh                  ← One-shot local setup (kind + ArgoCD)
    ├── setup-gke.sh                   ← One-shot GKE setup
    └── teardown.sh                    ← Delete kind cluster
```

---

## SDLC Pipeline

```
git push to phoenix / payment-api / checkout
  └─► GitHub Actions CI
        └─► Build linux/amd64 image
              └─► Push anshumaan10/<service>:<sha> to Docker Hub
                    └─► Update deployments/<service>/deployment.yaml here
                          └─► ArgoCD auto-sync (every 3 min or on webhook)
                                └─► kubectl apply → cluster
```

---

## Quick Start — Run Locally (kind)

### Prerequisites

```bash
brew install kind kubectl
# Docker Desktop must be running
```

### One-command setup

```bash
git clone https://github.com/anshumaan-10/k8s-lab-deployments
cd k8s-lab-deployments
chmod +x cluster/*.sh
./cluster/setup-kind.sh
```

That's it. The script:
1. Creates a kind cluster (`k8s-security-lab`)
2. Installs ArgoCD v2.13.3
3. Creates `web` and `payments` namespaces
4. Bootstraps the App-of-Apps → ArgoCD deploys all three services

After ~2 minutes:

| URL | Service |
|---|---|
| http://localhost:8080/ | phoenix dashboard |
| http://localhost:8080/debug/ | phoenix RCE endpoint |
| `kubectl port-forward svc/payment-api 8081:8080 -n payments` | payment-api |

**ArgoCD UI:** https://localhost:8443  
**Username:** `admin`  
**Password:** from `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d`

---

## Quick Start — Google Kubernetes Engine (GKE)

```bash
export DOCKERHUB_TOKEN=<your-docker-hub-token>
./cluster/setup-gke.sh --project <gcp-project-id> --region us-central1
```

> Uses GKE Autopilot — no node management required. Estimated cost: ~$0.10/hr.
> Delete with `gcloud container clusters delete k8s-security-lab --region us-central1 --project <project>`.

---

## Manual Deploy (any cluster)

```bash
# 0. Point kubectl at your cluster
kubectl config current-context

# 1. Namespaces
kubectl apply -f namespaces.yaml

# 2. Docker Hub pull secret (images are public — skip if you don't need auth)
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=anshumaan10 \
  --docker-password=<token> \
  --namespace web
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=anshumaan10 \
  --docker-password=<token> \
  --namespace payments

# 3. Apply manifests directly (without ArgoCD)
kubectl apply -f deployments/phoenix/
kubectl apply -f deployments/payment-api/
kubectl apply -f deployments/checkout/

# 4. Verify
kubectl get pods -n web
kubectl get pods -n payments
```

---

## Install ArgoCD Separately

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.3/manifests/install.yaml

# Wait for it to be ready
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s

# Bootstrap the App-of-Apps
kubectl apply -f argocd/app-of-apps.yaml
```

---

## Vulnerability Map

| File | Vulnerability |
|---|---|
| `deployments/phoenix/deployment.yaml` | VULN-01: `privileged: true`, `hostPID`, `hostNetwork`, `hostPath: /` |
| `deployments/phoenix/rbac.yaml` | VULN-06: wildcard `resources: ["*"]` RBAC |

See [k8s-security-lab](https://github.com/anshumaan-10/k8s-security-lab) for the full writeup and fix YAMLs.
