#!/bin/bash
#
# mongo_export.sh — Export a MongoDB database using mongodump and package it as a .zip
#
# Usage:
#   ./mongo_export.sh <db_name> <output_file_path> [mongo_uri]
#
# Arguments:
#   db_name           Name of the MongoDB database to export (e.g. TNT002)
#   output_file_path  Full path (including directory) for the resulting .zip file
#                      e.g. /home/uabbas/backups/TNT002-backup.zip
#   mongo_uri         (optional) Mongo connection string, defaults to mongodb://localhost:27017
#
# Example:
#   ./mongo_export.sh TNT002 /home/uabbas/backups/TNT002-backup.zip
#   ./mongo_export.sh TNT002 /home/uabbas/backups/TNT002-backup.zip "mongodb://user:pass@localhost:27017/?authSource=admin"

set -euo pipefail

# ---- Argument validation ----
if [ $# -lt 2 ]; then
    echo "Usage: $0 <db_name> <output_file_path> [mongo_uri]"
    echo "Example: $0 TNT002 /home/uabbas/backups/TNT002-backup.zip"
    exit 1
fi

DB_NAME="$1"
OUTPUT_FILE="$2"
# MONGO_URI="${3:-mongodb://localhost:27017}"
MONGO_URI="${3:-mongodb://root:R3s3rv%23313@localhost:27017/?authSource=admin}"

# Ensure .zip extension
case "$OUTPUT_FILE" in
    *.zip) ;;
    *) OUTPUT_FILE="${OUTPUT_FILE}.zip" ;;
esac

OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

# ---- Check dependencies ----
if ! command -v mongodump &> /dev/null; then
    echo "Error: mongodump not found. Install it first (e.g. sudo dnf install mongodb-database-tools)."
    exit 1
fi

if ! command -v zip &> /dev/null; then
    echo "Error: zip not found. Install it first (e.g. sudo dnf install zip)."
    exit 1
fi

# ---- Ensure output directory exists ----
mkdir -p "$OUTPUT_DIR"

# ---- Create a temp working directory for the raw dump ----
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Exporting database '$DB_NAME' from $MONGO_URI ..."
# mongodump --uri="${MONGO_URI}/${DB_NAME}" --out="$TMP_DIR"
mongodump --uri="${MONGO_URI}" --db="${DB_NAME}"  --out="$TMP_DIR"

if [ ! -d "$TMP_DIR/$DB_NAME" ]; then
    echo "Error: mongodump did not produce output for database '$DB_NAME'. Check the db name and connection."
    exit 1
fi

# Remove existing zip at destination so 'zip' doesn't just append/update it
rm -f "$OUTPUT_FILE"

echo "Compressing dump into $OUTPUT_FILE ..."
(cd "$TMP_DIR" && zip -r "$OUTPUT_FILE" "$DB_NAME")

echo "Done. Export saved to: $OUTPUT_FILE"
echo "Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
