#!/bin/bash
# Command Analyzer - Single command with flags
# Usage: .command-analyzer.sh [flag] [options]

LOG_DIR="/home/hunghlh/app/infras/.command-logs"
TODAY=$(date +%Y%m%d)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    cat << EOF
╔════════════════════════════════════════════════════════════╗
║  Infras Command Analytics                                 ║
╚════════════════════════════════════════════════════════════╝

Usage: infras [flag] [options]

Flags:
  --stats, -s       Show today's statistics (default)
  --top, -t         Show most used commands
  --recent, -r      Show recent commands
  --search, -S      Search command history
  --failed, -f      Show failed commands
  --timeline        Timeline view of commands
  --raw             Show raw log entries

Options:
  --limit=N         Limit results (default: 20)
  --days=N          Number of days (default: 1)

Examples:
  infras                       Show help
  infras --stats               Today's statistics
  infras --top                 Most used commands
  infras --recent              Recent commands
  infras --search kubectl      Search for "kubectl"
  infras --failed --days=7     Failed commands this week

EOF
}

# Get log files for N days
get_logs() {
    local days=${1:-1}
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

# Show statistics
show_stats() {
    local days=${1:-1}
    local logs
    mapfile -t logs < <(get_logs "$days")

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Statistics (Last $days day(s))${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    local total=0 success=0
    for log_file in "${logs[@]}"; do
        local count
        count=$(grep -c "=== COMMAND LOG ===" "$log_file" 2>/dev/null || echo "0")
        total=$((total + count))
        local s
        s=$(grep -c "Exit Code:   0" "$log_file" 2>/dev/null || echo "0")
        success=$((success + s))
    done

    echo "Total Commands:    $total"
    echo "Successful:        $success"
    echo "Failed:            $((total - success))"

    if [[ $total -gt 0 ]]; then
        local rate=$((success * 100 / total))
        echo "Success Rate:       ${rate}%"
    fi

    echo ""
    echo -e "${CYAN}Top Directories:${NC}"
    for log_file in "${logs[@]}"; do
        grep "^Directory:" "$log_file" 2>/dev/null
    done | sort | uniq -c | sort -rn | head -5 | \
        awk '{printf "  %3d  %s\n", $1, $2}'
}

# Show top commands
show_top() {
    local limit=${1:-20}
    local logs
    mapfile -t logs < <(get_logs 1)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Most Used Commands${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    for log_file in "${logs[@]}"; do
        grep "^Command:" "$log_file" 2>/dev/null
    done | sort | uniq -c | sort -rn | head -n "$limit" | \
        awk '{printf "  %3d  %s\n", $1, substr($0, index($0,$2))}'
}

# Show recent commands
show_recent() {
    local limit=${1:-20}
    local logs
    mapfile -t logs < <(get_logs 1)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Recent Commands${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    local count=0
    local in_block=false
    local timestamp cmd exit_code

    for log_file in "${logs[@]}"; do
        while IFS= read -r line; do
            if [[ "$line" == "=== COMMAND LOG ===" ]]; then
                in_block=true
                continue
            fi

            if $in_block; then
                case "$line" in
                    "Timestamp:"*)
                        timestamp="${line#Timestamp:   }"
                        ;;
                    "Command:"*)
                        cmd="${line#Command:     }"
                        ;;
                    "Exit Code:"*)
                        exit_code="${line#Exit Code:   }"
                        local color=$GREEN
                        [[ "$exit_code" != "0" ]] && color=$RED
                        echo -e "${color}[$timestamp]${NC} $cmd"
                        ((count++))
                        in_block=false
                        [[ $count -ge $limit ]] && break 2
                        ;;
                esac
            fi
        done < "$log_file"
    done
}

# Search commands
search_commands() {
    local pattern="$1"
    local limit=${2:-20}

    if [[ -z "$pattern" ]]; then
        echo -e "${RED}Error: Search pattern required${NC}"
        return 1
    fi

    local logs
    mapfile -t logs < <(get_logs 1)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Search: \"$pattern\"${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    local count=0
    for log_file in "${logs[@]}"; do
        while IFS= read -r line; do
            if [[ "$line" == Command:*"$pattern"* ]]; then
                echo "  ${line#Command:     }"
                ((count++))
                [[ $count -ge $limit ]] && break 2
            fi
        done < "$log_file"
    done

    [[ $count -eq 0 ]] && echo -e "${YELLOW}No matches found${NC}"
}

# Show failed commands
show_failed() {
    local days=${1:-7}
    local logs
    mapfile -t logs < <(get_logs "$days")

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${RED}═══════════════════════════════════════════════════${NC}"
    echo -e "${RED}  Failed Commands (Last $days days)${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════${NC}"
    echo ""

    local count=0
    for log_file in "${logs[@]}"; do
        while IFS= read -r line; do
            if [[ "$line" =~ Exit:\ ([0-9]+) ]]; then
                local exit_code="${BASH_REMATCH[1]}"
                if [[ "$exit_code" != "0" ]]; then
                    echo "  Exit: $exit_code - $line"
                    ((count++))
                fi
            fi
        done < "$log_file"
    done

    [[ $count -eq 0 ]] && echo -e "${GREEN}No failed commands!${NC}"
}

# Timeline view
show_timeline() {
    local days=${1:-1}
    local logs
    mapfile -t logs < <(get_logs "$days")

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Timeline (Last $days day(s))${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    for log_file in "${logs[@]}"; do
        while IFS= read -r line; do
            case "$line" in
                "Timestamp:"*)
                    local time="${line#Timestamp:   }"
                    echo -e "${GREEN}[$time]${NC}"
                    ;;
                "Command:"*)
                    echo "  → ${line#Command:     }"
                    ;;
            esac
        done < "$log_file"
    done
}

# Show raw logs
show_raw() {
    local logs
    mapfile -t logs < <(get_logs 1)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No logs found${NC}"
        return
    fi

    for log_file in "${logs[@]}"; do
        cat "$log_file"
    done
}

# Parse arguments
FLAG=""
LIMIT=20
DAYS=1
PATTERN=""

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
        --failed|-f)
            FLAG="failed"
            shift
            ;;
        --timeline)
            FLAG="timeline"
            shift
            ;;
        --raw)
            FLAG="raw"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
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
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Default: show help
if [[ -z "$FLAG" ]]; then
    show_help
else
    case "$FLAG" in
        stats) show_stats "$DAYS" ;;
        top) show_top "$LIMIT" ;;
        recent) show_recent "$LIMIT" ;;
        search) search_commands "$PATTERN" "$LIMIT" ;;
        failed) show_failed "$DAYS" ;;
        timeline) show_timeline "$DAYS" ;;
        raw) show_raw ;;
    esac
fi
