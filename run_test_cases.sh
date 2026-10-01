#!/usr/bin/env bash
# run_test_cases.sh - run any ExcelTestDriver test cases sequentially against a k3s host running
# k8s-ec2 (local or EC2), with a pass/fail + timing summary at the end.
#
# Usage: ./run_test_cases.sh Hearst_ALT Hearst_BIC TestSBO_DSL ...
#        ./run_test_cases.sh --bg Hearst_ALT Hearst_BIC ...   # detached; survives logout / SSH drop
#        (names are folder names under src/test/resources/TestDriver)
#
# Watching a run (from any shell):
#        tail -f ~/test-logs/run.log          # everything this script prints: starts, PASS/FAIL, timings
#        tail -f ~/test-logs/<case>.log       # gradle output of one case (silent until that case ends)
#        kubectl logs -n fyntrac -l app=dataloader -f --tail=20   # live progress inside a case
#        kill -- -$(cat ~/test-logs/run.pid)  # stop the background run (whole group, incl. gradle)
#
# Env:   STOP_ON_FAIL=1   stop at the first failing case (default: run them all)
#        LOG_DIR          where per-case logs + summary.txt go (default ~/test-logs)
#
# Each case runs against the tenant in its own test.properties. Run it inside tmux: a dropped SSH
# session kills the run.
set -u
cd "$(dirname "$0")"

source ~/.dev_profile   # GIT_USER/GIT_KEY for the GitHub Packages repo, MONGODB_* for the test driver
NAMESPACE=fyntrac
STOP_ON_FAIL=${STOP_ON_FAIL:-0}
LOG_DIR=${LOG_DIR:-$HOME/test-logs}
CASES_DIR=src/test/resources/TestDriver
PF_SCRIPT=src/main/resources/k8s-ec2/deploy/port-forward.sh
mkdir -p "$LOG_DIR"
SUMMARY=$LOG_DIR/summary.txt

# --bg: re-launch this script detached from the terminal, with all its output in run.log.
if [ "${1:-}" = "--bg" ]; then
  shift
  [ $# -eq 0 ] && { echo "Usage: $0 --bg <test case names>"; exit 2; }
  rm -f "$LOG_DIR/run.pid"
  RUN_BG_CHILD=1 nohup setsid "$0" "$@" >"$LOG_DIR/run.log" 2>&1 < /dev/null &
  for _ in 1 2 3 4 5; do [ -s "$LOG_DIR/run.pid" ] && break; sleep 1; done
  echo "Started in background (pid $(cat "$LOG_DIR/run.pid" 2>/dev/null)). Watch with:"
  echo "  tail -f $LOG_DIR/run.log"
  echo "Stop with:"
  echo "  kill -- -\$(cat $LOG_DIR/run.pid)"
  exit 0
fi
# The detached child leads its own process group, so `kill -- -<pid>` also stops gradle.
[ "${RUN_BG_CHILD:-0}" = "1" ] && echo $$ >"$LOG_DIR/run.pid"

CASES=("$@")
[ ${#CASES[@]} -eq 0 ] && { echo "Usage: $0 <test case names, e.g. Hearst_ALT Hearst_BIC>"; exit 2; }

# Catch typos before spending hours on the cases in front of them.
for tc in "${CASES[@]}"; do
  [ -f "$CASES_DIR/$tc/test.properties" ] || { echo "Unknown test case: $tc (no $CASES_DIR/$tc/test.properties)"; exit 2; }
done

log() { echo "$(date '+%F %T') $*" | tee -a "$SUMMARY"; }
port_open() { (timeout 1 bash -c "</dev/tcp/127.0.0.1/$1") 2>/dev/null; }
tenant_of() { sed -n 's/^test\.tenantId=\(.*\)$/\1/p' "$CASES_DIR/$1/test.properties" | tr -d '[:space:]'; }

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
# the next case starts on an idle cluster and its timing isn't skewed.
wait_gl_settled() {
  local tenant=$1 last="" now same=0 start=$SECONDS
  while [ $same -lt 3 ] && [ $((SECONDS - start)) -lt 900 ]; do
    now=$(mongo_eval "const d=db.getSiblingDB('$tenant'); print(d.GeneralLedgerEnteryStage.estimatedDocumentCount()+','+d.GeneralLedgerAccountBalanceStage.estimatedDocumentCount())" 2>/dev/null)
    if [ -n "$now" ] && [ "$now" = "$last" ]; then same=$((same + 1)); else same=0; fi
    last=$now
    [ $same -lt 3 ] && sleep 10
  done
  log "GL settled=$([ $same -ge 3 ] && echo yes || echo NO) after $((SECONDS - start))s (stage,balance)=$last"
}

results=()
failed=0
log "RUN START: ${CASES[*]}"
for tc in "${CASES[@]}"; do
  tenant=$(tenant_of "$tc")
  log "=== START $tc (tenant=$tenant) ==="
  t0=$SECONDS
  # Gradle's --info output is buffered until the test method ends, so this log stays silent for the
  # whole case. Check progress with: kubectl logs -n fyntrac -l app=dataloader --tail=20
  ./gradlew clean test --tests com.fyntrac.data.testdriver.ExcelTestDriver \
      -PtestData="$tc" --no-daemon --info >"$LOG_DIR/$tc.log" 2>&1
  rc=$?
  mins=$(( (SECONDS - t0) / 60 ))
  if [ $rc -eq 0 ]; then
    status=PASSED
    log "=== $tc PASSED in ${mins}m ==="
  else
    status=FAILED; failed=$((failed + 1))
    log "=== $tc FAILED after ${mins}m (rc=$rc, see $LOG_DIR/$tc.log) ==="
  fi
  results+=("$tc|$status|${mins}m")
  [ -n "$tenant" ] && wait_gl_settled "$tenant"
  if [ $rc -ne 0 ] && [ "$STOP_ON_FAIL" = "1" ]; then log "STOP_ON_FAIL=1 - stopping"; break; fi
done

echo
echo "==================== TEST SUMMARY ===================="
{ echo "TestCase|Status|Time"; printf '%s\n' "${results[@]}"; } | column -t -s '|'
echo "======================================================"
log "RUN DONE: ${#results[@]} run, $failed failed (logs in $LOG_DIR)"
[ $failed -eq 0 ]
