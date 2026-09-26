#!/bin/bash
#
# port-forward.sh — Expose the in-cluster-only services (mongodb, memcached, pulsar) on
#                   127.0.0.1 so the ExcelTestDriver can run on the k3s host itself.
#
# These are ClusterIP services on purpose (never reachable from outside the node), unlike the
# app services (dataloader 8081, model 8082, ...) which k3s's servicelb already serves on the
# host. A plain `kubectl port-forward` pins to one pod and exits when that pod restarts, so each
# forward runs inside a reconnect loop.
#
# Usage:
#   ./port-forward.sh start     # start all forwards in the background (default)
#   ./port-forward.sh stop      # stop them
#   ./port-forward.sh status    # show which ports are listening
#
# Logs: /tmp/pf-<service>.log

set -uo pipefail

NAMESPACE="${NAMESPACE:-fyntrac}"
FORWARDS=("mongodb 27017" "memcached 11211" "pulsar 6650")
PID_DIR="/tmp/fyntrac-pf"

status() {
    for f in "${FORWARDS[@]}"; do
        set -- $f
        if ss -ltn | grep -qE "127\.0\.0\.1:$2\b"; then
            echo "  $1 ($2): listening"
        else
            echo "  $1 ($2): NOT listening — see /tmp/pf-$1.log"
        fi
    done
}

stop() {
    [ -d "$PID_DIR" ] || { echo "No forwards running."; return; }
    for pidfile in "$PID_DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        # Kill the loop's whole process group so the child kubectl goes too.
        kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
        rm -f "$pidfile"
    done
    echo "Forwards stopped."
}

start() {
    command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
        || { echo "Cannot reach namespace '$NAMESPACE' — is KUBECONFIG set?" >&2; exit 1; }

    stop >/dev/null
    mkdir -p "$PID_DIR"

    for f in "${FORWARDS[@]}"; do
        set -- $f
        # setsid gives each loop its own process group, which is what stop() kills.
        setsid nohup bash -c "
            while true; do
                echo \"[\$(date '+%F %T')] starting forward svc/$1 $2\"
                kubectl port-forward -n '$NAMESPACE' --address 127.0.0.1 svc/$1 $2:$2
                echo \"[\$(date '+%F %T')] forward exited, retrying in 2s\"
                sleep 2
            done" > "/tmp/pf-$1.log" 2>&1 < /dev/null &
        echo $! > "$PID_DIR/$1.pid"
    done

    sleep 3
    echo "Port forwards:"
    status
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) echo "Port forwards:"; status ;;
    *)      echo "Usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
