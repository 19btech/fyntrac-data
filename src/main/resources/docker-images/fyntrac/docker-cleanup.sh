#!/bin/bash

# ==============================================================================
# WARNING: THIS SCRIPT IS DESTRUCTIVE.
# It will stop and permanently delete ALL Docker containers and ALL Docker images.
# Use with extreme caution. There is no undo.
# ==============================================================================

# Ask for confirmation before proceeding
read -p "Are you sure you want to stop and remove ALL containers and images? [y/N] " response

if [[ "$response" =~ ^[Yy]$ ]]
then
    echo "Stopping all running Docker containers..."
    # The '|| true' part prevents the script from exiting if there are no containers to stop
    docker stop $(docker ps -a -q) || true

    echo "Removing all Docker containers..."
    docker rm $(docker ps -a -q) || true

    echo "Removing all Docker images..."
    docker rmi $(docker images -q) || true

    echo "Cleanup complete."
else
    echo "Operation cancelled."
fi

