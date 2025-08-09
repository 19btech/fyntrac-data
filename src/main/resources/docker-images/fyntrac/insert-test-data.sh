#!/bin/bash

# Name of your running MongoDB container
MONGO_CONTAINER="mongodb"

# Path to your init script on the host
INIT_SCRIPT_PATH="./mongo-init.js"

# Database credentials
MONGO_USER="root"
MONGO_PASS="R3s3rv#313"
MONGO_DB="master"

# Copy script into the container
docker cp "$INIT_SCRIPT_PATH" "$MONGO_CONTAINER":/tmp/mongo-init.js

# Execute the script inside the container
docker exec -it "$MONGO_CONTAINER" mongosh \
  --username "$MONGO_USER" \
  --password "$MONGO_PASS" \
  --authenticationDatabase admin \
  "$MONGO_DB" /tmp/mongo-init.js
