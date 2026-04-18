# Command Tracking System for /home/hunghlh/app/infras/

Complete command execution tracking with logging, statistics, and search capabilities.

## 🚀 Quick Setup

### Option 1: Add to your .zshrc (Recommended)

```bash
# Add this line to the end of your ~/.zshrc
source /home/hunghlh/app/infras/.zsh-tracker.zsh
```

Then restart your shell or run:
```bash
source ~/.zshrc
```

### Option 2: Source Manually

```bash
# Track commands for current session only
source /home/hunghlh/app/infras/.zsh-tracker.zsh
```

## 📊 What Gets Tracked

Every command executed in `/home/hunghlh/app/infras/` logs:

- **Timestamp**: When the command was executed
- **Session ID**: Unique identifier for your terminal session
- **Directory**: Relative path within the project
- **Git Branch**: Current git branch (if applicable)
- **Exit Code**: Success (0) or failure (non-0)
- **Duration**: How long the command took to run
- **Command**: The full command that was executed

## 📁 Log Storage

Logs are stored in: `/home/hunghlh/app/infras/.command-logs/`

```
.command-logs/
├── commands-20260419.log    # Today's commands
├── commands-20260418.log    # Yesterday's commands
└── commands-20260417.log    # Previous day's commands
```

Each log file contains:
```
=== COMMAND LOG ===
Timestamp:   2026-04-19 14:30:45
Session:     20260419-143045-12345
Directory:   minikube-local/k8s-local/postgres
Git Branch:  main
Exit Code:   0
Duration:    2s
Command:     ./scripts/backup.sh create
```

## 🎯 Available Commands

Once tracking is enabled, use the single `infras` command with flags:

### `infras` (Default: Show Help)

```bash
infras                    # Show help
```

### `infras --stats` - Statistics

```bash
infras --stats            # Today's statistics
infras --stats --days=7   # Weekly statistics
```

Shows:
- Total commands executed
- Success/failure counts
- Success rate percentage
- Top directories used

### `infras --top` - Most Used Commands

```bash
infras --top              # Top 20 commands
infras --top --limit=10   # Top 10 commands
infras --top --days=7     # Top commands this week
```

### `infras --recent` - Recent Commands

```bash
infras --recent           # Last 20 commands
infras --recent --limit=5 # Last 5 commands
```

Shows recent commands with timestamps, directories, and exit status.

### `infras --search` - Search Command History

```bash
infras --search kubectl   # Search for "kubectl"
infras --search "backup" --days=7  # Search this week
```

### `infras --raw` - Raw Log Entries

```bash
infras --raw              # Last 5 raw entries
infras --raw --limit=10   # Last 10 raw entries
```

Shows raw log data for debugging.

## 🔍 Search Examples

### Find All Backup Operations

```bash
infras --search "backup.sh"
```

### Find Failed Commands

```bash
infras --search "Exit Code: [1-9]"
```

### Find kubectl Commands

```bash
infras --search "kubectl"
```

### Find Git Operations

```bash
infras --search "git"
```

## 📈 Use Cases

### 1. Track Your Work Session

```bash
# Start working on postgres setup
cd /home/hunghlh/app/infras/minikube-local/k8s-local/postgres

# Do your work...
./scripts/backup.sh create
kubectl get pods -n infras-postgres
./scripts/backup.sh list

# Check what you did
infras --stats
```

### 2. Remember What You Did Yesterday

```bash
# Search for commands from a specific day
infras --search "2026-04-18" 2
```

### 3. Find That Command You Used Last Week

```bash
# Search for keywords
infras --search "minikube" 7
```

### 4. Analyze Your Workflow

```bash
# See your most used commands
infras --top 7
```

### 5. Debug Issues

```bash
# Find failed commands
infras --search "Exit Code: [1-9]" 7
```

## 🔧 Advanced Usage

### View Raw Logs

```bash
# Today's log
cat /home/hunghlh/app/infras/.command-logs/commands-$(date +%Y%m%d).log

# Follow logs in real-time
tail -f /home/hunghlh/app/infras/.command-logs/commands-$(date +%Y%m%d).log
```

### Export Command History

