#!/bin/bash
# PostgreSQL Backup & Restore Script for Minikube
# Supports: backup, list, restore, verify, cleanup, schedule

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-$POSTGRES_DIR/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
NAMESPACE="infras-postgres"
DEPLOYMENT="postgres"
USER="postgres"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

show_header() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  PostgreSQL Backup & Restore - Minikube                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi

    # Check if PostgreSQL is running
    if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &> /dev/null; then
        log_error "PostgreSQL deployment not found in namespace '$NAMESPACE'"
        log_info "Deploy PostgreSQL first: cd $POSTGRES_DIR && ./scripts/deploy.sh"
        exit 1
    fi

    # Check if PostgreSQL pods are ready
    READY_REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY_REPLICAS" -lt 1 ]; then
        log_error "PostgreSQL is not ready. Please check the deployment status."
        exit 1
    fi

    # Create backup directory if it doesn't exist
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        log_success "Created backup directory: $BACKUP_DIR"
    fi

    log_success "Prerequisites check passed"
}

# Get PostgreSQL password from Vault
get_password() {
    local vault_pod

    # Get Vault pod
    vault_pod=$(kubectl get pod -n infras-vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$vault_pod" ]; then
        log_error "Vault pod not found in infras-vault namespace"
        exit 1
    fi

    # Get password from Vault
    kubectl exec -n infras-vault "$vault_pod" -- vault kv get -field=password infras/postgres/auth 2>/dev/null | tr -d '\n'
}

# Get all user databases (exclude system databases)
get_user_databases() {
    local password
    password=$(get_password)

    # Query PostgreSQL for all user databases
    # Exclude template databases and databases that don't allow connections
    kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
        bash -c "PGPASSWORD='$password' psql -U '$USER' -t -c \
        \"SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn;\"" 2>/dev/null | \
        grep -v '^[[:space:]]*$' || echo ""
}

# Get latest backup file for a database
get_latest_backup() {
    local database="$1"
    ls -t "$BACKUP_DIR"/postgres-backup-"${database}"-*.sql.gz 2>/dev/null | head -n 1
}

# Calculate checksum of database dump (excluding changing metadata)
calculate_checksum() {
    local database="$1"
    local password="$2"

    kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
        bash -c "PGPASSWORD='$password' pg_dump -U '$USER' -d '$database' --format=plain --no-owner --no-acl" 2>/dev/null | \
        grep -v '^--' | grep -v '^\\' | grep -v '^SET ' | grep -v '^$' | sort | md5sum | cut -d' ' -f1
}

# Create backup
create_backup() {
    show_header
    log_info "Creating PostgreSQL backup..."

    check_prerequisites

    local timestamp
    local password
    local databases
    local backup_count=0
    local failed_count=0
    local skipped_count=0

    timestamp=$(date +"%Y%m%d-%H%M%S")

    # Get all user databases
    log_info "Discovering databases..."
    databases=$(get_user_databases)

    if [ -z "$databases" ]; then
        log_error "No user databases found to backup"
        exit 1
    fi

    # Convert to array and count
    local db_array=($databases)
    local total_dbs=${#db_array[@]}

    log_info "Found $total_dbs database(s) to backup: $databases"
    echo ""

    # Get password once for all databases
    password=$(get_password)

    # Backup each database
    for database in $databases; do
        log_info "Checking '$database' for changes..."

        # Calculate current checksum
        local current_checksum
        current_checksum=$(calculate_checksum "$database" "$password")

        if [ -z "$current_checksum" ]; then
            log_error "Failed to calculate checksum for '$database'"
            ((failed_count++)) || true
            continue
        fi

        # Get latest backup for comparison
        local latest_backup
        latest_backup=$(get_latest_backup "$database")

        if [ -n "$latest_backup" ]; then
            # Calculate checksum of latest backup (using same filtering)
            local latest_checksum
            latest_checksum=$(gunzip -c "$latest_backup" | grep -v '^--' | grep -v '^\\' | grep -v '^SET ' | grep -v '^$' | sort | md5sum | cut -d' ' -f1)

            # Compare checksums
            if [ "$current_checksum" = "$latest_checksum" ]; then
                log_warning "Skipped '$database': No changes since last backup"
                log_info "Latest backup: $(basename "$latest_backup")"
                ((skipped_count++)) || true
                continue
            fi
        fi

        # Data has changed or no previous backup exists
        local backup_file
        backup_file="$BACKUP_DIR/postgres-backup-${database}-${timestamp}.sql.gz"

        log_info "Backing up '$database'..."

        # Create backup using pg_dump with compression
        # Redirect stderr to /dev/null to suppress kubectl warnings
        if kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
            bash -c "PGPASSWORD='$password' pg_dump -U '$USER' -d '$database' --format=plain --no-owner --no-acl" 2>/dev/null | \
            gzip > "$backup_file"; then

            # Verify backup was created
            if [ -f "$backup_file" ]; then
                local size
                size=$(du -h "$backup_file" | cut -f1)
                log_success "Backed up '$database': $backup_file ($size)"
                ((backup_count++)) || true
            else
                log_error "Backup file was not created for '$database'"
                ((failed_count++)) || true
            fi
        else
            log_error "Failed to backup '$database'"
            ((failed_count++)) || true
        fi
    done

    echo ""
    log_info "Backup Summary:"
    echo "  Successful: $backup_count/$total_dbs"
    echo "  Skipped:    $skipped_count/$total_dbs (no changes)"
    echo "  Failed:     $failed_count/$total_dbs"
    echo "  Timestamp:  $(date)"

    if [ $failed_count -gt 0 ]; then
        log_warning "Some backups failed! Check logs above."
        exit 1
    fi
}

# List backups
list_backups() {
    show_header
    log_info "Available PostgreSQL backups..."

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.sql.gz 2>/dev/null)" ]; then
        log_warning "No backups found in $BACKUP_DIR"
        echo ""
        log_info "Create a backup: $0 create"
        exit 0
    fi

    echo ""
    printf "%-40s %-15s %-10s\n" "Filename" "Date" "Size"
    printf "%-40s %-15s %-10s\n" "--------------------------------" "--------------" "----------"

    for backup in "$BACKUP_DIR"/postgres-backup-*.sql.gz; do
        if [ -f "$backup" ]; then
            local filename
            local date
            local size

            filename=$(basename "$backup")
            date=$(stat -c '%y' "$backup" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1 || stat -f '%Sm' "$backup")
            size=$(du -h "$backup" | cut -f1)

            printf "%-40s %-15s %-10s\n" "$filename" "$date" "$size"
        fi
    done

    echo ""
    log_info "Total backups: $(ls -1 "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l)"
    log_info "Backup directory: $BACKUP_DIR"
}

