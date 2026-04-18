# PostgreSQL Backup & Restore Guide

Complete guide for backing up and restoring PostgreSQL in Minikube.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Backup Operations](#backup-operations)
- [Restore Operations](#restore-operations)
- [Automated Backups](#automated-backups)
- [Backup Management](#backup-management)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

---

## Quick Start

### First Time Setup

```bash
cd /home/hunghlh/app/infras/minikube-local/k8s-local/postgres

# Create your first backup
./scripts/backup.sh create

# List all backups
./scripts/backup.sh list

# Setup automated daily backups
./scripts/backup.sh schedule
```

### Basic Commands

| Command | Description |
|---------|-------------|
| `./scripts/backup.sh create` | Create a new backup |
| `./scripts/backup.sh list` | List all backups |
| `./scripts/backup.sh restore <file>` | Restore from backup |
| `./scripts/backup.sh verify <file>` | Verify backup integrity |
| `./scripts/backup.sh cleanup` | Remove old backups |
| `./scripts/backup.sh schedule [hour]` | Setup automated backups |

---

## Backup Operations

### Creating Backups

#### Manual Backup

```bash
./scripts/backup.sh create
```

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║  PostgreSQL Backup & Restore - Minikube                    ║
╚════════════════════════════════════════════════════════════╝

ℹ Creating PostgreSQL backup...
ℹ Checking prerequisites...
✓ Prerequisites check passed
ℹ Backup file: /home/hunghlh/app/infras/minikube-local/k8s-local/postgres/backups/postgres-backup-20250119-020000.sql.gz
ℹ Running pg_dump...
✓ Backup created successfully: postgres-backup-20250119-020000.sql.gz (1.2M)

ℹ Backup Details:
  File:     /home/hunghlh/app/infras/minikube-local/k8s-local/postgres/backups/postgres-backup-20250119-020000.sql.gz
  Size:     1.2M
  Database: postgres
  Date:     Sun Jan 19 02:00:00 UTC 2025
```

#### Backup Details

- **Format:** SQL dump (plain text), gzip-compressed
- **Location:** `./backups/` directory
- **Naming:** `postgres-backup-YYYYMMDD-HHMMSS.sql.gz`
- **Content:** Complete database dump (schema + data)
- **Compression:** ~80% space savings

#### What Gets Backed Up?

✅ **Included:**
- All tables and data
- Indexes and constraints
- Sequences and defaults
- Extensions
- Schema structure

❌ **Not Included:**
- Database users/roles (managed separately)
- Configuration settings (postgresql.conf)
- External files

---

## Restore Operations

### Restoring from Backup

#### Full Restore

```bash
./scripts/backup.sh restore postgres-backup-20250119-020000.sql.gz
```

**Process:**
1. ⚠️ **WARNING**: This will REPLACE all existing data
2. Drops existing database
3. Creates fresh database
4. Restores data from backup
5. Verifies completion

**Example Output:**
```
╔════════════════════════════════════════════════════════════╗
║  PostgreSQL Backup & Restore - Minikube                    ║
╚════════════════════════════════════════════════════════════╝

ℹ Restoring PostgreSQL from backup...
ℹ Checking prerequisites...
⚠ This will REPLACE all data in the database 'postgres'

Are you sure you want to continue? (yes/no): yes
ℹ Restoring from: ./backups/postgres-backup-20250119-020000.sql.gz
ℹ Dropping existing database...
ℹ Creating new database...
ℹ Restoring data...
✓ Database restored successfully from: ./backups/postgres-backup-20250119-020000.sql.gz
```

#### Restore Scenarios

**Scenario 1: Accidental Data Deletion**
```bash
# Something went wrong, data was deleted
# Restore from last night's backup
./scripts/backup.sh restore postgres-backup-20250119-020000.sql.gz
```

**Scenario 2: Failed Migration**
```bash
# Migration failed, need to rollback
# 1. Find the backup before migration
./scripts/backup.sh list

# 2. Restore it
./scripts/backup.sh restore postgres-backup-20250118-020000.sql.gz
```

**Scenario 3: Complete Disaster Recovery**
```bash
# PVC was deleted/recreated
# 1. Deploy PostgreSQL (if not running)
cd /home/hunghlh/app/infras/minikube-local/k8s-local/postgres
./scripts/deploy.sh

# 2. Restore from most recent backup
./scripts/backup.sh restore postgres-backup-20250119-020000.sql.gz
```

---

## Automated Backups

### Setting Up Cron Jobs

#### Daily Backups at 2 AM (Default)

```bash
./scripts/backup.sh schedule
```

#### Custom Schedule (e.g., 3 AM)

```bash
./scripts/backup.sh schedule 3
```

#### How It Works

The cron job:
- Runs daily at specified hour (default: 2 AM)
- Executes `./scripts/backup.sh create`
- Logs output to `./backups/backup.log`
- Automatically cleans up old backups (older than 7 days)

#### Managing Cron Jobs

```bash
# View current cron jobs
crontab -l

# Edit cron jobs
crontab -e

# Remove backup cron job
crontab -l | grep -v '/home/hunghlh/app/infras/minikube-local/k8s-local/postgres/scripts/backup.sh' | crontab -

# View backup logs
tail -f /home/hunghlh/app/infras/minikube-local/k8s-local/postgres/backups/backup.log
```

#### Example Cron Output

```bash
$ crontab -l
0 2 * * * cd /home/hunghlh/app/infras/minikube-local/k8s-local/postgres && ./scripts/backup.sh create >> /home/hunghlh/app/infras/minikube-local/k8s-local/postgres/backups/backup.log 2>&1
```

---

## Backup Management

### Listing Backups

```bash
./scripts/backup.sh list
```

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║  PostgreSQL Backup & Restore - Minikube                    ║
╚════════════════════════════════════════════════════════════╝

ℹ Available PostgreSQL backups...

Filename                                  Date            Size
---------------------------------------- -------------- ----------
postgres-backup-20250119-020000.sql.gz   2025-01-19     1.2M
postgres-backup-20250118-020000.sql.gz   2025-01-18     1.1M
postgres-backup-20250117-020000.sql.gz   2025-01-17     1.0M
...

ℹ Total backups: 7
ℹ Backup directory: /home/hunghlh/app/infras/minikube-local/k8s-local/postgres/backups
```

### Verifying Backups

```bash
./scripts/backup.sh verify postgres-backup-20250119-020000.sql.gz
```

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║  PostgreSQL Backup & Restore - Minikube                    ║
╚════════════════════════════════════════════════════════════╝

ℹ Verifying PostgreSQL backup...
ℹ Verifying: ./backups/postgres-backup-20250119-020000.sql.gz
✓ Backup file is valid PostgreSQL dump

ℹ Backup Statistics:
  Compressed size:   1.2M
  Uncompressed size: 5.8M
  Line count:        45230

✓ Backup verification passed
```

### Cleaning Up Old Backups

```bash
./scripts/backup.sh cleanup
```

**What It Does:**
- Removes backups older than 7 days (configurable via `RETENTION_DAYS`)
- Shows what was deleted
- Lists remaining backups

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║  PostgreSQL Backup & Restore - Minikube                    ║
╚════════════════════════════════════════════════════════════╝

ℹ Cleaning up old backups (older than 7 days)...
ℹ Total backups: 10
ℹ Deleting: postgres-backup-20250110-020000.sql.gz
ℹ Deleting: postgres-backup-20250109-020000.sql.gz
ℹ Deleting: postgres-backup-20250108-020000.sql.gz
✓ Deleted 3 old backup(s)

ℹ Remaining backups:
[Lists remaining backups...]
```

---

## Troubleshooting

### Common Issues

#### Issue: "kubectl not found"

**Solution:**
```bash
# Install kubectl
# Ubuntu/Debian
sudo apt-get install kubectl

# Or use the minikube bundled kubectl
minikube kubectl -- version
```

#### Issue: "PostgreSQL deployment not found"

**Solution:**
```bash
# Deploy PostgreSQL first
cd /home/hunghlh/app/infras/minikube-local/k8s-local/postgres
./scripts/deploy.sh
```

#### Issue: "Backup file was not created"

**Possible Causes:**
1. PostgreSQL pod not ready
2. Insufficient disk space
3. Permission issues

**Solution:**
```bash
# Check pod status
kubectl get pods -n infras-postgres

# Check disk space
df -h

# Check pod logs
kubectl logs -n infras-postgres -l app=postgres -c postgres
```

#### Issue: "Restore failed"

**Possible Causes:**
1. Corrupted backup file
2. Insufficient memory in pod
3. Database conflicts

**Solution:**
```bash
# Verify backup first
./scripts/backup.sh verify <backup-file>

# Check pod resources
kubectl describe pod -n infras-postgres -l app=postgres

# Try manual restore for more details
gunzip -c <backup-file> | kubectl exec -i -n infras-postgres deployment/postgres -- \
  psql -U postgres -d postgres
```

#### Issue: "Vault pod not found"

**Solution:**
```bash
# Check if Vault is deployed
kubectl get pods -n infras-vault

# Deploy Vault if needed
cd /home/hunghlh/app/infras/minikube-local/k8s-local/vault
./scripts/deploy.sh
```

### Getting Help

```bash
# Show usage
./scripts/backup.sh help

# Check script version
ls -l ./scripts/backup.sh

# View logs
tail -f ./backups/backup.log
```

---

## Best Practices

### Backup Strategy

1. **Frequency**: Daily automated backups
2. **Retention**: Keep 7 days of backups
3. **Verification**: Verify critical backups after creation
4. **Testing**: Test restore procedure regularly

### Before Major Changes

```bash
# 1. Create backup
./scripts/backup.sh create

# 2. Verify backup
./scripts/backup.sh verify postgres-backup-<latest>.sql.gz

# 3. Note the backup name
echo "Backup: postgres-backup-<latest>.sql.gz" > /tmp/pre-migration-backup.txt

# 4. Proceed with changes
# ... perform migration/schema changes ...
```

### Monitoring

```bash
# Check backup cron job status
systemctl status cron  # or cronie/crond depending on distro

# View recent backup logs
tail -n 50 ./backups/backup.log

# Check disk usage
du -sh ./backups

# Monitor backup trends
ls -lh ./backups/postgres-backup-*.sql.gz | tail -n 10
```

### Security

✅ **Do:**
- Keep backups secure (contains sensitive data)
- Use appropriate file permissions
- Consider encrypting backups for long-term storage
- Regularly test restore procedures

❌ **Don't:**
- Store backups in public repositories
- Share backups via unencrypted channels
- Ignore backup failures
- Keep backups indefinitely without cleanup

### Advanced Configuration

#### Custom Backup Directory

```bash
export BACKUP_DIR=/mnt/backups/postgres
./scripts/backup.sh create
```

#### Custom Retention Period

```bash
export RETENTION_DAYS=30
./scripts/backup.sh cleanup
```

#### Both Together

```bash
export BACKUP_DIR=/mnt/backups/postgres
export RETENTION_DAYS=30
./scripts/backup.sh create
```

---

## Integration with Other Tools

### PostgreSQL Client Tools

```bash
# Connect to database for queries
kubectl exec -n infras-postgres deployment/postgres -- psql -U postgres

# Export specific table
kubectl exec -n infras-postgres deployment/postgres -- \
  pg_dump -U postgres -t your_table postgres > your_table.sql
```

### Monitoring & Alerts

```bash
# Check backup script runs
grep "Backup created successfully" ./backups/backup.log | tail -n 7

# Alert on backup failures (example)
if ! ./scripts/backup.sh create; then
    echo "Backup failed!" | mail -s "PostgreSQL Backup Alert" admin@example.com
fi
```

---

## Quick Reference

### Essential Commands

```bash
# Create backup
./scripts/backup.sh create

# List backups
./scripts/backup.sh list

# Restore backup
./scripts/backup.sh restore <file>

# Verify backup
./scripts/backup.sh verify <file>

# Cleanup old backups
./scripts/backup.sh cleanup

# Schedule automated backups
./scripts/backup.sh schedule [hour]

# Show help
./scripts/backup.sh help
```

### File Locations

- **Backup script**: `./scripts/backup.sh`
- **Backup directory**: `./backups/`
- **Log file**: `./backups/backup.log`
- **This guide**: `./BACKUP_GUIDE.md`

### Default Configuration

| Setting | Value |
|---------|-------|
| Backup directory | `./backups/` |
| Retention period | 7 days |
| Compression | gzip |
| Database | postgres |
| User | postgres |
| Namespace | infras-postgres |
| Deployment | postgres |

---

## Additional Resources

- [PostgreSQL Documentation](https://www.postgresql.org/docs/17/backup.html)
- [Main README](./README.md)
- [Connection Guide](./CONNECTION_GUIDE.md)
- [Deployment Script](./scripts/deploy.sh)

---

## Support

For issues or questions:
1. Check this guide's troubleshooting section
2. Review logs: `./backups/backup.log`
3. Verify pod status: `kubectl get pods -n infras-postgres`
4. Check PostgreSQL logs: `kubectl logs -n infras-postgres -l app=postgres -c postgres`

---

**Last Updated**: 2025-01-19
**Version**: 1.0.0
