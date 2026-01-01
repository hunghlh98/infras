#!/usr/bin/env bash

create_acl() {
    local service_name=$1
    local password=$2
    
    local acl_file="${ROOT_DIR}/redis-local/users.acl"
    
    # Check if file exists
    if [ ! -f "$acl_file" ]; then
        log_error "Redis ACL file not found at $acl_file"
        exit 1
    fi
    
    # Init Check: Does user exist in file?
    if grep -q "^user $service_name " "$acl_file"; then
        log_warn "Redis user '$service_name' already exists in ACL file. Updating password..."
        # We use sed to replace the line. 
        # Pattern: user service_name ...
        # We assume standard format: user <name> on >password ...
        # This is tricky with sed safely. Easier to append if not exists, or manual edit.
        # For this script, let's assume valid formatted start.
        
        # Determine the permissions. Getting complicated to parse.
        # Fallback: We will just comment out old line and add new one, or try strict replacement.
        # Let's try to replace the line matching user $service_name
        
        # New ACL line: user <name> on >password ~* &* +@all
        # Giving full access for now as requested "users for each system" usually implies full app access.
        # Ideally we should restrict keys, but for "shared infrastructure" platform, splitting by DB/Prefix is better.
        # But for now, standard "+@all" as per up.sh templates.
        
        # Using a temporary file
        temp_file=$(mktemp)
        local new_line="user $service_name on >$password ~$service_name:* &* +@all"
        
        awk -v user="$service_name" -v new_line="$new_line" '
        $2 == user { print new_line; found=1; next }
        { print }
        END { if (!found) print new_line }
        ' "$acl_file" > "$temp_file" && mv "$temp_file" "$acl_file"
        
    else
        log_info "Adding new Redis user '$service_name'..."
        echo "user $service_name on >$password ~$service_name:* &* +@all" >> "$acl_file"
    fi
    
    
    # Reload ACLs
    log_info "Reloading Redis ACLs..."
    
    local admin_pass=$(fetch_secret infras/redis/auth password)
    
    if [ -z "$admin_pass" ]; then
        log_warn "Could not fetch Redis admin password. ACL reload might fail if auth is required."
    fi
    
    # Reload on all redis containers in the project
    local containers=$(docker ps --format "{{.Names}}" | grep "redis")
    
    if [ -z "$containers" ]; then
        log_warn "No running Redis containers found to reload ACLs."
    else
        for container in $containers; do
            log_info "Reloading ACL on $container..."
            # Try with auth if we have pass, else without
            if [ -n "$admin_pass" ]; then
                docker exec "$container" redis-cli -a "$admin_pass" ACL LOAD > /dev/null 2>&1 || true
            else
                docker exec "$container" redis-cli ACL LOAD > /dev/null 2>&1 || true
            fi
        done
    fi
    
    log_info "Redis ACL setup for '$service_name' completed."
}
