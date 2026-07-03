#!/bin/bash
# MinIO backup/restore for minikube — mirrors all buckets to the host.
# Commands: create | list | restore <snapshot> | verify <snapshot> | cleanup | schedule [hour]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIO_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(cd "$MINIO_DIR/../../.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/volumes/minio-backup}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
NAMESPACE="infras-minio"
S3_ENDPOINT="${S3_ENDPOINT:-http://s3.minio.local:8080}"
ALIAS="infras"
MC_BIN="$SCRIPT_DIR/bin/mc"

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

configure_alias() {
  local user pass env
  env=$(kubectl get secret storage-configuration -n "$NAMESPACE" -o jsonpath='{.data.config\.env}' | base64 -d)
  user=$(echo "$env" | sed -n 's/^export MINIO_ROOT_USER="\(.*\)"$/\1/p')
  pass=$(echo "$env" | sed -n 's/^export MINIO_ROOT_PASSWORD="\(.*\)"$/\1/p')
  "$MC_BIN" alias set "$ALIAS" "$S3_ENDPOINT" "$user" "$pass" >/dev/null
}

create_backup() {
  ensure_mc; configure_alias
  local ts snap
  ts=$(date +"%Y%m%d-%H%M%S")
  snap="$BACKUP_DIR/$ts"
  if ! mkdir -p "$snap" 2>/dev/null; then
    err "Cannot create $BACKUP_DIR (is it writable?)."
    err "One-time fix: sudo mkdir -p '$BACKUP_DIR' && sudo chown \"\$USER\" '$BACKUP_DIR'"
    err "Or set BACKUP_DIR=<writable path> when running this script."
    exit 1
  fi
  log "Mirroring all buckets to $snap ..."
  "$MC_BIN" mirror --overwrite "$ALIAS" "$snap"
  ok "Snapshot created: $snap"
}

list_backups() {
  if [ ! -d "$BACKUP_DIR" ]; then warn "No backups in $BACKUP_DIR"; return; fi
  log "Snapshots in $BACKUP_DIR:"
  ls -1 "$BACKUP_DIR"
}

restore_backup() {
  local snap="$1"
  [ -z "$snap" ] && { err "Usage: $0 restore <snapshot>"; list_backups; exit 1; }
  [[ "$snap" != /* ]] && snap="$BACKUP_DIR/$snap"
  [ -d "$snap" ] || { err "Snapshot not found: $snap"; exit 1; }
  ensure_mc; configure_alias
  warn "This mirrors $snap back INTO MinIO (may overwrite objects)."
  read -p "Continue? (yes/no): " c; [ "$c" = "yes" ] || { log "Cancelled"; exit 0; }
  "$MC_BIN" mirror --overwrite "$snap" "$ALIAS"
  ok "Restored from $snap"
}

verify_backup() {
  local snap="$1"
  [ -z "$snap" ] && { err "Usage: $0 verify <snapshot>"; exit 1; }
  [[ "$snap" != /* ]] && snap="$BACKUP_DIR/$snap"
  [ -d "$snap" ] || { err "Snapshot not found: $snap"; exit 1; }
  local files size
  files=$(find "$snap" -type f | wc -l)
  size=$(du -sh "$snap" | cut -f1)
  log "Snapshot: $snap"; echo "  Files: $files"; echo "  Size:  $size"
  [ "$files" -gt 0 ] && ok "Verification passed" || { err "Snapshot is empty"; exit 1; }
}

cleanup_backups() {
  [ -d "$BACKUP_DIR" ] || { warn "Nothing to clean"; return; }
  log "Removing snapshots older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} \;
  ok "Cleanup done"
}

schedule_backup() {
  local hour="${1:-02}"
  local cmd="cd $MINIO_DIR && ./scripts/backup.sh create >> $BACKUP_DIR/backup.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "minio/scripts/backup.sh"; echo "0 $hour * * * $cmd") | crontab -
  ok "Scheduled daily backup at ${hour}:00"
}

case "${1:-}" in
  create)   create_backup ;;
  list)     list_backups ;;
  restore)  restore_backup "${2:-}" ;;
  verify)   verify_backup "${2:-}" ;;
  cleanup)  cleanup_backups ;;
  schedule) schedule_backup "${2:-}" ;;
  *) echo "Usage: $0 {create|list|restore <snap>|verify <snap>|cleanup|schedule [hour]}"; exit 1 ;;
esac
