# Zsh Command Tracker Integration
# Add this to your ~/.zshrc or source it separately

# Configuration
INFRAS_TRACKING_DIR="/home/hunghlh/app/infras"
INFRAS_LOG_DIR="$INFRAS_TRACKING_DIR/.command-logs"

# Create log directory
mkdir -p "$INFRAS_LOG_DIR" 2>/dev/null

# Session tracking
INFRAS_SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
INFRAS_LOG_FILE="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"

# Helper functions for tracking
_infras_get_relative_path() {
    local current_pwd="$PWD"
    if [[ "$current_pwd" == "$INFRAS_TRACKING_DIR"* ]]; then
        echo "${current_pwd#$INFRAS_TRACKING_DIR/}"
    else
        echo "outside-project"
    fi
}

_infras_get_git_branch() {
    git branch --show-current 2>/dev/null || echo "no-git"
}

_infras_log_command() {
    # Only log if we're in the tracking directory
    if [[ "$PWD" == "$INFRAS_TRACKING_DIR"* ]]; then
        local cmd="$1"
        local exit_code="$2"
        local start_time="$3"
        local end_time="$4"

        {
            echo "=== COMMAND LOG ==="
            echo "Timestamp:   $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Session:     $INFRAS_SESSION_ID"
            echo "Directory:   $(_infras_get_relative_path)"
            echo "Git Branch:  $(_infras_get_git_branch)"
            echo "Exit Code:   $exit_code"
            echo "Duration:    $((end_time - start_time))s"
            echo "Command:     $cmd"
            echo ""
        } >> "$INFRAS_LOG_FILE"
    fi
}

# Pre-execution hook - runs before each command
_infras_preexec() {
    # Skip if the command is empty or just whitespace
    [[ -z "$1" ]] || [[ "$1" =~ ^[[:space:]]+$ ]] && return

    INFRAS_CMD_START_TIME=$(date +%s)
    INFRAS_LAST_CMD="$1"
}

# Post-execution hook - runs after each command
_infras_precmd() {
    local exit_code=$?  # Capture exit code FIRST
    if [[ -n "$INFRAS_LAST_CMD" && -n "$INFRAS_CMD_START_TIME" ]]; then
        local end_time=$(date +%s)
        _infras_log_command "$INFRAS_LAST_CMD" "$exit_code" "$INFRAS_CMD_START_TIME" "$end_time"
        INFRAS_LAST_CMD=""
        INFRAS_CMD_START_TIME=""
    fi
    return $exit_code  # Preserve the exit code
}

# Register hooks
autoload -U add-zsh-hook
add-zsh-hook preexec _infras_preexec
add-zsh-hook precmd _infras_precmd

# Interactive commands for statistics
infras_stats() {
    local today_log="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"
    if [[ -f "$today_log" ]]; then
        echo "📊 Today's Command Statistics:"
        echo "================================"
        echo "Session: $INFRAS_SESSION_ID"
        echo "Project: $INFRAS_TRACKING_DIR"
        echo ""

        local cmd_count
        cmd_count=$(grep -c "=== COMMAND LOG ===" "$today_log" 2>/dev/null || echo "0")
        echo "Commands executed: $cmd_count"
        echo ""

        # Count success vs failure
        local success failed
        success=$(grep -c "Exit Code:   0" "$today_log" 2>/dev/null || echo "0")
        failed=$((cmd_count - success))
        if [[ $cmd_count -gt 0 ]]; then
            local success_rate=$((success * 100 / cmd_count))
            echo "Success rate: $success_rate% ($success successful, $failed failed)"
            echo ""
        fi

        # Count by directory
        echo "Commands by directory:"
        grep "Directory:" "$today_log" 2>/dev/null | sort | uniq -c | sort -rn | head -5
        echo ""

        # Recent commands (using improved parsing)
        echo "Recent commands (last 3):"
        grep -A 8 "=== COMMAND LOG ===" "$today_log" 2>/dev/null | awk -v count="3" '
            BEGIN { cmd_count = 0 }
            /^=== COMMAND LOG ===/ {
                if (cmd_count >= count) exit
                cmd_count++
                getline; getline; getline; directory = $2
                getline; getline; getline; getline; getline
                gsub(/^Command:     /, "", $0)
                cmd = $0
                printf "   • [%s] %s\n", directory, cmd
            }
        '
    else
        echo "No commands logged yet today."
        echo "Log file: $today_log"
    fi
}

