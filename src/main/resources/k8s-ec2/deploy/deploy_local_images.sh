#!/bin/bash
#
# import_images_to_k3s.sh — Import Fyntrac Docker images into k3s's containerd
#                            and restart the corresponding pods so they pick up
#                            the freshly-imported images.
#
# Usage:
#   ./import_images_to_k3s.sh [tag] [namespace]
#
# Arguments:
#   tag         (optional) Image tag to import, defaults to 0.0.4-SNAPSHOT
#   namespace   (optional) Kubernetes namespace, defaults to fyntrac
#
# Example:
#   ./import_images_to_k3s.sh
#   ./import_images_to_k3s.sh 0.0.5-SNAPSHOT fyntrac

set -euo pipefail

TAG="${1:-0.0.4-SNAPSHOT}"
NAMESPACE="${2:-fyntrac}"
REGISTRY="ghcr.io/19btech/fyntrac/docker"
IMAGES=(dataloader gl model reporting)

echo "=== Importing images (tag: $TAG) into k3s containerd ==="
for img in "${IMAGES[@]}"; do
    IMAGE_REF="${REGISTRY}/${img}:${TAG}"
    echo "--- Importing ${IMAGE_REF} ---"

    if ! DOCKER_HOST=unix:///var/run/docker.sock docker image inspect "$IMAGE_REF" &> /dev/null; then
        echo "Error: image ${IMAGE_REF} not found locally in Docker. Skipping."
        continue
    fi

    DOCKER_HOST=unix:///var/run/docker.sock docker save "$IMAGE_REF" | sudo k3s ctr images import -
    echo "Imported: ${IMAGE_REF}"
done

echo ""
echo "=== Restarting pods in namespace '$NAMESPACE' to pick up new images ==="
for img in "${IMAGES[@]}"; do
    echo "--- Deleting pods with label app=${img} ---"
    kubectl delete pod -n "$NAMESPACE" -l app="${img}" --ignore-not-found
done

echo ""
echo "Done. Pods will be recreated automatically by their controllers (Deployment/ReplicaSet)."
echo "Verify with: kubectl get pods -n ${NAMESPACE}"
