#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_FILE="${PORT_FILE:-$BASE_DIR/ports.conf}"
RUN_DIR="$HOME/.forward-ports"
PID_DIR="$RUN_DIR/pids"
LOG_DIR="$RUN_DIR/logs"

mkdir -p "$PID_DIR" "$LOG_DIR"

usage() {
  echo "Usage: $0 {start|stop|status|restart|list}"
  exit 1
}

# Improved parsing for Bash 3.2
parse_config() {
  local section=""
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/#.*//' | xargs)"
    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^\[(.*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    case "$section" in
      ssh)
        # Format: mapping target
        local mapping=$(echo "$line" | awk '{print $1}')
        local target=$(echo "$line" | awk '{print $2}')
        # Store in unique target lists
        local var_name="ssh_mappings_$(echo "$target" | sed 's/[^a-zA-Z0-9_]/_/g')"
        eval "current=\${$var_name:-}"
        eval "$var_name=\"\$current $mapping\""
        if [[ ! " $ssh_targets " == *" $target "* ]]; then
          ssh_targets="$ssh_targets $target"
        fi
        ;;
      kubectl)
        # Format: namespace resource mapping
        kube_forwards[${#kube_forwards[@]}]="$line"
        ;;
    esac
  done < "$PORT_FILE"
}

ssh_targets=""
kube_forwards=()

start() {
  echo "Starting port forwards from $PORT_FILE..."
  parse_config

  # Start SSH
  local ssh_ports=""
  for target in $ssh_targets; do
    local var_name="ssh_mappings_$(echo "$target" | sed 's/[^a-zA-Z0-9_]/_/g')"
    eval "mappings=\$$var_name"
    local pid_file="$PID_DIR/ssh_$(echo "$target" | sed 's/[^a-zA-Z0-9_]/_/g').pid"
    local log_file="$LOG_DIR/ssh_$(echo "$target" | sed 's/[^a-zA-Z0-9_]/_/g').log"
    
    # Extract local ports for waiting
    for mapping in $mappings; do
      local port=$(echo "$mapping" | cut -d: -f1)
      ssh_ports="$ssh_ports $port"
    done

    if [[ -f "$pid_file" ]] && kill -0 $(cat "$pid_file") 2>/dev/null; then
      echo "SSH forward to $target already running (PID: $(cat "$pid_file"))"
    else
      nohup "$BASE_DIR/forward-ssh.sh" "$mappings" "$target" > "$log_file" 2>&1 &
      echo $! > "$pid_file"
      echo "Started SSH forward to $target (PID: $!)"
    fi
  done

  # Wait for SSH ports to be active
  if [[ -n "$ssh_ports" ]]; then
    echo "Waiting for SSH ports to be active: $ssh_ports..."
    for port in $ssh_ports; do
      local count=0
      while ! nc -z localhost "$port" 2>/dev/null; do
        sleep 0.5
        count=$((count + 1))
        if [ $count -gt 20 ]; then
          echo "Warning: Timeout waiting for port $port"
          break
        fi
      done
    done
  fi

  # Start Kubectl
  # Loop over kube_forwards with Bash 3.2 safety
  local i=0
  while [ $i -lt ${#kube_forwards[@]} ]; do
    local line="${kube_forwards[$i]}"
    local ns=$(echo "$line" | awk '{print $1}')
    local res=$(echo "$line" | awk '{print $2}')
    local map=$(echo "$line" | awk '{print $3}')
    local name="kube_${ns}_${res//\//_}"
    local pid_file="$PID_DIR/$name.pid"
    local log_file="$LOG_DIR/$name.log"

    if [[ -f "$pid_file" ]] && kill -0 $(cat "$pid_file") 2>/dev/null; then
      echo "Kubectl forward $ns/$res already running (PID: $(cat "$pid_file"))"
    else
      nohup "$BASE_DIR/forward-kubectl.sh" "$ns" "$res" "$map" > "$log_file" 2>&1 &
      echo $! > "$pid_file"
      echo "Started Kubectl forward $ns/$res (PID: $!)"
    fi
    i=$((i+1))
  done
}

stop() {
  echo "Stopping all port forwards..."
  for pid_file in "$PID_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Killing process $pid ($(basename "$pid_file" .pid))"
      kill "$pid" 2>/dev/null || true
    fi
    rm "$pid_file"
  done
}

status() {
  echo "Checking status of port forwards..."
  local running=0
  for pid_file in "$PID_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local pid=$(cat "$pid_file")
    local name=$(basename "$pid_file" .pid)
    if kill -0 "$pid" 2>/dev/null; then
      echo "[RUNNING] $name (PID: $pid)"
      running=$((running + 1))
    else
      echo "[STOPPED] $name (PID: $pid - file exists but process dead)"
      rm "$pid_file"
    fi
  done
  
  if [[ $running -eq 0 ]]; then
    echo "No active forwards."
  fi
}

list() {
  echo "Current configuration in $PORT_FILE:"
  cat "$PORT_FILE"
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  status)  status ;;
  restart) stop; sleep 1; start ;;
  list)    list ;;
  *)       usage ;;
esac
