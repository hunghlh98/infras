#!/bin/bash
# Command Tracker for /home/hunghlh/app/infras/
# Logs all command executions with timestamps, session info, and context

TRACKING_DIR="${INFRAS_TRACKING_DIR:-/home/hunghlh/app/infras}"
LOG_DIR="$TRACKING_DIR/.command-logs"
LOG_FILE="$LOG_DIR/commands-$(date +%Y%m%d).log"
SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Format current timestamp
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get current git branch if in a git repo
get_git_branch() {
    git branch --show-current 2>/dev/null || echo "no-git"
}

# Get relative path from tracking directory
get_relative_path() {
    local current_pwd="$PWD"
    if [[ "$current_pwd" == "$TRACKING_DIR"* ]]; then
        echo "${current_pwd#$TRACKING_DIR/}"
    else
        echo "outside-project"
    fi
}

# Log command execution
log_command() {
    # Only log if we're in the tracking directory
    if [[ "$PWD" == "$TRACKING_DIR"* ]]; then
        local cmd="$1"
        local exit_code="$2"
        local relative_path
        relative_path=$(get_relative_path)
        local git_branch
        git_branch=$(get_git_branch)

        {
            echo "=== COMMAND LOG ==="
            echo "Timestamp:   $(timestamp)"
            echo "Session:     $SESSION_ID"
            echo "Directory:   $relative_path"
            echo "Git Branch:  $git_branch"
            echo "Exit Code:   $exit_code"
            echo "Command:     $cmd"
            echo ""
        } >> "$LOG_FILE"
    fi
}

# Log directory changes
log_cd() {
    if [[ "$PWD" == "$TRACKING_DIR"* ]]; then
        {
            echo "=== DIRECTORY CHANGE ==="
            echo "Timestamp:   $(timestamp)"
            echo "Session:     $SESSION_ID"
            echo "Changed to:  $(get_relative_path)"
            echo ""
        } >> "$LOG_FILE"
    fi
}

# Show tracking statistics
show_stats() {
    local today_log="$LOG_DIR/commands-$(date +%Y%m%d).log"
    if [[ -f "$today_log" ]]; then
        echo "📊 Today's Command Statistics:"
        echo "================================"
        echo "Session: $SESSION_ID"
        echo "Log file: $today_log"
        echo ""
        echo "Commands executed today:"
        grep -c "=== COMMAND LOG ===" "$today_log" 2>/dev/null || echo "0"
        echo ""
        echo "Recent commands (last 10):"
        grep -A 6 "=== COMMAND LOG ===" "$today_log" 2>/dev/null | tail -20
    else
        echo "No commands logged yet today."
    fi
}

# Search command history
search_commands() {
    local search_term="$1"
    local days="${2:-7}"

    echo "🔍 Searching for: '$search_term' (last $days days)"
    echo "=========================================="

    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$LOG_DIR/commands-$log_date.log"

        if [[ -f "$log_file" ]]; then
            echo "📅 $log_date:"
            grep -B 2 -A 4 "$search_term" "$log_file" 2>/dev/null | head -20
            echo ""
        fi
    done
}

# Show top commands
top_commands() {
    local days="${1:-7}"

    echo "🏆 Top Commands (last $days days)"
    echo "================================"

    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$LOG_DIR/commands-$log_date.log"

        if [[ -f "$log_file" ]]; then
            grep "^Command:" "$log_file" 2>/dev/null
        fi
    done | sort | uniq -c | sort -rn | head -20
}

# Export functions for use in shell
export -f log_command log_cd show_stats search_commands top_commands

# Main initialization
init_tracker() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════╗
║  Command Tracker Initialized                              ║
╚════════════════════════════════════════════════════════════╝

Tracking commands in: $TRACKING_DIR
Session ID: $SESSION_ID

Available commands:
  show_stats          - Show today's statistics
  search_commands     - Search command history
  top_commands        - Show most used commands

Logs stored in: $LOG_DIR
EOF
}

# Run initialization if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init_tracker
fi
