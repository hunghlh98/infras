#!/bin/bash
# Real-time MinIO -> host mirror (data safety, size-flat).
#
# Continuously mirrors ALL buckets to ONE host directory using
# `mc mirror --watch --overwrite --remove`, so the mirror always reflects the
# live data and does NOT accumulate per-run snapshots (unlike a dated backup).
# Trade-off: `--remove` propagates deletions, so this is a live replica, not a
# point-in-time archive — an accidental delete in MinIO also clears from the
# mirror.
#
# Commands:
#   start     start the real-time mirror daemon (background, survives shell exit)
#   stop      stop the daemon
#   status    show whether the daemon is running
#   watch     run the mirror in the FOREGROUND (for systemd / debugging)
#   sync      one-shot mirror now, then exit
#   restore   push the host mirror BACK into MinIO (recovery)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIO_DIR="$(dirname "$SCRIPT_DIR")"
# Mirror lives inside the minio module (user-owned), not the root-owned repo
# volumes/ dir: minikube-local/k8s-local/minio/volumes/
MIRROR_DIR="${MIRROR_DIR:-$MINIO_DIR/volumes}"
NAMESPACE="infras-minio"
S3_ENDPOINT="${S3_ENDPOINT:-http://s3.minio.local:8080}"
ALIAS="infras"
MC_BIN="$SCRIPT_DIR/bin/mc"
PID_FILE="$SCRIPT_DIR/.sync.pid"
# Keep the log OUTSIDE the mirror dir: `mc mirror --remove` would otherwise
# delete a root-level .sync.log (no matching bucket), and `restore` would try
# to treat it as an invalid bucket name.
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/.sync.log}"

log()  { echo -e "\033[0;34mℹ\033[0m $1"; }
ok()   { echo -e "\033[0;32m✓\033[0m $1"; }
warn() { echo -e "\033[1;33m⚠\033[0m $1"; }
err()  { echo -e "\033[0;31m✗\033[0m $1"; }

ensure_mc() {
  if [ ! -x "$MC_BIN" ]; then
    log "Downloading mc client..."
    mkdir -p "$(dirname "$MC_BIN")"
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o "$MC_BIN"
    chmod +x "$MC_BIN"
  fi
}

ensure_dir() {
  if ! mkdir -p "$MIRROR_DIR" 2>/dev/null; then
    err "Cannot create $MIRROR_DIR (is it writable?)."
    err "One-time fix: sudo mkdir -p '$MIRROR_DIR' && sudo chown \"\$USER\" '$MIRROR_DIR'"
    err "Or set MIRROR_DIR=<writable path> when running this script."
    exit 1
  fi
}

configure_alias() {
  local user pass env
  env=$(kubectl get secret storage-configuration -n "$NAMESPACE" -o jsonpath='{.data.config\.env}' | base64 -d)
  user=$(echo "$env" | sed -n 's/^export MINIO_ROOT_USER="\(.*\)"$/\1/p')
  pass=$(echo "$env" | sed -n 's/^export MINIO_ROOT_PASSWORD="\(.*\)"$/\1/p')
  "$MC_BIN" alias set "$ALIAS" "$S3_ENDPOINT" "$user" "$pass" >/dev/null
}

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_sync() {
  ensure_mc; ensure_dir; configure_alias
  log "One-shot mirror $ALIAS -> $MIRROR_DIR ..."
  "$MC_BIN" mirror --overwrite --remove "$ALIAS" "$MIRROR_DIR"
  ok "Mirror complete: $MIRROR_DIR"
}

cmd_watch() {
  ensure_mc; ensure_dir; configure_alias
  log "Watching $ALIAS -> $MIRROR_DIR (Ctrl-C to stop) ..."
  exec "$MC_BIN" mirror --watch --overwrite --remove "$ALIAS" "$MIRROR_DIR"
}

cmd_start() {
  if is_running; then warn "Already running (pid $(cat "$PID_FILE"))."; exit 0; fi
  ensure_mc; ensure_dir; configure_alias
  nohup "$MC_BIN" mirror --watch --overwrite --remove "$ALIAS" "$MIRROR_DIR" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  sleep 1
  if is_running; then
    ok "Real-time mirror started (pid $(cat "$PID_FILE")). Log: $LOG_FILE"
    warn "Does not survive reboot — re-run 'start' after boot, or wrap 'watch' in a systemd user unit."
  else
    err "Daemon failed to start. Check $LOG_FILE"; rm -f "$PID_FILE"; exit 1
  fi
}

cmd_stop() {
  if is_running; then
    kill "$(cat "$PID_FILE")" && rm -f "$PID_FILE"
    ok "Stopped."
  else
    warn "Not running."; rm -f "$PID_FILE" 2>/dev/null || true
  fi
}

cmd_status() {
  if is_running; then ok "Running (pid $(cat "$PID_FILE")). Mirror: $MIRROR_DIR"
  else warn "Not running."; fi
}

cmd_restore() {
  ensure_mc; configure_alias
  [ -d "$MIRROR_DIR" ] || { err "Mirror dir not found: $MIRROR_DIR"; exit 1; }
  warn "This pushes $MIRROR_DIR back INTO MinIO (recovery; may overwrite objects)."
  read -p "Continue? (yes/no): " c; [ "$c" = "yes" ] || { log "Cancelled"; exit 0; }
  "$MC_BIN" mirror --overwrite "$MIRROR_DIR" "$ALIAS"
  ok "Restored MinIO from $MIRROR_DIR"
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  watch)   cmd_watch ;;
  sync)    cmd_sync ;;
  restore) cmd_restore ;;
  *) echo "Usage: $0 {start|stop|status|watch|sync|restore}"; exit 1 ;;
esac