# Restore from backup
restore_backup() {
    local backup_file="$1"
    local database

    show_header
    log_info "Restoring PostgreSQL from backup..."

    if [ -z "$backup_file" ]; then
        log_error "Please specify a backup file"
        echo ""
        echo "Usage: $0 restore <backup-file>"
        echo ""
        echo "Available backups:"
        list_backups
        exit 1
    fi

    # Check if backup file exists
    if [[ ! "$backup_file" =~ ^/ ]]; then
        # Relative path, prepend backup directory
        backup_file="$BACKUP_DIR/$backup_file"
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        echo ""
        log_info "Available backups:"
        list_backups
        exit 1
    fi

    # Extract database name from filename
    # Format: postgres-backup-<dbname>-YYYYMMDD-HHMMSS.sql.gz
    local filename
    filename=$(basename "$backup_file")

    if [[ "$filename" =~ postgres-backup-(.+)-[0-9]{8}-[0-9]{6}\.sql\.gz ]]; then
        database="${BASH_REMATCH[1]}"
    else
        log_error "Invalid backup filename format: $filename"
        log_error "Expected format: postgres-backup-<dbname>-YYYYMMDD-HHMMSS.sql.gz"
        exit 1
    fi

    check_prerequisites

    log_warning "This will REPLACE all data in the database '$database'"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    local password
    password=$(get_password)

    log_info "Restoring from: $backup_file"
    log_info "Target database: $database"

    # Drop existing database and recreate
    log_info "Dropping existing database '$database'..."
    kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
        bash -c "PGPASSWORD='$password' psql -U '$USER' -c 'DROP DATABASE IF EXISTS $database;'"

    log_info "Creating new database '$database'..."
    kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
        bash -c "PGPASSWORD='$password' psql -U '$USER' -c 'CREATE DATABASE $database;'"

    # Restore backup
    log_info "Restoring data to '$database'..."
    gunzip -c "$backup_file" | kubectl exec -i -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- \
        bash -c "PGPASSWORD='$password' psql -U '$USER' -d '$database'"

    log_success "Database '$database' restored successfully from: $backup_file"
}

