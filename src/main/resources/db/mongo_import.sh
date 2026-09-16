#!/bin/bash
#
# mongo_import.sh — Restore a MongoDB database from a .zip export (created by mongo_export.sh)
#
# Usage:
#   ./mongo_import.sh <zip_file_path> <target_db_name> [mongo_uri]
#
# Arguments:
#   zip_file_path     Path to the .zip file created by mongo_export.sh
#                      e.g. /home/uabbas/backups/TNT002-backup.zip
#   target_db_name    Name of the database to restore into (can differ from the original)
#   mongo_uri         (optional) Mongo connection string, defaults to mongodb://localhost:27017
#                      Do NOT include a trailing db name or authSource path segment issues —
#                      just host/port + query params, e.g.:
#                      "mongodb://root:pass@localhost:27017/?authSource=admin"
#
# Example:
#   ./mongo_import.sh /home/uabbas/backups/TNT002-backup.zip TNT002
#   ./mongo_import.sh /home/uabbas/backups/TNT002-backup.zip TNT002_restored "mongodb://root:R3s3rv%23313@localhost:27017/?authSource=admin"

set -euo pipefail

# ---- Argument validation ----
if [ $# -lt 2 ]; then
    echo "Usage: $0 <zip_file_path> <target_db_name> [mongo_uri]"
    echo "Example: $0 /home/uabbas/backups/TNT002-backup.zip TNT002"
    exit 1
fi

ZIP_FILE="$1"
TARGET_DB="$2"
MONGO_URI="${3:-mongodb://localhost:27017}"

if [ ! -f "$ZIP_FILE" ]; then
    echo "Error: file not found: $ZIP_FILE"
    exit 1
fi

# ---- Check dependencies ----
if ! command -v mongorestore &> /dev/null; then
    echo "Error: mongorestore not found. Install mongodb-database-tools first."
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "Error: unzip not found. Install it first (e.g. sudo dnf install unzip)."
    exit 1
fi

# ---- Extract into a temp working directory ----
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Extracting $ZIP_FILE ..."
unzip -q "$ZIP_FILE" -d "$TMP_DIR"

# The zip contains a top-level folder named after the ORIGINAL db name.
# Find it automatically (there should be exactly one top-level directory).
SRC_DIR=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)

if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
    echo "Error: could not find a database dump folder inside the zip."
    exit 1
fi

echo "Found dump folder: $(basename "$SRC_DIR")"
echo "Restoring into database '$TARGET_DB' at $MONGO_URI ..."

# --nsFrom/--nsTo lets us restore into a different db name than the original dump,
# and also works fine when TARGET_DB matches the original name.
ORIGINAL_DB_NAME=$(basename "$SRC_DIR")

mongorestore --uri="${MONGO_URI}" \
    --nsFrom="${ORIGINAL_DB_NAME}.*" \
    --nsTo="${TARGET_DB}.*" \
    --dir="$SRC_DIR" \
    --drop

echo "Done. Data restored into database: $TARGET_DB"
