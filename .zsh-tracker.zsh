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

# Single command interface with flags
infras() {
    local FLAG=""
    local LIMIT=20
    local DAYS=1
    local PATTERN=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stats|-s)
                FLAG="stats"
                shift
                ;;
            --top|-t)
                FLAG="top"
                shift
                ;;
            --recent|-r)
                FLAG="recent"
                shift
                ;;
            --search|-S)
                FLAG="search"
                shift
                PATTERN="$1"
                shift
                ;;
            --raw)
                FLAG="raw"
                shift
                ;;
            --help|-h)
                _infras_show_help
                return 0
                ;;
            --limit=*)
                LIMIT="${1#*=}"
                shift
                ;;
            --days=*)
                DAYS="${1#*=}"
                shift
                ;;
            *)
                echo "❌ Unknown option: $1"
                _infras_show_help
                return 1
                ;;
        esac
    done

    # Default: show help
    if [[ -z "$FLAG" ]]; then
        _infras_show_help
        return 0
    fi

    # Execute command
    case "$FLAG" in
        stats) _infras_stats "$DAYS" ;;
        top) _infras_top "$DAYS" "$LIMIT" ;;
        recent) _infras_recent "$LIMIT" ;;
        search) _infras_search "$PATTERN" "$DAYS" ;;
        raw) _infras_raw "$LIMIT" ;;
    esac
}

_infras_show_help() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════╗
║  Infras Command Tracking                                   ║
╚════════════════════════════════════════════════════════════╝

Usage: infras [flag] [options]

Flags:
  --stats, -s       Show today's statistics
  --top, -t         Show most used commands
  --recent, -r      Show recent commands
  --search, -S      Search command history
  --raw             Show raw log entries
  --help, -h        Show this help

Options:
  --limit=N         Limit results (default: 20)
  --days=N          Number of days (default: 1)

Examples:
  infras                    Show this help
  infras --stats            Today's statistics
  infras --top              Most used commands
  infras --recent           Recent commands
  infras --search kubectl   Search for "kubectl"
  infras --top --limit=10   Top 10 commands
  infras --stats --days=7   Weekly statistics

EOF
}

_infras_stats() {
    local days="${1:-1}"
    local temp_file=$(mktemp)

    echo "📊 Statistics (Last $days day(s))"
    echo "================================"
    echo ""

    # Collect logs
    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"
        if [[ -f "$log_file" ]]; then
            grep "^Command:" "$log_file" 2>/dev/null >> "$temp_file"
            grep "^Exit Code:" "$log_file" 2>/dev/null >> "$temp_file"
        fi
    done

    if [[ ! -s "$temp_file" ]]; then
        echo "No commands found."
        rm -f "$temp_file"
        return
    fi

    local total=$(grep -c "^Command:" "$temp_file" 2>/dev/null || echo "0")
    local success=$(grep -c "Exit Code:   0" "$temp_file" 2>/dev/null || echo "0")
    local failed=$((total - success))

    echo "Total Commands:    $total"
    echo "Successful:        $success"
    echo "Failed:            $failed"

    if [[ $total -gt 0 ]]; then
        local rate=$((success * 100 / total))
        echo "Success Rate:       ${rate}%"
    fi
    echo ""

    # Top directories
    echo "Top Directories:"
    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"
        if [[ -f "$log_file" ]]; then
            grep "^Directory:" "$log_file" 2>/dev/null
        fi
    done | sed 's/^Directory:[[:space:]]*//' | sort | uniq -c | sort -rn | head -5 | awk '{printf "  %3d  %s\n", $1, $2}'

    rm -f "$temp_file"
}

_infras_top() {
    local days="${1:-7}"
    local limit="${2:-20}"
    local temp_file=$(mktemp)

    echo "🏆 Top Commands (Last $days days)"
    echo "================================"
    echo ""

    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"
        if [[ -f "$log_file" ]]; then
            grep "^Command:" "$log_file" 2>/dev/null >> "$temp_file"
        fi
    done

    if [[ -s "$temp_file" ]]; then
        sort "$temp_file" | uniq -c | sort -rn | head -n "$limit" | \
            awk '{printf "  %3d  %s\n", $1, substr($0, index($0,$2))}'
    else
        echo "No commands found."
    fi

    rm -f "$temp_file"
}

_infras_recent() {
    local limit="${1:-20}"
    local today_log="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"

    echo "🕐 Recent Commands"
    echo "=================="
    echo ""

    if [[ ! -f "$today_log" ]]; then
        echo "No commands logged yet today."
        return
    fi

    grep -A 8 "=== COMMAND LOG ===" "$today_log" 2>/dev/null | awk -v count="$limit" '
        BEGIN { cmd_count = 0 }
        /^=== COMMAND LOG ===/ {
            if (cmd_count >= count) exit
            cmd_count++
            getline
            timestamp = $2 " " $3
            getline
            getline
            directory = $2
            getline
            getline
            exit_code = $NF
            getline
            getline
            gsub(/^Command:     /, "", $0)
            cmd = $0

            symbol = (exit_code != 0) ? "❌" : "✅"
            printf "%s [%s] %s\n", timestamp, directory, cmd
            if (exit_code != 0) printf "   %s Exit: %s\n", symbol, exit_code
            print ""
        }
    '
}

_infras_search() {
    local pattern="$1"
    local days="${2:-1}"

    if [[ -z "$pattern" ]]; then
        echo "❌ Search pattern required"
        echo "Usage: infras --search <pattern> [--days=N]"
        return 1
    fi

    echo "🔍 Search: \"$pattern\" (Last $days days)"
    echo "========================================"
    echo ""

    local found=0
    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$INFRAS_LOG_DIR/commands-$log_date.log"

        if [[ -f "$log_file" ]]; then
            while IFS= read -r line; do
                if [[ "$line" == Command:*"$pattern"* ]]; then
                    echo "  ${line#Command:     }"
                    ((found++))
                fi
            done < "$log_file"
        fi
    done

    [[ $found -eq 0 ]] && echo "No matches found."
}

_infras_raw() {
    local count="${1:-5}"
    local today_log="$INFRAS_LOG_DIR/commands-$(date +%Y%m%d).log"

    echo "🔍 Raw Log Entries (Last $count)"
    echo "================================"
    echo ""

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

# Cleanup old function names from previous versions
unset -f infras_stats infras_search infras_top infras_recent infras_raw infras_summary 2>/dev/null

# Initialize on startup
infras_chpwd

# Notification message (only show once per session)
if [[ -z "$INFRAS_TRACKER_INITIALIZED" ]]; then
    echo "✅ Command tracking active for /home/hunghlh/app/infras/"
    echo "   Type 'infras' for available commands"
    export INFRAS_TRACKER_INITIALIZED=1
fi
