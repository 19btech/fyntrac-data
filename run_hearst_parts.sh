#!/usr/bin/env bash
# run_hearst_parts.sh - run the Hearst_GHK split scenario (Test_P1..P4.xlsx) sequentially against
# TNT004, stopping at the first failure. Works on any k3s host running k8s-ec2 (local or EC2).
#
# Usage: ./run_hearst_parts.sh 1 2 3 4     # P1 resets the tenant DB, the rest continue on its data
#        ./run_hearst_parts.sh 3 4         # resume from P3 (TNT004 must already hold P1+P2 output)
#
# Env:   BACKUP=1   zip-backup the tenant after each part (needs mongodump + zip on the host;
#                   backups go to $BACKUP_DIR, default ~/backups/fyntrac)
#        LOG_DIR    where test logs + summary.txt go (default ~/backups/fyntrac/logs)
#
# Run it inside tmux: the four parts take several hours and a dropped SSH session kills the run.
set -u
cd "$(dirname "$0")"

source ~/.dev_profile   # GIT_USER/GIT_KEY for the GitHub Packages repo, MONGODB_* for the test driver
TENANT=TNT004
TEST_DATA=Hearst_GHK
NAMESPACE=fyntrac
BACKUP=${BACKUP:-0}
BACKUP_DIR=${BACKUP_DIR:-$HOME/backups/fyntrac}
LOG_DIR=${LOG_DIR:-$BACKUP_DIR/logs}
PF_SCRIPT=src/main/resources/k8s-ec2/deploy/port-forward.sh
mkdir -p "$LOG_DIR"
SUMMARY=$LOG_DIR/summary.txt

PARTS=("$@")
[ ${#PARTS[@]} -eq 0 ] && { echo "Usage: $0 <part numbers, e.g. 1 2 3 4>"; exit 2; }

log() { echo "$(date '+%F %T') $*" | tee -a "$SUMMARY"; }
port_open() { (timeout 1 bash -c "</dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Starting into a half-ready cluster fails the run (dataloader/gl sit 0/1 for minutes after a restart).
log "waiting for all $NAMESPACE deployments to be available..."
kubectl wait deploy --all -n "$NAMESPACE" --for=condition=Available --timeout=10m \
  || { log "cluster not ready - aborting"; exit 1; }

# mongodb/memcached/pulsar are ClusterIP-only; the test's Spring context reaches them on 127.0.0.1.
if ! port_open 27017 || ! port_open 11211 || ! port_open 6650; then
  log "starting port-forwards"
  bash "$PF_SCRIPT" start
fi
for p in 27017 11211 6650 8081 8082; do
  port_open $p || { log "port $p not reachable on 127.0.0.1 - aborting"; exit 1; }
done

# Run a mongosh snippet inside the mongodb pod, authenticating with the pod's own root password,
# so this script needs neither mongosh on the host nor the password in plain text.
mongo_eval() {
  kubectl exec -n "$NAMESPACE" deploy/mongodb -- sh -c \
    'mongosh -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "$0"' "$1"
}

# GL booking is asynchronous (gl service, via Pulsar) and can still be writing after the test passes.
# Wait until both GL collections stop growing (3 identical polls 10s apart; give up after 15 min) so
# the next part - or a backup - starts from a settled tenant.
wait_gl_settled() {
  local last="" now same=0 start=$SECONDS
  while [ $same -lt 3 ] && [ $((SECONDS - start)) -lt 900 ]; do
    now=$(mongo_eval "const d=db.getSiblingDB('$TENANT'); print(d.GeneralLedgerEnteryStage.estimatedDocumentCount()+','+d.GeneralLedgerAccountBalanceStage.estimatedDocumentCount())" 2>/dev/null)
    if [ -n "$now" ] && [ "$now" = "$last" ]; then same=$((same + 1)); else same=0; fi
    last=$now
    [ $same -lt 3 ] && sleep 10
  done
  log "GL settled=$([ $same -ge 3 ] && echo yes || echo NO) after $((SECONDS - start))s (stage,balance)=$last"
}

backup() {
  local part=$1 out="$BACKUP_DIR/${TENANT}_after_${1}_$(date +%Y%m%d_%H%M).zip"
  TMPDIR=$BACKUP_DIR/.tmp; mkdir -p "$TMPDIR"; export TMPDIR   # dumps are ~15G; keep them off /tmp
  if bash src/main/resources/db/mongo_export.sh "$TENANT" "$out" \
       "mongodb://root:${MONGODB_PSWD}@localhost:27017/?authSource=admin" >"$LOG_DIR/backup_${part}.log" 2>&1; then
    log "backup $part OK -> $out ($(du -h "$out" | cut -f1))"
  else
    log "backup $part FAILED (see $LOG_DIR/backup_${part}.log)"; return 1
  fi
}

for n in "${PARTS[@]}"; do
  part=P$n
  reset=false; [ "$n" = "1" ] && reset=true
  log "=== START $part (resetDb=$reset) ==="
  t0=$SECONDS
  # Gradle's --info output is buffered until the test method ends, so this log stays silent for the
  # whole part. Check progress with: kubectl logs -n fyntrac -l app=dataloader --tail=20
  ./gradlew clean test --tests com.fyntrac.data.testdriver.ExcelTestDriver \
      -PtestData=$TEST_DATA -PtestSteps=Test_${part}.xlsx -PresetDb=$reset \
      --no-daemon --info >"$LOG_DIR/test_${part}.log" 2>&1
  rc=$?
  mins=$(( (SECONDS - t0) / 60 ))
  if [ $rc -ne 0 ]; then
    log "=== $part FAILED after ${mins}m (rc=$rc, see $LOG_DIR/test_${part}.log) ==="
    exit $rc
  fi
  log "=== $part PASSED in ${mins}m ==="
  wait_gl_settled
  if [ "$BACKUP" = "1" ]; then backup "$part" || exit 1; fi
done
log "ALL DONE: parts ${PARTS[*]}"
