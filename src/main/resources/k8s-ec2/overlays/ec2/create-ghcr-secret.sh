#!/bin/bash
# Creates/updates the ghcr-creds image pull secret so the EC2 node can pull
# ghcr.io/19btech/fyntrac/docker/* images. Needs a GitHub Personal Access Token
# with the read:packages scope. Never commit the token to git.
#
# Usage: GHCR_USER=<github-user> GHCR_TOKEN=<pat> ./create-ghcr-secret.sh
set -euo pipefail

: "${GHCR_USER:?set GHCR_USER to your GitHub username}"
: "${GHCR_TOKEN:?set GHCR_TOKEN to a PAT with read:packages}"

kubectl create namespace fyntrac --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ghcr-creds \
  --namespace fyntrac \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ghcr-creds applied."
