#!/bin/bash

set -e

COMPOSE_FILE="fyntrac-docker-compose.yml"
NETWORK_NAME="fyntrac-network"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
  printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

log_error() {
  printf "${RED}[ERROR] %s${NC}\n" "$1"
}

# Check minimum arguments
if [ "$#" -lt 1 ]; then
  log_error "No components specified. Usage: $0 version [component1] [component2] ... | all"
  exit 1
fi

# Version parameter
VERSION="$1"
shift

# Default version
if [ -z "$VERSION" ]; then
  VERSION="0.0.2-SNAPSHOT"
fi

log_info "Using version: $VERSION"

# Container and image maps (using functions instead of declare -A)
get_container_name() {
  case "$1" in
    dataloader) echo "fyntrac-dataloader" ;;
    model) echo "fyntrac-model" ;;
    gl) echo "fyntrac-gl" ;;
    reporting) echo "fyntrac-reporting" ;;
    web) echo "fyntrac-web" ;;
    *) echo "" ;;
  esac
}

get_image_name() {
  case "$1" in
    dataloader) echo "ghcr.io/19btech/fyntrac/docker/dataloader:${VERSION}" ;;
    model) echo "ghcr.io/19btech/fyntrac/docker/model:${VERSION}" ;;
    gl) echo "ghcr.io/19btech/fyntrac/docker/gl:${VERSION}" ;;
    reporting) echo "ghcr.io/19btech/fyntrac/docker/reporting:${VERSION}" ;;
    web) echo "ghcr.io/19btech/fyntrac/docker/web:latest" ;;
    *) echo "" ;;
  esac
}

# Determine components
if [ "$#" -eq 0 ]; then
  log_error "No components specified after version. Usage: $0 version [component1] [component2] ... | all"
  exit 1
fi

if [ "$1" = "all" ]; then
  components=("dataloader" "model" "gl" "reporting" "web")
else
  components=()
  for arg in "$@"; do
    if [ -n "$(get_container_name "$arg")" ]; then
      components+=("$arg")
    else
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
  container=$(get_container_name "$comp")
  if docker rm -f "$container" 2>/dev/null; then
    log_info "Removed container: $container"
  else
    log_info "Container not found or already removed: $container"
  fi
done

# Remove selected images
log_info "Removing old images..."
for comp in "${components[@]}"; do
  image=$(get_image_name "$comp")
  if docker rmi -f "$image" 2>/dev/null; then
    log_info "Removed image: $image"
  else
    log_info "Image not found or already removed: $image"
  fi
done

# Pull latest images
log_info "Pulling latest images..."
for comp in "${components[@]}"; do
  image=$(get_image_name "$comp")
  if docker pull "$image"; then
    log_info "Successfully pulled: $image"
  else
    log_error "Failed to pull image: $image"
    exit 1
  fi
done

# Start selected services
log_info "Starting containers using $COMPOSE_FILE..."
if docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate --no-build --pull always "${components[@]}"; then
  log_info "Containers started successfully."
else
  log_error "Failed to start containers. Check docker compose logs."
  exit 1
fi