infras_search() {
    local search_term="$1"
    local days="${2:-7}"

    if [[ -z "$search_term" ]]; then
        echo "Usage: infras_search <search-term> [days]"
        return 1
    fi

    echo "🔍 Searching for: '$search_term' (last $days days)"
    echo "=========================================="
    echo ""

    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"

        if [[ -f "$log_file" ]]; then
            local results
            results=$(grep -i "$search_term" "$log_file" 2>/dev/null)
            if [[ -n "$results" ]]; then
                echo "📅 $log_date:"
                echo "$results"
                echo ""
            fi
        fi
    done
}

infras_top() {
    local days="${1:-7}"
    local temp_file=$(mktemp)

    echo "🏆 Top Commands (last $days days)"
    echo "================================"
    echo ""

    # Extract commands from all log files
    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"

        if [[ -f "$log_file" ]]; then
            grep "^Command:" "$log_file" 2>/dev/null >> "$temp_file"
        fi
    done

    if [[ -s "$temp_file" ]]; then
        sort "$temp_file" | uniq -c | sort -rn | head -20
    else
        echo "No commands found in the last $days days."
    fi

    rm -f "$temp_file"
}

infras_recent() {
    local count="${1:-10}"

    echo "🕐 Recent Commands (last $count)"
    echo "================================"
    echo ""

    local today_log="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"
    if [[ -f "$today_log" ]]; then
        # Use grep to find command blocks, then parse with awk
        grep -A 8 "=== COMMAND LOG ===" "$today_log" 2>/dev/null | awk -v count="$count" '
            BEGIN { cmd_count = 0 }
            /^=== COMMAND LOG ===/ {
                if (cmd_count >= count) exit
                cmd_count++
                getline # Timestamp: line
                timestamp = $2 " " $3
                getline # Session: line (skip)
                getline # Directory: line
                directory = $2
                getline # Git Branch: line (skip)
                getline # Exit Code: line
                exit_code = $NF
                getline # Duration: line (skip)
                getline # Command: line
                gsub(/^Command:     /, "", $0)
                cmd = $0

                printf "🔹 %s\n", timestamp
                printf "   [%s] %s\n", directory, cmd
                if (exit_code != 0) printf "   ❌ Exit code: %s\n", exit_code
                print ""
            }
        '
    else
        echo "No commands logged yet today."
    fi
}

infras_summary() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Infras Command Tracker                                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Session:       $INFRAS_SESSION_ID"
    echo "Tracking dir:  $INFRAS_TRACKING_DIR"
    echo "Log directory: $INFRAS_LOG_DIR"
    echo ""
    echo "Available commands:"
    echo "  infras_stats    - Show today's statistics"
    echo "  infras_search   - Search command history"
    echo "  infras_top      - Show most used commands"
    echo "  infras_recent   - Show recent commands"
    echo "  infras_raw      - Show raw log entries (debug)"
    echo "  infras_summary  - Show this help"
    echo ""
}

# Debug function to show raw log entries
infras_raw() {
    local count="${1:-5}"
    echo "🔍 Raw Log Entries (last $count):"
    echo "===================================="
    echo ""

    local today_log="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"
    if [[ -f "$today_log" ]]; then
        tail -n "$((count * 10))" "$today_log"
    else
        echo "No log file found for today."
    fi
}

# Show notification when entering the tracked directory
infras_chpwd() {
    if [[ "$PWD" == "$INFRAS_TRACKING_DIR"* ]]; then
        # Update log file for new day
        INFRAS_LOG_FILE="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"

        # Log directory change
        {
            echo "=== SESSION START ==="
            echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Session:   $INFRAS_SESSION_ID"
            echo "Directory: $(_infras_get_relative_path)"
            echo "User:      $USER"
            echo "Host:      $HOST"
            echo ""
        } >> "$INFRAS_LOG_FILE"
    fi
}

# Register directory change hook
add-zsh-hook chpwd infras_chpwd

# Initialize on startup
infras_chpwd

# Notification message (only show once per session)
if [[ -z "$INFRAS_TRACKER_INITIALIZED" ]]; then
    echo "✅ Command tracking active for /home/hunghlh/app/infras/"
    echo "   Type 'infras_summary' for available commands"
    export INFRAS_TRACKER_INITIALIZED=1
fi
