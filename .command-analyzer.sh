#!/bin/bash
# Command Analyzer - Advanced analytics for command logs
# Usage: ./command-analyzer.sh [command] [options]

LOG_DIR="/home/hunghlh/app/infras/.command-logs"
TODAY=$(date +%Y%m%d)
TODAY_LOG="$LOG_DIR/commands-$TODAY.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

show_usage() {
    cat << EOF
╔════════════════════════════════════════════════════════════╗
║  Command Analyzer - Advanced Log Analytics                ║
╚════════════════════════════════════════════════════════════╝

Usage: $0 <command> [options]

Commands:
  today              Show today's command summary
  week               Show weekly summary
  analyze            Deep analysis of patterns
  failed             Show only failed commands
  slow               Show slow commands (>10s)
  directories        Commands by directory
  git                Commands by git branch
  timeline           Timeline view of commands
  export             Export to CSV/JSON
  clean              Clean old logs

Options:
  --days=N           Specify number of days (default: 7)
  --limit=N          Limit results (default: 20)
  --format=fmt       Output format (text, json, csv)

Examples:
  $0 today                    Today's summary
  $0 week --days=30           30-day summary
  $0 failed --days=7          Failed commands this week
  $0 slow --limit=10          Top 10 slowest commands
  $0 timeline --days=1        Timeline of today's activity

EOF
}

# Get all log files for specified days
get_log_files() {
    local days=${1:-7}
    local logs=()

    for ((i=0; i<days; i++)); do
        local log_date
        log_date=$(date -d "$i days ago" +%Y%m%d 2>/dev/null || date -v-${i}d +%Y%m%d)
        local log_file="$LOG_DIR/commands-$log_date.log"
        if [[ -f "$log_file" ]]; then
            logs+=("$log_file")
        fi
    done

    echo "${logs[@]}"
}

# Show today's summary
show_today() {
    if [[ ! -f "$TODAY_LOG" ]]; then
        echo -e "${YELLOW}No commands logged yet today.${NC}"
        return
    fi

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Today's Command Summary ($(date +%Y-%m-%d))                   ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Total commands
    local total
    total=$(grep -c "=== COMMAND LOG ===" "$TODAY_LOG" 2>/dev/null || echo "0")
    echo -e "${GREEN}Total Commands:${NC} $total"
    echo ""

    # Success rate
    local success failed
    success=$(grep -c "Exit Code:   0" "$TODAY_LOG" 2>/dev/null || echo "0")
    failed=$((total - success))
    local success_rate
    if [[ $total -gt 0 ]]; then
        success_rate=$((success * 100 / total))
    else
        success_rate=0
    fi

    echo -e "${GREEN}Success Rate:${NC} $success_rate% ($success successful, $failed failed)"
    echo ""

    # Top directories
    echo -e "${CYAN}Top Directories:${NC}"
    grep "Directory:" "$TODAY_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5
    echo ""

    # Recent activity
    echo -e "${CYAN}Recent Commands (last 5):${NC}"
    grep -A 6 "=== COMMAND LOG ===" "$TODAY_LOG" 2>/dev/null | tail -35
}

