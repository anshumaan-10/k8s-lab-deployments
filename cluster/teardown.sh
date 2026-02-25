#!/usr/bin/env bash
# teardown.sh — Delete the k8s-security-lab kind cluster and all resources
set -euo pipefail

CLUSTER_NAME="k8s-security-lab"

echo "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}" && echo "Done."