```bash
# Export this week's commands to a file
grep -h "^Command:" /home/hunghlh/app/infras/.command-logs/commands-*.log > my_commands.txt
```

### Analyze with Custom Scripts

```bash
# Count commands by exit code
grep "Exit Code:" /home/hunghlh/app/infras/.command-logs/commands-*.log | sort | uniq -c

# Find long-running commands
grep "Duration:" /home/hunghlh/app/infras/.command-logs/commands-*.log | awk '$NF > 60'
```

## 🛠️ Customization

### Change Tracking Directory

Edit `.zsh-tracker.zsh`:
```zsh
INFRAS_TRACKING_DIR="/your/custom/path"
```

### Change Log Retention

Add to your crontab:
```bash
# Delete logs older than 30 days
0 0 * * * find /home/hunghlh/app/infras/.command-logs/ -name "commands-*.log" -mtime +30 -delete
```

### Track Multiple Directories

Duplicate the tracking functions with different directory names and log files.

## 🚨 Privacy & Security

**What gets logged:**
- ✅ Commands you type
- ✅ Working directory
- ✅ Git branch
- ✅ Exit codes and timing

**What does NOT get logged:**
- ❌ Command output
- ❌ Passwords or sensitive data
- ❌ Commands outside the tracking directory

**Security notes:**
- Log files are readable only by you (mode 600)
- Logs are stored locally, not sent anywhere
- You can delete logs at any time

## 📝 Troubleshooting

### Tracking Not Working

```bash
# Check if tracker is loaded
echo $INFRAS_TRACKER_INITIALIZED

# Should show: 1
```

### Commands Not Being Logged

1. Make sure you're in `/home/hunghlh/app/infras/` directory
2. Check that `.zsh-tracker.zsh` is sourced in your `.zshrc`
3. Verify log directory exists: `ls -la /home/hunghlh/app/infras/.command-logs/`

### Performance Issues

If tracking slows down your shell, you can:
1. Disable tracking temporarily: `unset INFRAS_TRACKER_INITIALIZED`
2. Remove from `.zshrc` and source manually when needed
3. Adjust logging frequency

## 🎓 Tips & Tricks

### 1. Session Tracking

Each terminal session gets a unique ID. This helps you distinguish between:
- Different terminal windows
- Different days
- Different SSH sessions

### 2. Git Context

The tracker automatically logs your git branch, so you can see:
- What branch you were on for each command
- Which commands were run on which branch

### 3. Exit Code Tracking

Exit codes help you find:
- Failed commands (non-zero exit codes)
- Successful commands (exit code 0)
- Patterns of failures

### 4. Duration Tracking

See how long your commands take:
- Identify slow operations
- Optimize your workflow
- Find performance bottlenecks

## 📚 Example Workflows

### Morning Development Session

```bash
# Start your day
cd /home/hunghlh/app/infras

# Check what you did yesterday
infras --recent 20

# Start working
cd minikube-local
./up.sh

# Check your session so far
infras --stats
```

### Weekly Review

```bash
# See your week in review
infras --top 7

# Find all failed commands
infras --search "Exit Code: [1-9]" 7

# See your most active directories
infras --stats
```

### Project Handoff

```bash
# Export command history for documentation
grep -h "^Command:" /home/hunghlh/app/infras/.command-logs/commands-*.log > handoff_commands.txt
```

## 🔗 Integration with Other Tools

### Combine with `fzf` for fuzzy search

```bash
infras --search "" 30 | fzf
```

### Use with `jq` for JSON parsing

```bash
# If you convert logs to JSON format
cat commands-*.log | jq '.command' | sort | uniq -c
```

### Integrate with task management

```bash
# Log commands to your todo system
infras --recent 5 >> todo.txt
```

## 📞 Support

If you need help or want to report issues:

1. Check the log files: `ls -la /home/hunghlh/app/infras/.command-logs/`
2. Verify tracker is loaded: `echo $INFRAS_TRACKER_INITIALIZED`
3. Test manually: `source /home/hunghlh/app/infras/.zsh-tracker.zsh`

---

**Happy Tracking!** 🎯

Remember: This tool helps you understand your workflow and productivity patterns.
