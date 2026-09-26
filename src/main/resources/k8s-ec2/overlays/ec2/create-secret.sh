#!/bin/bash
# Creates/updates the fyntrac-secrets k8s Secret from ~/.dev_profile — never commit actual
# credential values to git. Re-run any time .dev_profile changes; --dry-run + apply makes it
# idempotent.
set -euo pipefail

if [ -f ~/.dev_profile ]; then
  source ~/.dev_profile
else
  echo "~/.dev_profile not found — required for ZITADEL_ISSUER_URI / MONGODB_PSWD" >&2
  exit 1
fi

kubectl create namespace fyntrac --dry-run=client -o yaml | kubectl apply -f -

# .dev_profile's MONGODB_PSWD is URL-encoded for use inside connection-string URIs (e.g.
# "R3s3rv%23313" for a real password of "R3s3rv#313" — see .env.example's own comment on this
# var). mongod's MONGO_INITDB_ROOT_PASSWORD is NOT a URI and takes the value literally, so it
# needs the decoded form — otherwise mongod's real password ends up containing a literal "%23"
# while every client correctly decodes the URI back to "#" and authentication never matches.
MONGODB_PSWD_RAW=$(python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))" "${MONGODB_PSWD:?MONGODB_PSWD not set in .dev_profile}")

kubectl create secret generic fyntrac-secrets \
  --namespace fyntrac \
  --from-literal=ZITADEL_ISSUER_URI="${ZITADEL_ISSUER_URI:?ZITADEL_ISSUER_URI not set in .dev_profile}" \
  --from-literal=MONGODB_PSWD="${MONGODB_PSWD:?MONGODB_PSWD not set in .dev_profile}" \
  --from-literal=MONGODB_PSWD_RAW="${MONGODB_PSWD_RAW}" \
  --from-literal=ZITADEL_CLIENT_ID="${ZITADEL_CLIENT_ID:?ZITADEL_CLIENT_ID not set in .dev_profile}" \
  --from-literal=ZITADEL_CLIENT_SECRET="${ZITADEL_CLIENT_SECRET:?ZITADEL_CLIENT_SECRET not set in .dev_profile}" \
  --from-literal=ZITADEL_PROJECT_ID="${ZITADEL_PROJECT_ID:?ZITADEL_PROJECT_ID not set in .dev_profile}" \
  --from-literal=GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "fyntrac-secrets applied."