# Verify backup
verify_backup() {
    local backup_file="$1"

    show_header
    log_info "Verifying PostgreSQL backup..."

    if [ -z "$backup_file" ]; then
        log_error "Please specify a backup file"
        echo ""
        echo "Usage: $0 verify <backup-file>"
        echo ""
        echo "Available backups:"
        list_backups
        exit 1
    fi

    # Check if backup file exists
    if [[ ! "$backup_file" =~ ^/ ]]; then
        backup_file="$BACKUP_DIR/$backup_file"
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        echo ""
        log_info "Available backups:"
        list_backups
        exit 1
    fi

    log_info "Verifying: $backup_file"

    # Test if file is valid gzip
    if ! gzip -t "$backup_file" 2>/dev/null; then
        log_error "Backup file is corrupted (invalid gzip format)"
        exit 1
    fi

    # Check if it contains SQL data
    local content_check
    content_check=$(gunzip -c "$backup_file" | head -n 20)

    if echo "$content_check" | grep -q "PostgreSQL database dump"; then
        log_success "Backup file is valid PostgreSQL dump"
    else
        log_error "Backup file does not appear to be a valid PostgreSQL dump"
        exit 1
    fi

    # Show some statistics
    local uncompressed_size
    uncompressed_size=$(gunzip -c "$backup_file" | wc -c | numfmt --to=iec-i --suffix=B)

    local line_count
    line_count=$(gunzip -c "$backup_file" | wc -l)

    echo ""
    log_info "Backup Statistics:"
    echo "  Compressed size:   $(du -h "$backup_file" | cut -f1)"
    echo "  Uncompressed size: $uncompressed_size"
    echo "  Line count:        $line_count"
    echo ""
    log_success "Backup verification passed"
}

# Cleanup old backups
cleanup_backups() {
    show_header
    log_info "Cleaning up old backups (older than $RETENTION_DAYS days)..."

    if [ ! -d "$BACKUP_DIR" ]; then
        log_warning "Backup directory not found: $BACKUP_DIR"
        exit 0
    fi

    # Count total backups
    local total_backups
    total_backups=$(ls -1 "$BACKUP_DIR"/postgres-backup-*.sql.gz 2>/dev/null | wc -l)

    if [ "$total_backups" -eq 0 ]; then
        log_warning "No backups found in $BACKUP_DIR"
        exit 0
    fi

    log_info "Total backups: $total_backups"

    # Find and delete old backups
    local deleted_count=0
    while IFS= read -r -d '' backup; do
        log_info "Deleting: $(basename "$backup")"
        rm "$backup"
        ((deleted_count++))
    done < <(find "$BACKUP_DIR" -name "postgres-backup-*.sql.gz" -type f -mtime +$RETENTION_DAYS -print0 2>/dev/null)

    if [ "$deleted_count" -eq 0 ]; then
        log_success "No old backups to delete (retention: $RETENTION_DAYS days)"
    else
        log_success "Deleted $deleted_count old backup(s)"
    fi

    echo ""
    log_info "Remaining backups:"
    list_backups
}