# Show weekly summary
show_week() {
    local days=${1:-7}
    local log_files
    mapfile -t log_files < <(get_log_files "$days")

    if [[ ${#log_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found for the last $days days.${NC}"
        return
    fi

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Weekly Summary (Last $days Days)                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Total commands
    local total=0
    for log_file in "${log_files[@]}"; do
        local count
        count=$(grep -c "=== COMMAND LOG ===" "$log_file" 2>/dev/null || echo "0")
        total=$((total + count))
    done

    echo -e "${GREEN}Total Commands:${NC} $total (over $days days)"
    echo -e "${GREEN}Daily Average:${NC} $((total / days)) commands per day"
    echo ""

    # Commands per day
    echo -e "${CYAN}Daily Breakdown:${NC}"
    for log_file in "${log_files[@]}"; do
        local log_date
        log_date=$(basename "$log_file" | sed 's/commands-//;s/.log//')
        local count
        count=$(grep -c "=== COMMAND LOG ===" "$log_file" 2>/dev/null || echo "0")
        local formatted_date
        formatted_date=$(date -d "${log_date:0:4}-${log_date:4:2}-${log_date:6:2}" +%Y-%m-%d 2>/dev/null || echo "$log_date")
        echo "  $formatted_date: $count commands"
    done
    echo ""

    # Top commands
    echo -e "${CYAN}Top Commands This Week:${NC}"
    for log_file in "${log_files[@]}"; do
        grep "^Command:" "$log_file" 2>/dev/null
    done | sort | uniq -c | sort -rn | head -10
}

# Show failed commands
show_failed() {
    local days=${1:-7}
    local log_files
    mapfile -t log_files < <(get_log_files "$days")

    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Failed Commands (Last $days Days)                           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local found=0
    for log_file in "${log_files[@]}"; do
        while IFS= read -r line; do
            if [[ "$line" =~ Exit:\ ([0-9]+) ]]; then
                local exit_code="${BASH_REMATCH[1]}"
                if [[ "$exit_code" != "0" ]]; then
                    echo "$line"
                    ((found++))
                fi
            fi
        done < "$log_file"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "${GREEN}No failed commands found! 🎉${NC}"
    else
        echo ""
        echo -e "${RED}Found $found failed commands${NC}"
    fi
}

# Show slow commands
show_slow() {
    local days=${1:-7}
    local limit=${2:-10}
    local log_files
    mapfile -t log_files < <(get_log_files "$days")

    echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║  Slow Commands (>10s) - Last $days Days                    ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    {
        for log_file in "${log_files[@]}"; do
            grep -A 7 "=== COMMAND LOG ===" "$log_file" 2>/dev/null
        done
    } | awk '
        /^Duration:/ {
            duration = $NF
            gsub(/s/, "", duration)
            if (duration > 10) {
                getline; cmd = $0
                gsub(/^Command:     /, "", cmd)
                getline; getline; dir = $0
                gsub(/^Directory:   /, "", dir)
                printf "%5ss %s\n", duration, cmd
            }
        }
    ' | sort -rn | head -n "$limit"
}

# Timeline view
show_timeline() {
    local days=${1:-1}
    local log_files
    maptable -t log_files < <(get_log_files "$days")

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Command Timeline (Last $days Days)                          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    for log_file in "${log_files[@]}"; do
        local log_date
        log_date=$(basename "$log_file" | sed 's/commands-//;s/.log//')
        local formatted_date
        formatted_date=$(date -d "${log_date:0:4}-${log_date:4:2}-${log_date:6:2}" +%A 2>/dev/null || echo "$log_date")

        echo -e "${BLUE}$formatted_date${NC}"
        echo "────────────────────────────────────────────────────────────"

        grep -A 7 "=== COMMAND LOG ===" "$log_file" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                Timestamp:*)
                    local time
                    time=$(echo "$line" | awk '{print $2}')
                    echo -e "  ${GREEN}$time${NC}"
                    ;;
                Command:*)
                    local cmd
                    cmd=$(echo "$line" | cut -c 14-)
                    echo "    → $cmd"
                    ;;
            esac
        done
        echo ""
    done
}

# Clean old logs
clean_logs() {
    local days=${1:-30}

    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  Clean Old Logs                                         ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "This will delete logs older than $days days."
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return
    fi

    local deleted=0
    for log_file in "$LOG_DIR"/commands-*.log; do
        if [[ -f "$log_file" ]]; then
            local log_date
            log_date=$(basename "$log_file" | sed 's/commands-//;s/.log//')
            local file_age
            file_age=$(( ($(date +%s) - $(date -d "${log_date:0:4}-${log_date:4:2}-${log_date:6:2}" +%s 2>/dev/null || echo "0")) / 86400 ))

            if [[ $file_age -gt $days ]]; then
                rm "$log_file"
                ((deleted++))
                echo "Deleted: $log_file"
            fi
        fi
    done

    echo ""
    echo -e "${GREEN}Deleted $deleted old log files${NC}"
}

# Export logs
export_logs() {
    local format=${1:-text}
    local days=${2:-7}
    local output_file="/tmp/infras_commands_export.$(date +%Y%m%d).$format"

    case "$format" in
        csv)
            echo "Timestamp,Session,Directory,GitBranch,ExitCode,Duration,Command" > "$output_file"
            for log_file in $(get_log_files "$days"); do
                awk '
                    /^Timestamp:/   { timestamp = $2; getline }
                    /^Session:/     { session = $2; getline }
                    /^Directory:/   { directory = $2; getline }
                    /^Git Branch:/  { branch = $2; getline }
                    /^Exit Code:/   { exit_code = $2; getline }
                    /^Duration:/    { duration = $NF; getline }
                    /^Command:/     {
                        cmd = substr($0, 14)
                        gsub(/"/, "\"\"", cmd)
                        printf "%s,%s,%s,%s,%s,%s,\"%s\"\n", timestamp, session, directory, branch, exit_code, duration, cmd
                    }
                ' "$log_file" >> "$output_file"
            done
            ;;
        json)
            echo "[" > "$output_file"
            local first=true
            for log_file in $(get_log_files "$days"); do
                # Simple JSON export (consider using jq for production)
                grep -A 7 "=== COMMAND LOG ===" "$log_file" 2>/dev/null
            done | sed 's/$/ },/' | sed '$ s/ },//' >> "$output_file"
            echo "]" >> "$output_file"
            ;;
        *)
            # Text format (default)
            for log_file in $(get_log_files "$days"); do
                cat "$log_file"
            done > "$output_file"
            ;;
    esac

    echo -e "${GREEN}Exported to: $output_file${NC}"
}

# Main command dispatcher
case "${1:-}" in
    today)
        show_today
        ;;
    week)
        show_week "${2:-7}"
        ;;
    failed)
        show_failed "${2:-7}"
        ;;
    slow)
        show_slow "${2:-7}" "${3:-10}"
        ;;
    timeline)
        show_timeline "${2:-1}"
        ;;
    clean)
        clean_logs "${2:-30}"
        ;;
    export)
        export_logs "${2:-text}" "${3:-7}"
        ;;
    *)
        show_usage
        ;;
esac
