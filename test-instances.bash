#!/bin/bash

set -e
BALANCER_URL="http://localhost:8080"
MAX_TEST_TEAMS=200
WAIT_BETWEEN_REQUESTS=2
INSTANCE_CHECK_INTERVAL=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        error "curl is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        warning "jq is not installed - JSON parsing will be limited"
    fi
    
    success "All prerequisites are available"
}

count_instances() {
    local running=$(kubectl get pods 2>/dev/null | grep juiceshop | grep Running | wc -l)
    local pending=$(kubectl get pods 2>/dev/null | grep juiceshop | grep -E "(Pending|ContainerCreating)" | wc -l)
    local total=$((running + pending))
    echo "$total"
}

get_max_instances() {
    if [ -f "values.yaml" ]; then
        local limit=$(grep "maxInstances:" values.yaml | grep -v "#" | awk '{print $2}' | head -1)
        if [ "$limit" = "-1" ]; then
            echo "unlimited"
        else
            echo "$limit"
        fi
    else
        echo "unknown"
    fi
}

test_balancer() {
    local status=$(curl -s -o /dev/null -w "%{http_code}" "$BALANCER_URL" 2>/dev/null || echo "000")
    
    if [ "$status" = "200" ] || [ "$status" = "302" ]; then
        return 0
    else
        return 1
    fi
}

join_team() {
    local team_name=$1
    
    local curl_output=$(mktemp)
    local http_status=$(curl -s -w "%{http_code}" -X POST "$BALANCER_URL/balancer/api/teams/$team_name/join" \
        -H 'Accept: */*' \
        -H 'Content-Type: application/json' \
        -H "Origin: $BALANCER_URL" \
        -H "Referer: $BALANCER_URL/balancer" \
        --data-raw '{}' \
        -o "$curl_output" \
        2>/dev/null || echo "000")
    
    local body=$(cat "$curl_output" 2>/dev/null || echo "")
    rm -f "$curl_output"
    
    if [ "$http_status" = "500" ]; then
        error "Team $team_name - HTTP 500: Instance limit hit"
        return 2
    elif [ "$http_status" = "401" ]; then
        warning "Team $team_name - HTTP 401: Unauthorized"
        return 1
    elif [ "$http_status" = "404" ]; then
        warning "Team $team_name - HTTP 404: Not found"
        return 1
    elif [ "$http_status" != "200" ] && [ "$http_status" != "201" ] && [ "$http_status" != "302" ]; then
        warning "Team $team_name - HTTP $http_status: $body"
        return 1
    fi
    
    if echo "$body" | grep -q "Created Instance\|passcode\|message"; then
        success "Team $team_name joined - Instance created (HTTP $http_status)"
        return 0
    elif echo "$body" | grep -q "error\|Error"; then
        warning "Team $team_name join failed: $body"
        return 1
    elif [ ! -z "$body" ]; then
        log "Team $team_name joined (HTTP $http_status): $body"
        return 0
    else
        log "Team $team_name joined successfully (HTTP $http_status)"
        return 0
    fi
}

run_instance_test() {
    local team_num=1
    local peak_instances=0
    local prev_count=0
    local steady_checks=0
    local teams_created=()
    
    log "Starting Juice Shop instance capacity test via curl requests"
    log "Will create teams until no new instances are started"
    
    if ! test_balancer; then
        error "Balancer is not accessible at $BALANCER_URL"
        exit 1
    fi
    
    success "Balancer is accessible, starting test..."
    
    local config_limit=$(get_max_instances)
    log "Configured max instances: $config_limit"
    
    local current_count=$(count_instances)
    log "Initial instances (running + pending): $current_count"
    
    local ts=$(date +%s)
    
    while [ $team_num -le $MAX_TEST_TEAMS ]; do
        local team_name="test${ts}${team_num}"
        
        log "Attempting to join team $team_num: $team_name"
        
        # Try to join the team directly (this will create it if it doesn't exist)
        join_team "$team_name"
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            teams_created+=("$team_name")
        elif [ $exit_code -eq 2 ]; then
            error "HTTP 500 - instance limit hit"
            peak_instances=$(count_instances)
            log "Stopping due to HTTP 500"
            break
        else
            warning "Failed to join team $team_name (exit code: $exit_code)"
        fi
        
        # Wait between requests
        sleep $WAIT_BETWEEN_REQUESTS
        
        if [ $((team_num % 5)) -eq 0 ]; then
            log "Checking instance count after $team_num teams..."
            sleep $INSTANCE_CHECK_INTERVAL
            
            local total=$(count_instances)
            local running=$(kubectl get pods 2>/dev/null | grep juiceshop | grep Running | wc -l)
            local pending=$(kubectl get pods 2>/dev/null | grep juiceshop | grep -E "(Pending|ContainerCreating)" | wc -l)
            
            log "Current instances: $total total ($running running, $pending pending)"
            
            if [ "$config_limit" != "unlimited" ] && [ "$config_limit" != "unknown" ]; then
                if [ "$total" -ge "$config_limit" ] 2>/dev/null; then
                    log "Hit configured limit of $config_limit instances"
                    peak_instances=$total
                    break
                fi
            fi
            
            if [ "$total" -eq "$prev_count" ] 2>/dev/null; then
                steady_checks=$((steady_checks + 1))
                if [ "$steady_checks" -ge "3" ]; then
                    log "Instance count stable at $total for 3 checks"
                    peak_instances=$total
                    break
                fi
            else
                steady_checks=0
                peak_instances=$total
            fi
            
            prev_count=$total
            
            local mem=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
            local cpu=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d',' -f1 | xargs)
            log "System: Memory ${mem}%, CPU load $cpu"
        fi
        
        team_num=$((team_num + 1))
    done
    
    log "==============================================="
    success "Test completed"
    success "Peak instances: $peak_instances"
    success "Teams created: $((team_num - 1))"
    success "Config limit: $config_limit"
    
    local final_running=$(kubectl get pods 2>/dev/null | grep juiceshop | grep Running | wc -l)
    local final_pending=$(kubectl get pods 2>/dev/null | grep juiceshop | grep -E "(Pending|ContainerCreating)" | wc -l)
    local final_total=$((final_running + final_pending))
    
    log "Final: $final_total total ($final_running running, $final_pending pending)"
    
    if [ "$exit_code" -eq "2" ] 2>/dev/null; then
        warning "Stopped due to HTTP 500 (instance limit hit)"
    elif [ "$peak_instances" -ge "$config_limit" ] 2>/dev/null && [ "$config_limit" != "unlimited" ]; then
        log "Stopped due to config limit"
    else
        log "Stopped due to stable count"
    fi
    
    log "==============================================="
    
    log "Pod overview:"
    kubectl get pods 2>/dev/null | grep juiceshop | head -10 || log "No pods found"
}

cleanup() {
    log "Cleanup..."
    log "Teams auto-cleaned by multi-juicer"
}

trap cleanup EXIT

main() {
    log "Juice Shop Instance Capacity Test"
    log "=================================="
    
    check_prerequisites
    
    # Confirm before starting
    echo
    warning "This test will create multiple teams via curl requests to test instance limits"
    read -p "Do you want to continue? (y/N): " confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log "Test cancelled by user"
        exit 0
    fi
    
    run_instance_test
}

main "$@"