# Schedule cron job
schedule_backup() {
    local hour="${1:-02}"  # Default 2 AM

    show_header
    log_info "Setting up automated daily backups..."

    # Validate hour
    if ! [[ "$hour" =~ ^[0-9]+$ ]] || [ "$hour" -lt 0 ] || [ "$hour" -gt 23 ]; then
        log_error "Invalid hour. Please specify a value between 0 and 23"
        exit 1
    fi

    local cron_expr="0 $hour * * *"
    local cron_cmd="cd $POSTGRES_DIR && ./scripts/backup.sh create >> $BACKUP_DIR/backup.log 2>&1"

    echo ""
    log_info "Cron Configuration:"
    echo "  Schedule: $cron_expr (daily at $(printf "%02d:00" "$hour"))"
    echo "  Command:  $cron_cmd"
    echo "  Log file: $BACKUP_DIR/backup.log"
    echo ""

    # Check if crontab entry already exists
    if crontab -l 2>/dev/null | grep -q "$POSTGRES_DIR/scripts/backup.sh"; then
        log_warning "A cron job for PostgreSQL backup already exists"
        echo ""
        crontab -l 2>/dev/null | grep "$POSTGRES_DIR/scripts/backup.sh"
        echo ""
        read -p "Do you want to replace it? (yes/no): " confirm

        if [ "$confirm" != "yes" ]; then
            log_info "Schedule setup cancelled"
            exit 0
        fi

        # Remove existing entry
        crontab -l 2>/dev/null | grep -v "$POSTGRES_DIR/scripts/backup.sh" | crontab -
        log_info "Removed existing cron job"
    fi

    # Add new cron job
    (crontab -l 2>/dev/null; echo "$cron_expr $cron_cmd") | crontab -

    log_success "Cron job created successfully"
    echo ""
    log_info "Next backup will run at $(printf "%02d:00" "$hour") tomorrow"
    log_info "View logs: tail -f $BACKUP_DIR/backup.log"
    echo ""
    log_info "To manage cron jobs:"
    echo "  View:    crontab -l"
    echo "  Edit:    crontab -e"
    echo "  Delete:  crontab -l | grep -v '$POSTGRES_DIR/scripts/backup.sh' | crontab -"
}

# Show usage
show_usage() {
    show_header
    cat << EOF
Usage: $0 <command> [options]

Commands:
  create              Create a new backup
  list                List all available backups
  restore <backup>    Restore from a backup file
  verify <backup>     Verify backup integrity
  cleanup             Remove backups older than $RETENTION_DAYS days
  schedule [hour]     Setup daily automated backups (default: 2 AM)

Options:
  BACKUP_DIR          Backup directory (default: $BACKUP_DIR)
  RETENTION_DAYS      Days to keep backups (default: $RETENTION_DAYS)

Environment Variables:
  BACKUP_DIR          Override backup directory location
  RETENTION_DAYS      Override retention period

Examples:
  $0 create                           # Create a new backup
  $0 list                             # List all backups
  $0 restore postgres-backup-20250119-020000.sql.gz
  $0 verify postgres-backup-20250119-020000.sql.gz
  $0 cleanup                          # Remove old backups
  $0 schedule 3                       # Daily backup at 3 AM

Configuration:
  Backup directory: $BACKUP_DIR
  Retention period: $RETENTION_DAYS days
  PostgreSQL:      $NAMESPACE.$DEPLOYMENT
  Database:        $DATABASE

EOF
}

# Main script
main() {
    local command="${1:-}"

    case "$command" in
        create)
            create_backup
            ;;
        list)
            list_backups
            ;;
        restore)
            restore_backup "$2"
            ;;
        verify)
            verify_backup "$2"
            ;;
        cleanup)
            cleanup_backups
            ;;
        schedule)
            schedule_backup "$2"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
