#!/bin/bash

set -e

COMPOSE_FILE="fyntrac-docker-compose.yml"
NETWORK_NAME="fyntrac-network"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
  echo "${GREEN}[INFO] $1${NC}"
}

log_error() {
  echo "${RED}[ERROR] $1${NC}"
}

# Check minimum arguments
if [ "$#" -lt 1 ]; then
  log_error "No components specified. Usage: $0 version [component1] [component2] ... | all"
  exit 1
fi

# Version parameter
VERSION="$1"
shift

# Default version if empty
if [ -z "$VERSION" ]; then
  VERSION="0.0.2-SNAPSHOT"
fi

log_info "Using version: $VERSION"

# Component → Container mapping
container_names=("dataloader" "model" "gl" "reporting" "web")
container_values=("fyntrac-dataloader" "fyntrac-model" "fyntrac-gl" "fyntrac-reporting" "fyntrac-web")

# Component → Image mapping
image_values=(
  "ghcr.io/19btech/fyntrac/docker/dataloader:${VERSION}"
  "ghcr.io/19btech/fyntrac/docker/model:${VERSION}"
  "ghcr.io/19btech/fyntrac/docker/gl:${VERSION}"
  "ghcr.io/19btech/fyntrac/docker/reporting:${VERSION}"
  "ghcr.io/19btech/fyntrac/docker/web:latest"
)

# Determine components
if [ "$#" -eq 0 ]; then
  log_error "No components specified after version."
  exit 1
fi

if [ "$1" == "all" ]; then
  components=("${container_names[@]}")
else
  components=()
  for arg in "$@"; do
    found=false
    for cname in "${container_names[@]}"; do
      if [ "$arg" == "$cname" ]; then
        components+=("$arg")
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      log_error "Unknown component: $arg"
      exit 1
    fi
  done
fi

log_info "Components to deploy: ${components[*]}"

# Ensure network exists
log_info "Checking for existing Docker network: $NETWORK_NAME..."
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log_info "Creating Docker network: $NETWORK_NAME"
  docker network create "$NETWORK_NAME"
else
  log_info "Docker network $NETWORK_NAME already exists."
fi

# Stop and remove selected containers
log_info "Stopping and removing containers..."
for comp in "${components[@]}"; do
  for i in "${!container_names[@]}"; do
    if [ "$comp" == "${container_names[$i]}" ]; then
      container="${container_values[$i]}"
      if docker rm -f "$container" 2>/dev/null; then
        log_info "Removed container: $container"
      else
        log_info "Container not found or already removed: $container"
      fi
    fi
  done
done

# Remove selected images
log_info "Removing old images..."
for comp in "${components[@]}"; do
  for i in "${!container_names[@]}"; do
    if [ "$comp" == "${container_names[$i]}" ]; then
      image="${image_values[$i]}"
      if docker rmi -f "$image" 2>/dev/null; then
        log_info "Removed image: $image"
      else
        log_info "Image not found or already removed: $image"
      fi
    fi
  done
done

# Pull latest images
log_info "Pulling latest images..."
for comp in "${components[@]}"; do
  for i in "${!container_names[@]}"; do
    if [ "$comp" == "${container_names[$i]}" ]; then
      image="${image_values[$i]}"
      if docker pull "$image"; then
        log_info "Successfully pulled: $image"
      else
        log_error "Failed to pull image: $image"
        exit 1
      fi
    fi
  done
done

# Start selected services
log_info "Starting containers using $COMPOSE_FILE..."
if docker compose -f "$COMPOSE_FILE" up -d "${components[@]}"; then
  log_info "Containers started successfully."
else
  log_error "Failed to start containers. Check docker compose logs."
  exit 1
fi
