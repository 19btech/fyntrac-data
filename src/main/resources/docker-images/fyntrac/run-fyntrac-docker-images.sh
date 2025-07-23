#!/bin/bash

set -e

COMPOSE_FILE="fyntrac-docker-compose.yml"
NETWORK_NAME="fyntrac-network"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO] $1${NC}"
}

log_error() {
  echo -e "${RED}[ERROR] $1${NC}"
}

containers=("fyntrac-dataloader" "fyntrac-model" "fyntrac-gl" "fyntrac-reporting" "fyntrac-web")
images=(
  "ghcr.io/19btech/fyntrac/docker/dataloader:0.0.1-snapshot"
  "ghcr.io/19btech/fyntrac/docker/model:0.0.1-snapshot"
  "ghcr.io/19btech/fyntrac/docker/gl:0.0.1-snapshot"
  "ghcr.io/19btech/fyntrac/docker/reporting:0.0.1-snapshot"
  "ghcr.io/19btech/fyntrac/docker/web:latest"
)

log_info "Checking for existing Docker network: $NETWORK_NAME..."
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log_info "Creating Docker network: $NETWORK_NAME"
  docker network create "$NETWORK_NAME"
else
  log_info "Docker network $NETWORK_NAME already exists."
fi

log_info "Stopping and removing containers..."
for container in "${containers[@]}"; do
  if docker rm -f "$container" 2>/dev/null; then
    log_info "Removed container: $container"
  else
    log_info "Container not found or already removed: $container"
  fi
done

log_info "Removing old images..."
for image in "${images[@]}"; do
  if docker rmi -f "$image" 2>/dev/null; then
    log_info "Removed image: $image"
  else
    log_info "Image not found or already removed: $image"
  fi
done

log_info "Pulling latest images..."
for image in "${images[@]}"; do
  if docker pull "$image"; then
    log_info "Successfully pulled: $image"
  else
    log_error "Failed to pull image: $image"
    exit 1
  fi
done

log_info "Starting containers using $COMPOSE_FILE..."
if docker compose -f "$COMPOSE_FILE" up -d; then
  log_info "Containers started successfully."
else
  log_error "Failed to start containers. Check docker compose logs."
  exit 1
fi
