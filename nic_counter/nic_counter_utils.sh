#!/bin/bash

# NIC Counter Utilities
# Shared functions for collecting and reporting NIC counters across test scripts
#
# Usage: Source this file in your test script:
#   source "$(dirname "$0")/nic_counter_utils.sh"
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed
#
# Required variables to set before calling functions:
#   POD_NAME_WIDTH - Width for pod name column in printf (default: 25)
#
# Workflow:
#   1. Set NET_DEBUG_NS environment variable
#   2. Source this file
#   3. Create your pods array (e.g., deepep_pods)
#   4. Call: init_nic_counter_utils <pods_array_name> <pods_namespace>
#   5. Call: collect_all_counters <pods_array_name> "before"
#   6. Run your test
#   7. Call: collect_all_counters <pods_array_name> "after"
#   8. Call print functions with <pods_array_name>

# ============================================
# Configuration
# ============================================
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-2}
POD_NAME_WIDTH=25  # Will be auto-calculated during init
NICS_PER_POD=9     # rdma0-rdma7 (8) + eth0 (1)

# ============================================
# Helper function to get NIC name from index
# Arguments: $1=nic_idx (0-8)
# Returns: NIC name (rdma0-rdma7 or eth0)
# ============================================
get_nic_name() {
    local nic_idx=$1
    if [ $nic_idx -lt 8 ]; then
        echo "rdma${nic_idx}"
    else
        echo "eth0"
    fi
}

# ============================================
# Helper function to format bytes in human-readable form
# Arguments: $1=bytes (can be negative for diffs)
# Returns: Formatted string (e.g., "1.23 GB", "456.78 MB")
# ============================================
format_bytes() {
    local bytes=$1
    local sign=""
    
    # Handle negative values
    if [ "$bytes" -lt 0 ] 2>/dev/null; then
        sign="-"
        bytes=$((-bytes))
    fi
    
    # Handle zero or empty
    if [ -z "$bytes" ] || [ "$bytes" == "0" ]; then
        echo "0 B"
        return
    fi
    
    if [ "$bytes" -ge 1000000000000 ]; then
        # TB
        local tb=$((bytes / 1000000000000))
        local remainder=$((bytes % 1000000000000))
        local decimal=$((remainder * 100 / 1000000000000))
        printf "%s%d.%02d TB" "$sign" "$tb" "$decimal"
    elif [ "$bytes" -ge 1000000000 ]; then
        # GB
        local gb=$((bytes / 1000000000))
        local remainder=$((bytes % 1000000000))
        local decimal=$((remainder * 100 / 1000000000))
        printf "%s%d.%02d GB" "$sign" "$gb" "$decimal"
    elif [ "$bytes" -ge 1000000 ]; then
        # MB
        local mb=$((bytes / 1000000))
        local remainder=$((bytes % 1000000))
        local decimal=$((remainder * 100 / 1000000))
        printf "%s%d.%02d MB" "$sign" "$mb" "$decimal"
    elif [ "$bytes" -ge 1000 ]; then
        # KB
        local kb=$((bytes / 1000))
        local remainder=$((bytes % 1000))
        local decimal=$((remainder * 100 / 1000))
        printf "%s%d.%02d KB" "$sign" "$kb" "$decimal"
    else
        # Bytes
        printf "%s%d B" "$sign" "$bytes"
    fi
}

# ============================================
# Internal arrays (populated by init function)
# ============================================
declare -a _node_names
declare -a _networking_debug_pods

# ============================================
# Arrays for RX priority packet counters
# ============================================
declare -a before_rx_prio0_packets
declare -a before_rx_prio1_packets
declare -a before_rx_prio5_packets
declare -a before_rx_packets_phy

declare -a after_rx_prio0_packets
declare -a after_rx_prio1_packets
declare -a after_rx_prio5_packets
declare -a after_rx_packets_phy

# ============================================
# Arrays for TX priority packet counters
# ============================================
declare -a before_tx_prio0_packets
declare -a before_tx_prio1_packets
declare -a before_tx_prio5_packets
declare -a before_tx_packets_phy

declare -a after_tx_prio0_packets
declare -a after_tx_prio1_packets
declare -a after_tx_prio5_packets
declare -a after_tx_packets_phy

# ============================================
# Arrays for RX priority discard counters
# ============================================
declare -a before_rx_prio0_buf_discard
declare -a before_rx_prio1_buf_discard
declare -a before_rx_prio5_buf_discard

declare -a after_rx_prio0_buf_discard
declare -a after_rx_prio1_buf_discard
declare -a after_rx_prio5_buf_discard

# ============================================
# Arrays for RX priority byte counters
# ============================================
declare -a before_rx_prio0_bytes
declare -a before_rx_prio1_bytes
declare -a before_rx_prio5_bytes

declare -a after_rx_prio0_bytes
declare -a after_rx_prio1_bytes
declare -a after_rx_prio5_bytes

# ============================================
# Arrays for TX priority byte counters
# ============================================
declare -a before_tx_prio0_bytes
declare -a before_tx_prio1_bytes
declare -a before_tx_prio5_bytes

declare -a after_tx_prio0_bytes
declare -a after_tx_prio1_bytes
declare -a after_tx_prio5_bytes

# ============================================
# Arrays for PFC pause counters (prio0 and prio5)
# ============================================
declare -a before_tx_prio0_pause
declare -a before_rx_prio0_pause
declare -a before_tx_prio5_pause
declare -a before_rx_prio5_pause
declare -a before_tx_prio0_pause_duration
declare -a before_rx_prio0_pause_duration
declare -a before_tx_prio5_pause_duration
declare -a before_rx_prio5_pause_duration

declare -a after_tx_prio0_pause
declare -a after_rx_prio0_pause
declare -a after_tx_prio5_pause
declare -a after_rx_prio5_pause
declare -a after_tx_prio0_pause_duration
declare -a after_rx_prio0_pause_duration
declare -a after_tx_prio5_pause_duration
declare -a after_rx_prio5_pause_duration

# ============================================
# Arrays for ECN counters (per NIC: pod_idx * NICS_PER_POD + nic_idx)
# Note: ECN counters come from mlx5 InfiniBand devices - each NIC (rdma0-7, eth0)
# may have an associated mlx5 device with ECN hw_counters
# ============================================
declare -a before_ecn_marked
declare -a before_cnp_sent
declare -a before_cnp_handled

declare -a after_ecn_marked
declare -a after_cnp_sent
declare -a after_cnp_handled

# ============================================
# Initialization function
# Arguments: $1=pod_names_array_ref, $2=pods_namespace
# Discovers nodes and builds networking-debug-pods array
# Auto-calculates POD_NAME_WIDTH based on longest pod name
# ============================================
init_nic_counter_utils() {
    local -n pods_ref=$1
    local pods_namespace=$2
    
    # Validate NET_DEBUG_NS is set
    if [ -z "$NET_DEBUG_NS" ]; then
        echo "ERROR: NET_DEBUG_NS environment variable is not set."
        echo "Please set it to the namespace where networking-debug-pods are deployed."
        echo "Example: export NET_DEBUG_NS=kube-system"
        return 1
    fi
    
    echo ""
    echo "=============================================="
    echo "Initializing NIC Counter Utils"
    echo "=============================================="
    echo "Pods namespace: $pods_namespace"
    echo "Networking debug pods namespace: $NET_DEBUG_NS"
    echo ""
    
    # Clear internal arrays
    _node_names=()
    _networking_debug_pods=()
    
    # Discover nodes for each pod and calculate max pod name width
    echo "Discovering nodes for pods..."
    local max_width=10  # Minimum width
    for pod in "${pods_ref[@]}"; do
        local node_name=$(kubectl get pod -n "$pods_namespace" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        
        if [ -z "$node_name" ]; then
            echo "  [ERROR] Could not find node for pod: $pod"
            return 1
        fi
        
        _node_names+=("$node_name")
        _networking_debug_pods+=("networking-debug-pod-$node_name")
        echo "  $pod -> $node_name -> networking-debug-pod-$node_name"
        
        # Track max width
        local pod_len=${#pod}
        [ $pod_len -gt $max_width ] && max_width=$pod_len
    done
    
    # Set POD_NAME_WIDTH with some padding
    POD_NAME_WIDTH=$((max_width + 2))
    
    # Verify networking-debug-pods exist
    echo ""
    echo "Verifying networking-debug-pods in namespace $NET_DEBUG_NS..."
    for debug_pod in "${_networking_debug_pods[@]}"; do
        if ! kubectl get pod -n "$NET_DEBUG_NS" "$debug_pod" &>/dev/null; then
            echo "  [ERROR] Networking debug pod not found: $debug_pod in namespace $NET_DEBUG_NS"
            return 1
        fi
        echo "  Found: $debug_pod"
    done
    
    echo ""
    echo "Pod name column width: $POD_NAME_WIDTH"
    echo "Initialization complete."
    return 0
}

# ============================================
# Get node name for a pod index
# Arguments: $1=pod_idx
# ============================================
get_node_name() {
    local pod_idx=$1
    echo "${_node_names[$pod_idx]}"
}

# ============================================
# Function to fetch ethtool stats with retry logic
# Arguments: $1=networking_debug_pod, $2=nic
# ============================================
_fetch_ethtool_stats() {
    local pod=$1
    local nic=$2
    local retry=0
    local stats=""
    
    while [ $retry -lt $MAX_RETRIES ]; do
        stats=$(kubectl exec -n "$NET_DEBUG_NS" "$pod" -- ethtool -S "$nic" 2>/dev/null)
        
        if echo "$stats" | grep -q "rx_prio0_packets:"; then
            echo "$stats"
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $MAX_RETRIES ]; then
            echo "  [WARN] Failed to get stats for $nic on $pod, retrying ($retry/$MAX_RETRIES)..." >&2
            sleep $RETRY_DELAY
        fi
    done
    
    echo "  [ERROR] Failed to get stats for $nic on $pod after $MAX_RETRIES attempts" >&2
    echo ""
    return 1
}

# ============================================
# Internal function to collect NIC counters for a single pod
# Arguments: $1=networking_debug_pod, $2=pod_idx, $3=prefix (before|after)
# ============================================
_collect_nic_counters_for_pod() {
    local debug_pod=$1
    local pod_idx=$2
    local prefix=$3
    
    for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
        local array_idx=$((pod_idx * NICS_PER_POD + nic_idx))
        local nic_name=$(get_nic_name $nic_idx)
        local stats=$(_fetch_ethtool_stats "$debug_pod" "$nic_name")
        
        if [ -z "$stats" ]; then
            echo "  [ERROR] No stats retrieved for $nic_name on $debug_pod - using -1 marker"
            if [ "$prefix" == "before" ]; then
                # RX packets
                before_rx_prio0_packets[$array_idx]=-1
                before_rx_prio1_packets[$array_idx]=-1
                before_rx_prio5_packets[$array_idx]=-1
                before_rx_packets_phy[$array_idx]=-1
                # TX packets
                before_tx_prio0_packets[$array_idx]=-1
                before_tx_prio1_packets[$array_idx]=-1
                before_tx_prio5_packets[$array_idx]=-1
                before_tx_packets_phy[$array_idx]=-1
                # RX discards
                before_rx_prio0_buf_discard[$array_idx]=-1
                before_rx_prio1_buf_discard[$array_idx]=-1
                before_rx_prio5_buf_discard[$array_idx]=-1
                # RX bytes
                before_rx_prio0_bytes[$array_idx]=-1
                before_rx_prio1_bytes[$array_idx]=-1
                before_rx_prio5_bytes[$array_idx]=-1
                # TX bytes
                before_tx_prio0_bytes[$array_idx]=-1
                before_tx_prio1_bytes[$array_idx]=-1
                before_tx_prio5_bytes[$array_idx]=-1
                # PFC pause
                before_tx_prio0_pause[$array_idx]=-1
                before_rx_prio0_pause[$array_idx]=-1
                before_tx_prio5_pause[$array_idx]=-1
                before_rx_prio5_pause[$array_idx]=-1
                before_tx_prio0_pause_duration[$array_idx]=-1
                before_rx_prio0_pause_duration[$array_idx]=-1
                before_tx_prio5_pause_duration[$array_idx]=-1
                before_rx_prio5_pause_duration[$array_idx]=-1
            else
                # RX packets
                after_rx_prio0_packets[$array_idx]=-1
                after_rx_prio1_packets[$array_idx]=-1
                after_rx_prio5_packets[$array_idx]=-1
                after_rx_packets_phy[$array_idx]=-1
                # TX packets
                after_tx_prio0_packets[$array_idx]=-1
                after_tx_prio1_packets[$array_idx]=-1
                after_tx_prio5_packets[$array_idx]=-1
                after_tx_packets_phy[$array_idx]=-1
                # RX discards
                after_rx_prio0_buf_discard[$array_idx]=-1
                after_rx_prio1_buf_discard[$array_idx]=-1
                after_rx_prio5_buf_discard[$array_idx]=-1
                # RX bytes
                after_rx_prio0_bytes[$array_idx]=-1
                after_rx_prio1_bytes[$array_idx]=-1
                after_rx_prio5_bytes[$array_idx]=-1
                # TX bytes
                after_tx_prio0_bytes[$array_idx]=-1
                after_tx_prio1_bytes[$array_idx]=-1
                after_tx_prio5_bytes[$array_idx]=-1
                # PFC pause
                after_tx_prio0_pause[$array_idx]=-1
                after_rx_prio0_pause[$array_idx]=-1
                after_tx_prio5_pause[$array_idx]=-1
                after_rx_prio5_pause[$array_idx]=-1
                after_tx_prio0_pause_duration[$array_idx]=-1
                after_rx_prio0_pause_duration[$array_idx]=-1
                after_tx_prio5_pause_duration[$array_idx]=-1
                after_rx_prio5_pause_duration[$array_idx]=-1
            fi
            continue
        fi
        
        # Parse RX priority packet counters
        local rx_prio0_packets=$(echo "$stats" | grep -E "^\s*rx_prio0_packets:" | awk '{print $2}')
        local rx_prio1_packets=$(echo "$stats" | grep -E "^\s*rx_prio1_packets:" | awk '{print $2}')
        local rx_prio5_packets=$(echo "$stats" | grep -E "^\s*rx_prio5_packets:" | awk '{print $2}')
        local rx_packets_phy=$(echo "$stats" | grep -E "^\s*rx_packets_phy:" | awk '{print $2}')
        
        # Parse TX priority packet counters
        local tx_prio0_packets=$(echo "$stats" | grep -E "^\s*tx_prio0_packets:" | awk '{print $2}')
        local tx_prio1_packets=$(echo "$stats" | grep -E "^\s*tx_prio1_packets:" | awk '{print $2}')
        local tx_prio5_packets=$(echo "$stats" | grep -E "^\s*tx_prio5_packets:" | awk '{print $2}')
        local tx_packets_phy=$(echo "$stats" | grep -E "^\s*tx_packets_phy:" | awk '{print $2}')
        
        # Parse RX priority discard counters
        local rx_prio0_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio0_buf_discard:" | awk '{print $2}')
        local rx_prio1_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio1_buf_discard:" | awk '{print $2}')
        local rx_prio5_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio5_buf_discard:" | awk '{print $2}')
        
        # Parse RX priority byte counters
        local rx_prio0_bytes=$(echo "$stats" | grep -E "^\s*rx_prio0_bytes:" | awk '{print $2}')
        local rx_prio1_bytes=$(echo "$stats" | grep -E "^\s*rx_prio1_bytes:" | awk '{print $2}')
        local rx_prio5_bytes=$(echo "$stats" | grep -E "^\s*rx_prio5_bytes:" | awk '{print $2}')
        
        # Parse TX priority byte counters
        local tx_prio0_bytes=$(echo "$stats" | grep -E "^\s*tx_prio0_bytes:" | awk '{print $2}')
        local tx_prio1_bytes=$(echo "$stats" | grep -E "^\s*tx_prio1_bytes:" | awk '{print $2}')
        local tx_prio5_bytes=$(echo "$stats" | grep -E "^\s*tx_prio5_bytes:" | awk '{print $2}')
        
        # Parse PFC pause counters
        local tx_prio0_pause=$(echo "$stats" | grep -E "^\s*tx_prio0_pause:" | awk '{print $2}')
        local rx_prio0_pause=$(echo "$stats" | grep -E "^\s*rx_prio0_pause:" | awk '{print $2}')
        local tx_prio5_pause=$(echo "$stats" | grep -E "^\s*tx_prio5_pause:" | awk '{print $2}')
        local rx_prio5_pause=$(echo "$stats" | grep -E "^\s*rx_prio5_pause:" | awk '{print $2}')
        
        # Parse PFC pause duration counters
        local tx_prio0_pause_duration=$(echo "$stats" | grep -E "^\s*tx_prio0_pause_duration:" | awk '{print $2}')
        local rx_prio0_pause_duration=$(echo "$stats" | grep -E "^\s*rx_prio0_pause_duration:" | awk '{print $2}')
        local tx_prio5_pause_duration=$(echo "$stats" | grep -E "^\s*tx_prio5_pause_duration:" | awk '{print $2}')
        local rx_prio5_pause_duration=$(echo "$stats" | grep -E "^\s*rx_prio5_pause_duration:" | awk '{print $2}')
        
        if [ "$prefix" == "before" ]; then
            # RX packets
            before_rx_prio0_packets[$array_idx]=${rx_prio0_packets:-0}
            before_rx_prio1_packets[$array_idx]=${rx_prio1_packets:-0}
            before_rx_prio5_packets[$array_idx]=${rx_prio5_packets:-0}
            before_rx_packets_phy[$array_idx]=${rx_packets_phy:-0}
            # TX packets
            before_tx_prio0_packets[$array_idx]=${tx_prio0_packets:-0}
            before_tx_prio1_packets[$array_idx]=${tx_prio1_packets:-0}
            before_tx_prio5_packets[$array_idx]=${tx_prio5_packets:-0}
            before_tx_packets_phy[$array_idx]=${tx_packets_phy:-0}
            # RX discards
            before_rx_prio0_buf_discard[$array_idx]=${rx_prio0_buf_discard:-0}
            before_rx_prio1_buf_discard[$array_idx]=${rx_prio1_buf_discard:-0}
            before_rx_prio5_buf_discard[$array_idx]=${rx_prio5_buf_discard:-0}
            # RX bytes
            before_rx_prio0_bytes[$array_idx]=${rx_prio0_bytes:-0}
            before_rx_prio1_bytes[$array_idx]=${rx_prio1_bytes:-0}
            before_rx_prio5_bytes[$array_idx]=${rx_prio5_bytes:-0}
            # TX bytes
            before_tx_prio0_bytes[$array_idx]=${tx_prio0_bytes:-0}
            before_tx_prio1_bytes[$array_idx]=${tx_prio1_bytes:-0}
            before_tx_prio5_bytes[$array_idx]=${tx_prio5_bytes:-0}
            # PFC pause
            before_tx_prio0_pause[$array_idx]=${tx_prio0_pause:-0}
            before_rx_prio0_pause[$array_idx]=${rx_prio0_pause:-0}
            before_tx_prio5_pause[$array_idx]=${tx_prio5_pause:-0}
            before_rx_prio5_pause[$array_idx]=${rx_prio5_pause:-0}
            before_tx_prio0_pause_duration[$array_idx]=${tx_prio0_pause_duration:-0}
            before_rx_prio0_pause_duration[$array_idx]=${rx_prio0_pause_duration:-0}
            before_tx_prio5_pause_duration[$array_idx]=${tx_prio5_pause_duration:-0}
            before_rx_prio5_pause_duration[$array_idx]=${rx_prio5_pause_duration:-0}
        else
            # RX packets
            after_rx_prio0_packets[$array_idx]=${rx_prio0_packets:-0}
            after_rx_prio1_packets[$array_idx]=${rx_prio1_packets:-0}
            after_rx_prio5_packets[$array_idx]=${rx_prio5_packets:-0}
            after_rx_packets_phy[$array_idx]=${rx_packets_phy:-0}
            # TX packets
            after_tx_prio0_packets[$array_idx]=${tx_prio0_packets:-0}
            after_tx_prio1_packets[$array_idx]=${tx_prio1_packets:-0}
            after_tx_prio5_packets[$array_idx]=${tx_prio5_packets:-0}
            after_tx_packets_phy[$array_idx]=${tx_packets_phy:-0}
            # RX discards
            after_rx_prio0_buf_discard[$array_idx]=${rx_prio0_buf_discard:-0}
            after_rx_prio1_buf_discard[$array_idx]=${rx_prio1_buf_discard:-0}
            after_rx_prio5_buf_discard[$array_idx]=${rx_prio5_buf_discard:-0}
            # RX bytes
            after_rx_prio0_bytes[$array_idx]=${rx_prio0_bytes:-0}
            after_rx_prio1_bytes[$array_idx]=${rx_prio1_bytes:-0}
            after_rx_prio5_bytes[$array_idx]=${rx_prio5_bytes:-0}
            # TX bytes
            after_tx_prio0_bytes[$array_idx]=${tx_prio0_bytes:-0}
            after_tx_prio1_bytes[$array_idx]=${tx_prio1_bytes:-0}
            after_tx_prio5_bytes[$array_idx]=${tx_prio5_bytes:-0}
            # PFC pause
            after_tx_prio0_pause[$array_idx]=${tx_prio0_pause:-0}
            after_rx_prio0_pause[$array_idx]=${rx_prio0_pause:-0}
            after_tx_prio5_pause[$array_idx]=${tx_prio5_pause:-0}
            after_rx_prio5_pause[$array_idx]=${rx_prio5_pause:-0}
            after_tx_prio0_pause_duration[$array_idx]=${tx_prio0_pause_duration:-0}
            after_rx_prio0_pause_duration[$array_idx]=${rx_prio0_pause_duration:-0}
            after_tx_prio5_pause_duration[$array_idx]=${tx_prio5_pause_duration:-0}
            after_rx_prio5_pause_duration[$array_idx]=${rx_prio5_pause_duration:-0}
        fi
    done
}

# ============================================
# Internal function to collect ECN counters for a single pod
# Arguments: $1=networking_debug_pod, $2=pod_idx, $3=prefix (before|after)
# ECN counters come from mlx5 InfiniBand devices - we discover which mlx5 device
# corresponds to each NIC by checking /sys/class/net/<nic>/device/infiniband/
# ============================================
_collect_ecn_counters_for_pod() {
    local debug_pod=$1
    local pod_idx=$2
    local prefix=$3
    
    # Collect ECN counters for each NIC by discovering its mlx5 device
    # Output format: nic_idx ecn cnp_sent cnp_handled
    local ecn_data=$(kubectl exec -n "$NET_DEBUG_NS" "$debug_pod" -- bash -c '
        # Function to get ECN counters for a NIC
        get_ecn_for_nic() {
            local nic=$1
            local nic_idx=$2
            
            # Find the mlx5 device for this NIC
            local ib_path="/sys/class/net/$nic/device/infiniband"
            if [ -d "$ib_path" ]; then
                local mlx5_dev=$(ls "$ib_path" 2>/dev/null | head -1)
                if [ -n "$mlx5_dev" ] && [ -d "/sys/class/infiniband/$mlx5_dev/ports/1/hw_counters" ]; then
                    local ecn=$(cat "/sys/class/infiniband/$mlx5_dev/ports/1/hw_counters/np_ecn_marked_roce_packets" 2>/dev/null || echo 0)
                    local cnp_sent=$(cat "/sys/class/infiniband/$mlx5_dev/ports/1/hw_counters/np_cnp_sent" 2>/dev/null || echo 0)
                    local cnp_handled=$(cat "/sys/class/infiniband/$mlx5_dev/ports/1/hw_counters/rp_cnp_handled" 2>/dev/null || echo 0)
                    echo "$nic_idx $ecn $cnp_sent $cnp_handled"
                    return
                fi
            fi
            # No mlx5 device found for this NIC
            echo "$nic_idx 0 0 0"
        }
        
        # Get ECN counters for rdma0-rdma7 (indices 0-7)
        for i in $(seq 0 7); do
            get_ecn_for_nic "rdma$i" "$i"
        done
        
        # Get ECN counters for eth0 (index 8)
        get_ecn_for_nic "eth0" "8"
    ' 2>/dev/null)
    
    # Store per-NIC ECN counters
    while read -r nic_idx ecn cnp_sent cnp_handled; do
        [ -z "$nic_idx" ] && continue
        local array_idx=$((pod_idx * NICS_PER_POD + nic_idx))
        
        if [ "$prefix" == "before" ]; then
            before_ecn_marked[$array_idx]=${ecn:-0}
            before_cnp_sent[$array_idx]=${cnp_sent:-0}
            before_cnp_handled[$array_idx]=${cnp_handled:-0}
        else
            after_ecn_marked[$array_idx]=${ecn:-0}
            after_cnp_sent[$array_idx]=${cnp_sent:-0}
            after_cnp_handled[$array_idx]=${cnp_handled:-0}
        fi
    done <<< "$ecn_data"
}

# ============================================
# Collect NIC counters for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_nic_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting NIC counters from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_nic_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Collect ECN counters for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_ecn_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting ECN counters from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_ecn_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Collect all counters (NIC + ECN) for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_all_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    echo ""
    echo "=============================================="
    echo "Collecting NIC Counters ${prefix_upper} Test"
    echo "=============================================="
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_nic_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
        _collect_ecn_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Function to format counter value (show FAILED for -1)
# Arguments: $1=value
# ============================================
format_counter() {
    local val=$1
    if [ "$val" == "-1" ]; then
        echo "FAILED"
    else
        echo "$val"
    fi
}

# ============================================
# Function to print Packet Counters tables
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_nic_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: Packet Counters
        echo ""
        echo "=============================================================================="
        echo "Packet Counters ($prefix_upper) for: $pod (Node: $node)"
        echo "=============================================================================="
        
        # Sub-heading: RX Packets
        echo ""
        echo "RX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_rx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_packets_phy[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_rx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_packets_phy[$array_idx]}")"
            fi
        done
        
        # Sub-heading: TX Packets
        echo ""
        echo "TX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_tx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_packets_phy[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_tx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_packets_phy[$array_idx]}")"
            fi
        done
        
        # Sub-heading: RX Discards
        echo ""
        echo "RX Discards:"
        printf "%-8s %-24s %-24s %-24s\n" \
               "NIC" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
        printf "%-8s %-24s %-24s %-24s\n" \
               "--------" "------------------------" "------------------------" "------------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-24s %-24s %-24s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_rx_prio0_buf_discard[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio1_buf_discard[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_buf_discard[$array_idx]}")"
            else
                printf "%-8s %-24s %-24s %-24s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_rx_prio0_buf_discard[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio1_buf_discard[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_buf_discard[$array_idx]}")"
            fi
        done
        
        # Sub-heading: RX Bytes
        echo ""
        echo "RX Bytes:"
        printf "%-8s %-20s %-20s %-20s\n" \
               "NIC" "rx_prio0_bytes" "rx_prio1_bytes" "rx_prio5_bytes"
        printf "%-8s %-20s %-20s %-20s\n" \
               "--------" "--------------------" "--------------------" "--------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_rx_prio0_bytes[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio1_bytes[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_bytes[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_rx_prio0_bytes[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio1_bytes[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_bytes[$array_idx]}")"
            fi
        done
        
        # Sub-heading: TX Bytes
        echo ""
        echo "TX Bytes:"
        printf "%-8s %-20s %-20s %-20s\n" \
               "NIC" "tx_prio0_bytes" "tx_prio1_bytes" "tx_prio5_bytes"
        printf "%-8s %-20s %-20s %-20s\n" \
               "--------" "--------------------" "--------------------" "--------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_tx_prio0_bytes[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio1_bytes[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_bytes[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_tx_prio0_bytes[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio1_bytes[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_bytes[$array_idx]}")"
            fi
        done
    done
}

# ============================================
# Function to print PFC Counters tables
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_pfc_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: PFC Counters
        echo ""
        echo "=============================================================================="
        echo "PFC Counters ($prefix_upper) for: $pod (Node: $node) - Priorities 0 and 5"
        echo "=============================================================================="
        
        # Sub-heading: Pause Counts
        echo ""
        echo "Pause Counts:"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "NIC" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_tx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_pause[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_pause[$array_idx]}")"
            else
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_tx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_pause[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_pause[$array_idx]}")"
            fi
        done
        
        # Sub-heading: Pause Durations
        echo ""
        echo "Pause Durations:"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "NIC" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "--------" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_tx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_pause_duration[$array_idx]}")"
            else
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_tx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_pause_duration[$array_idx]}")"
            fi
        done
    done
}

# ============================================
# Function to print Packet Counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_nic_counter_diff() {
    local -n pods_ref=$1
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: Packet Counters DIFF
        echo ""
        echo "=============================================================================="
        echo "Packet Counters DIFF for: $pod (Node: $node)"
        echo "=============================================================================="
        
        # Sub-heading: RX Packets
        echo ""
        echo "RX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_rx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_packets[$array_idx]}" == "-1" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local rx_p0_diff=$((${after_rx_prio0_packets[$array_idx]:-0} - ${before_rx_prio0_packets[$array_idx]:-0}))
            local rx_p1_diff=$((${after_rx_prio1_packets[$array_idx]:-0} - ${before_rx_prio1_packets[$array_idx]:-0}))
            local rx_p5_diff=$((${after_rx_prio5_packets[$array_idx]:-0} - ${before_rx_prio5_packets[$array_idx]:-0}))
            local rx_phy_diff=$((${after_rx_packets_phy[$array_idx]:-0} - ${before_rx_packets_phy[$array_idx]:-0}))
            printf "%-8s %-20s %-20s %-20s %-18s\n" \
                   "$nic_name" "$rx_p0_diff" "$rx_p1_diff" "$rx_p5_diff" "$rx_phy_diff"
        done
        
        # Sub-heading: TX Packets
        echo ""
        echo "TX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_tx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_packets[$array_idx]}" == "-1" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_diff=$((${after_tx_prio0_packets[$array_idx]:-0} - ${before_tx_prio0_packets[$array_idx]:-0}))
            local tx_p1_diff=$((${after_tx_prio1_packets[$array_idx]:-0} - ${before_tx_prio1_packets[$array_idx]:-0}))
            local tx_p5_diff=$((${after_tx_prio5_packets[$array_idx]:-0} - ${before_tx_prio5_packets[$array_idx]:-0}))
            local tx_phy_diff=$((${after_tx_packets_phy[$array_idx]:-0} - ${before_tx_packets_phy[$array_idx]:-0}))
            printf "%-8s %-20s %-20s %-20s %-18s\n" \
                   "$nic_name" "$tx_p0_diff" "$tx_p1_diff" "$tx_p5_diff" "$tx_phy_diff"
        done
        
        # Sub-heading: RX Discards
        echo ""
        echo "RX Discards:"
        printf "%-8s %-24s %-24s %-24s\n" \
               "NIC" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
        printf "%-8s %-24s %-24s %-24s\n" \
               "--------" "------------------------" "------------------------" "------------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_rx_prio0_buf_discard[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_buf_discard[$array_idx]}" == "-1" ]; then
                printf "%-8s %-24s %-24s %-24s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local disc_p0_diff=$((${after_rx_prio0_buf_discard[$array_idx]:-0} - ${before_rx_prio0_buf_discard[$array_idx]:-0}))
            local disc_p1_diff=$((${after_rx_prio1_buf_discard[$array_idx]:-0} - ${before_rx_prio1_buf_discard[$array_idx]:-0}))
            local disc_p5_diff=$((${after_rx_prio5_buf_discard[$array_idx]:-0} - ${before_rx_prio5_buf_discard[$array_idx]:-0}))
            printf "%-8s %-24s %-24s %-24s\n" \
                   "$nic_name" "$disc_p0_diff" "$disc_p1_diff" "$disc_p5_diff"
        done
        
        # Sub-heading: RX Bytes
        echo ""
        echo "RX Bytes:"
        printf "%-8s %-18s %-18s %-18s\n" \
               "NIC" "rx_prio0_bytes" "rx_prio1_bytes" "rx_prio5_bytes"
        printf "%-8s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_rx_prio0_bytes[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_bytes[$array_idx]}" == "-1" ]; then
                printf "%-8s %-18s %-18s %-18s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local rx_b0_diff=$((${after_rx_prio0_bytes[$array_idx]:-0} - ${before_rx_prio0_bytes[$array_idx]:-0}))
            local rx_b1_diff=$((${after_rx_prio1_bytes[$array_idx]:-0} - ${before_rx_prio1_bytes[$array_idx]:-0}))
            local rx_b5_diff=$((${after_rx_prio5_bytes[$array_idx]:-0} - ${before_rx_prio5_bytes[$array_idx]:-0}))
            printf "%-8s %-18s %-18s %-18s\n" \
                   "$nic_name" "$(format_bytes $rx_b0_diff)" "$(format_bytes $rx_b1_diff)" "$(format_bytes $rx_b5_diff)"
        done
        
        # Sub-heading: TX Bytes
        echo ""
        echo "TX Bytes:"
        printf "%-8s %-18s %-18s %-18s\n" \
               "NIC" "tx_prio0_bytes" "tx_prio1_bytes" "tx_prio5_bytes"
        printf "%-8s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_tx_prio0_bytes[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_bytes[$array_idx]}" == "-1" ]; then
                printf "%-8s %-18s %-18s %-18s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_b0_diff=$((${after_tx_prio0_bytes[$array_idx]:-0} - ${before_tx_prio0_bytes[$array_idx]:-0}))
            local tx_b1_diff=$((${after_tx_prio1_bytes[$array_idx]:-0} - ${before_tx_prio1_bytes[$array_idx]:-0}))
            local tx_b5_diff=$((${after_tx_prio5_bytes[$array_idx]:-0} - ${before_tx_prio5_bytes[$array_idx]:-0}))
            printf "%-8s %-18s %-18s %-18s\n" \
                   "$nic_name" "$(format_bytes $tx_b0_diff)" "$(format_bytes $tx_b1_diff)" "$(format_bytes $tx_b5_diff)"
        done
    done
}

# ============================================
# Function to print PFC Counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_pfc_counter_diff() {
    local -n pods_ref=$1
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: PFC Counters DIFF
        echo ""
        echo "=============================================================================="
        echo "PFC Counters DIFF for: $pod (Node: $node) - Priorities 0 and 5"
        echo "=============================================================================="
        
        # Sub-heading: Pause Counts
        echo ""
        echo "Pause Counts:"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "NIC" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_diff=$((${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
            local rx_p0_diff=$((${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
            local tx_p5_diff=$((${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
            local rx_p5_diff=$((${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
            printf "%-8s %-18s %-18s %-18s %-18s\n" \
                   "$nic_name" "$tx_p0_diff" "$rx_p0_diff" "$tx_p5_diff" "$rx_p5_diff"
        done
        
        # Sub-heading: Pause Durations
        echo ""
        echo "Pause Durations:"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "NIC" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "--------" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            if [ "${before_tx_prio0_pause_duration[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause_duration[$array_idx]}" == "-1" ]; then
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "$nic_name" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_dur_diff=$((${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
            local rx_p0_dur_diff=$((${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
            local tx_p5_dur_diff=$((${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
            local rx_p5_dur_diff=$((${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
            printf "%-8s %-26s %-26s %-26s %-26s\n" \
                   "$nic_name" "$tx_p0_dur_diff" "$rx_p0_dur_diff" "$tx_p5_dur_diff" "$rx_p5_dur_diff"
        done
    done
}

# ============================================
# Function to print ECN counters table (per NIC)
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ECN counters are available for NICs backed by mlx5 devices
# ============================================
print_ecn_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading
        echo ""
        echo "=============================================================================="
        echo "ECN Counters ($prefix_upper) for: $pod (Node: $node)"
        echo "=============================================================================="
        printf "%-8s %-28s %-18s %-18s\n" \
               "NIC" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
        printf "%-8s %-28s %-18s %-18s\n" \
               "--------" "----------------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-28s %-18s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${before_ecn_marked[$array_idx]}")" \
                       "$(format_counter "${before_cnp_sent[$array_idx]}")" \
                       "$(format_counter "${before_cnp_handled[$array_idx]}")"
            else
                printf "%-8s %-28s %-18s %-18s\n" \
                       "$nic_name" \
                       "$(format_counter "${after_ecn_marked[$array_idx]}")" \
                       "$(format_counter "${after_cnp_sent[$array_idx]}")" \
                       "$(format_counter "${after_cnp_handled[$array_idx]}")"
            fi
        done
    done
}

# ============================================
# Function to print all counters (NIC + PFC + ECN)
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_all_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    print_nic_counters "$1" "$prefix"
    print_pfc_counters "$1" "$prefix"
    print_ecn_counters "$1" "$prefix"
}

# ============================================
# Function to print ECN Counter differences (per NIC)
# Arguments: $1=pod_names_array_ref
# ECN counters are available for NICs backed by mlx5 devices
# ============================================
print_ecn_counter_diff() {
    local -n pods_ref=$1
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading
        echo ""
        echo "=============================================================================="
        echo "ECN Counters DIFF for: $pod (Node: $node)"
        echo "=============================================================================="
        printf "%-8s %-28s %-18s %-18s\n" \
               "NIC" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
        printf "%-8s %-28s %-18s %-18s\n" \
               "--------" "----------------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local nic_name=$(get_nic_name $nic_idx)
            
            local ecn_diff=$((${after_ecn_marked[$array_idx]:-0} - ${before_ecn_marked[$array_idx]:-0}))
            local cnp_sent_diff=$((${after_cnp_sent[$array_idx]:-0} - ${before_cnp_sent[$array_idx]:-0}))
            local cnp_handled_diff=$((${after_cnp_handled[$array_idx]:-0} - ${before_cnp_handled[$array_idx]:-0}))
            
            printf "%-8s %-28d %-18d %-18d\n" \
                   "$nic_name" "$ecn_diff" "$cnp_sent_diff" "$cnp_handled_diff"
        done
    done
}

# ============================================
# Function to print all counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_all_counter_diff() {
    local -n pods_ref=$1
    
    echo ""
    echo "=============================================="
    echo "NIC Counter DIFFERENCES (After - Before)"
    echo "=============================================="
    
    print_nic_counter_diff "$1"
    print_pfc_counter_diff "$1"
    print_ecn_counter_diff "$1"
}

# ============================================
# Function to print priority packet counter summary (split by category)
# Arguments: $1=pod_names_array_ref
# Returns: Sets global skipped_nics variable
# Separates Backend (rdma0-7) and Frontend (eth0) NICs
# ============================================
print_priority_packet_summary() {
    local -n pods_ref=$1
    
    # Backend totals (rdma0-7)
    local be_total_rx_p0=0 be_total_rx_p1=0 be_total_rx_p5=0 be_total_rx_phy=0
    local be_total_tx_p0=0 be_total_tx_p1=0 be_total_tx_p5=0 be_total_tx_phy=0
    local be_total_disc_p0=0 be_total_disc_p1=0 be_total_disc_p5=0
    
    # Frontend totals (eth0)
    local fe_total_rx_p0=0 fe_total_rx_p1=0 fe_total_rx_p5=0 fe_total_rx_phy=0
    local fe_total_tx_p0=0 fe_total_tx_p1=0 fe_total_tx_p5=0 fe_total_tx_phy=0
    local fe_total_disc_p0=0 fe_total_disc_p1=0 fe_total_disc_p5=0
    
    skipped_nics=0
    
    # Arrays to hold per-pod totals for backend
    declare -a be_pod_rx_p0 be_pod_rx_p1 be_pod_rx_p5 be_pod_rx_phy
    declare -a be_pod_tx_p0 be_pod_tx_p1 be_pod_tx_p5 be_pod_tx_phy
    declare -a be_pod_disc_p0 be_pod_disc_p1 be_pod_disc_p5
    declare -a be_pod_skipped
    
    # Arrays to hold per-pod totals for frontend
    declare -a fe_pod_rx_p0 fe_pod_rx_p1 fe_pod_rx_p5 fe_pod_rx_phy
    declare -a fe_pod_tx_p0 fe_pod_tx_p1 fe_pod_tx_p5 fe_pod_tx_phy
    declare -a fe_pod_disc_p0 fe_pod_disc_p1 fe_pod_disc_p5
    declare -a fe_pod_skipped
    
    for i in "${!pods_ref[@]}"; do
        # Initialize backend arrays
        be_pod_rx_p0[$i]=0; be_pod_rx_p1[$i]=0; be_pod_rx_p5[$i]=0; be_pod_rx_phy[$i]=0
        be_pod_tx_p0[$i]=0; be_pod_tx_p1[$i]=0; be_pod_tx_p5[$i]=0; be_pod_tx_phy[$i]=0
        be_pod_disc_p0[$i]=0; be_pod_disc_p1[$i]=0; be_pod_disc_p5[$i]=0
        be_pod_skipped[$i]=0
        
        # Initialize frontend arrays
        fe_pod_rx_p0[$i]=0; fe_pod_rx_p1[$i]=0; fe_pod_rx_p5[$i]=0; fe_pod_rx_phy[$i]=0
        fe_pod_tx_p0[$i]=0; fe_pod_tx_p1[$i]=0; fe_pod_tx_p5[$i]=0; fe_pod_tx_phy[$i]=0
        fe_pod_disc_p0[$i]=0; fe_pod_disc_p1[$i]=0; fe_pod_disc_p5[$i]=0
        fe_pod_skipped[$i]=0
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local is_backend=$( [ $nic_idx -lt 8 ] && echo 1 || echo 0 )
            
            if [ "${before_rx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_packets[$array_idx]}" == "-1" ]; then
                if [ $is_backend -eq 1 ]; then
                    be_pod_skipped[$i]=$((${be_pod_skipped[$i]} + 1))
                else
                    fe_pod_skipped[$i]=$((${fe_pod_skipped[$i]} + 1))
                fi
                skipped_nics=$((skipped_nics + 1))
                continue
            fi
            
            # Calculate diffs
            local rx_p0=$((${after_rx_prio0_packets[$array_idx]:-0} - ${before_rx_prio0_packets[$array_idx]:-0}))
            local rx_p1=$((${after_rx_prio1_packets[$array_idx]:-0} - ${before_rx_prio1_packets[$array_idx]:-0}))
            local rx_p5=$((${after_rx_prio5_packets[$array_idx]:-0} - ${before_rx_prio5_packets[$array_idx]:-0}))
            local rx_phy=$((${after_rx_packets_phy[$array_idx]:-0} - ${before_rx_packets_phy[$array_idx]:-0}))
            local tx_p0=$((${after_tx_prio0_packets[$array_idx]:-0} - ${before_tx_prio0_packets[$array_idx]:-0}))
            local tx_p1=$((${after_tx_prio1_packets[$array_idx]:-0} - ${before_tx_prio1_packets[$array_idx]:-0}))
            local tx_p5=$((${after_tx_prio5_packets[$array_idx]:-0} - ${before_tx_prio5_packets[$array_idx]:-0}))
            local tx_phy=$((${after_tx_packets_phy[$array_idx]:-0} - ${before_tx_packets_phy[$array_idx]:-0}))
            local disc_p0=$((${after_rx_prio0_buf_discard[$array_idx]:-0} - ${before_rx_prio0_buf_discard[$array_idx]:-0}))
            local disc_p1=$((${after_rx_prio1_buf_discard[$array_idx]:-0} - ${before_rx_prio1_buf_discard[$array_idx]:-0}))
            local disc_p5=$((${after_rx_prio5_buf_discard[$array_idx]:-0} - ${before_rx_prio5_buf_discard[$array_idx]:-0}))
            
            if [ $is_backend -eq 1 ]; then
                # Backend NICs (rdma0-7)
                be_pod_rx_p0[$i]=$((${be_pod_rx_p0[$i]} + rx_p0))
                be_pod_rx_p1[$i]=$((${be_pod_rx_p1[$i]} + rx_p1))
                be_pod_rx_p5[$i]=$((${be_pod_rx_p5[$i]} + rx_p5))
                be_pod_rx_phy[$i]=$((${be_pod_rx_phy[$i]} + rx_phy))
                be_pod_tx_p0[$i]=$((${be_pod_tx_p0[$i]} + tx_p0))
                be_pod_tx_p1[$i]=$((${be_pod_tx_p1[$i]} + tx_p1))
                be_pod_tx_p5[$i]=$((${be_pod_tx_p5[$i]} + tx_p5))
                be_pod_tx_phy[$i]=$((${be_pod_tx_phy[$i]} + tx_phy))
                be_pod_disc_p0[$i]=$((${be_pod_disc_p0[$i]} + disc_p0))
                be_pod_disc_p1[$i]=$((${be_pod_disc_p1[$i]} + disc_p1))
                be_pod_disc_p5[$i]=$((${be_pod_disc_p5[$i]} + disc_p5))
            else
                # Frontend NIC (eth0)
                fe_pod_rx_p0[$i]=$((${fe_pod_rx_p0[$i]} + rx_p0))
                fe_pod_rx_p1[$i]=$((${fe_pod_rx_p1[$i]} + rx_p1))
                fe_pod_rx_p5[$i]=$((${fe_pod_rx_p5[$i]} + rx_p5))
                fe_pod_rx_phy[$i]=$((${fe_pod_rx_phy[$i]} + rx_phy))
                fe_pod_tx_p0[$i]=$((${fe_pod_tx_p0[$i]} + tx_p0))
                fe_pod_tx_p1[$i]=$((${fe_pod_tx_p1[$i]} + tx_p1))
                fe_pod_tx_p5[$i]=$((${fe_pod_tx_p5[$i]} + tx_p5))
                fe_pod_tx_phy[$i]=$((${fe_pod_tx_phy[$i]} + tx_phy))
                fe_pod_disc_p0[$i]=$((${fe_pod_disc_p0[$i]} + disc_p0))
                fe_pod_disc_p1[$i]=$((${fe_pod_disc_p1[$i]} + disc_p1))
                fe_pod_disc_p5[$i]=$((${fe_pod_disc_p5[$i]} + disc_p5))
            fi
        done
        
        # Accumulate backend totals
        be_total_rx_p0=$((be_total_rx_p0 + ${be_pod_rx_p0[$i]}))
        be_total_rx_p1=$((be_total_rx_p1 + ${be_pod_rx_p1[$i]}))
        be_total_rx_p5=$((be_total_rx_p5 + ${be_pod_rx_p5[$i]}))
        be_total_rx_phy=$((be_total_rx_phy + ${be_pod_rx_phy[$i]}))
        be_total_tx_p0=$((be_total_tx_p0 + ${be_pod_tx_p0[$i]}))
        be_total_tx_p1=$((be_total_tx_p1 + ${be_pod_tx_p1[$i]}))
        be_total_tx_p5=$((be_total_tx_p5 + ${be_pod_tx_p5[$i]}))
        be_total_tx_phy=$((be_total_tx_phy + ${be_pod_tx_phy[$i]}))
        be_total_disc_p0=$((be_total_disc_p0 + ${be_pod_disc_p0[$i]}))
        be_total_disc_p1=$((be_total_disc_p1 + ${be_pod_disc_p1[$i]}))
        be_total_disc_p5=$((be_total_disc_p5 + ${be_pod_disc_p5[$i]}))
        
        # Accumulate frontend totals
        fe_total_rx_p0=$((fe_total_rx_p0 + ${fe_pod_rx_p0[$i]}))
        fe_total_rx_p1=$((fe_total_rx_p1 + ${fe_pod_rx_p1[$i]}))
        fe_total_rx_p5=$((fe_total_rx_p5 + ${fe_pod_rx_p5[$i]}))
        fe_total_rx_phy=$((fe_total_rx_phy + ${fe_pod_rx_phy[$i]}))
        fe_total_tx_p0=$((fe_total_tx_p0 + ${fe_pod_tx_p0[$i]}))
        fe_total_tx_p1=$((fe_total_tx_p1 + ${fe_pod_tx_p1[$i]}))
        fe_total_tx_p5=$((fe_total_tx_p5 + ${fe_pod_tx_p5[$i]}))
        fe_total_tx_phy=$((fe_total_tx_phy + ${fe_pod_tx_phy[$i]}))
        fe_total_disc_p0=$((fe_total_disc_p0 + ${fe_pod_disc_p0[$i]}))
        fe_total_disc_p1=$((fe_total_disc_p1 + ${fe_pod_disc_p1[$i]}))
        fe_total_disc_p5=$((fe_total_disc_p5 + ${fe_pod_disc_p5[$i]}))
    done
    
    # ==========================================
    # BACKEND NICs Summary (rdma0-rdma7)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: Packet Counters - BACKEND NICs (rdma0-rdma7)"
    echo "=============================================================================="
    
    # Sub-heading: RX Packets
    echo ""
    echo "RX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        if [ ${be_pod_skipped[$i]} -gt 0 ]; then
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d (%d skip)\n" \
                   "${pods_ref[$i]}" "${be_pod_rx_p0[$i]}" "${be_pod_rx_p1[$i]}" "${be_pod_rx_p5[$i]}" "${be_pod_rx_phy[$i]}" "${be_pod_skipped[$i]}"
        else
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
                   "${pods_ref[$i]}" "${be_pod_rx_p0[$i]}" "${be_pod_rx_p1[$i]}" "${be_pod_rx_p5[$i]}" "${be_pod_rx_phy[$i]}"
        fi
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$be_total_rx_p0" "$be_total_rx_p1" "$be_total_rx_p5" "$be_total_rx_phy"
    
    # Sub-heading: TX Packets
    echo ""
    echo "TX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
               "${pods_ref[$i]}" "${be_pod_tx_p0[$i]}" "${be_pod_tx_p1[$i]}" "${be_pod_tx_p5[$i]}" "${be_pod_tx_phy[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$be_total_tx_p0" "$be_total_tx_p1" "$be_total_tx_p5" "$be_total_tx_phy"
    
    # Sub-heading: RX Discards
    echo ""
    echo "RX Discards:"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "POD" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
               "${pods_ref[$i]}" "${be_pod_disc_p0[$i]}" "${be_pod_disc_p1[$i]}" "${be_pod_disc_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
           "TOTAL" "$be_total_disc_p0" "$be_total_disc_p1" "$be_total_disc_p5"
    
    # ==========================================
    # FRONTEND NIC Summary (eth0)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: Packet Counters - FRONTEND NIC (eth0)"
    echo "=============================================================================="
    
    # Sub-heading: RX Packets
    echo ""
    echo "RX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        if [ ${fe_pod_skipped[$i]} -gt 0 ]; then
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d (skip)\n" \
                   "${pods_ref[$i]}" "${fe_pod_rx_p0[$i]}" "${fe_pod_rx_p1[$i]}" "${fe_pod_rx_p5[$i]}" "${fe_pod_rx_phy[$i]}"
        else
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
                   "${pods_ref[$i]}" "${fe_pod_rx_p0[$i]}" "${fe_pod_rx_p1[$i]}" "${fe_pod_rx_p5[$i]}" "${fe_pod_rx_phy[$i]}"
        fi
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$fe_total_rx_p0" "$fe_total_rx_p1" "$fe_total_rx_p5" "$fe_total_rx_phy"
    
    # Sub-heading: TX Packets
    echo ""
    echo "TX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
               "${pods_ref[$i]}" "${fe_pod_tx_p0[$i]}" "${fe_pod_tx_p1[$i]}" "${fe_pod_tx_p5[$i]}" "${fe_pod_tx_phy[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$fe_total_tx_p0" "$fe_total_tx_p1" "$fe_total_tx_p5" "$fe_total_tx_phy"
    
    # Sub-heading: RX Discards
    echo ""
    echo "RX Discards:"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "POD" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
               "${pods_ref[$i]}" "${fe_pod_disc_p0[$i]}" "${fe_pod_disc_p1[$i]}" "${fe_pod_disc_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
           "TOTAL" "$fe_total_disc_p0" "$fe_total_disc_p1" "$fe_total_disc_p5"
}

# ============================================
# Function to print byte counter summary
# Arguments: $1=pod_names_array_ref
# Separates Backend (rdma0-7) and Frontend (eth0) NICs
# ============================================
print_byte_summary() {
    local -n pods_ref=$1
    
    # Backend totals (rdma0-7)
    local be_total_rx_b0=0 be_total_rx_b1=0 be_total_rx_b5=0
    local be_total_tx_b0=0 be_total_tx_b1=0 be_total_tx_b5=0
    
    # Frontend totals (eth0)
    local fe_total_rx_b0=0 fe_total_rx_b1=0 fe_total_rx_b5=0
    local fe_total_tx_b0=0 fe_total_tx_b1=0 fe_total_tx_b5=0
    
    # Arrays to hold per-pod totals for backend
    declare -a be_pod_rx_b0 be_pod_rx_b1 be_pod_rx_b5
    declare -a be_pod_tx_b0 be_pod_tx_b1 be_pod_tx_b5
    
    # Arrays to hold per-pod totals for frontend
    declare -a fe_pod_rx_b0 fe_pod_rx_b1 fe_pod_rx_b5
    declare -a fe_pod_tx_b0 fe_pod_tx_b1 fe_pod_tx_b5
    
    for i in "${!pods_ref[@]}"; do
        # Initialize backend arrays
        be_pod_rx_b0[$i]=0; be_pod_rx_b1[$i]=0; be_pod_rx_b5[$i]=0
        be_pod_tx_b0[$i]=0; be_pod_tx_b1[$i]=0; be_pod_tx_b5[$i]=0
        
        # Initialize frontend arrays
        fe_pod_rx_b0[$i]=0; fe_pod_rx_b1[$i]=0; fe_pod_rx_b5[$i]=0
        fe_pod_tx_b0[$i]=0; fe_pod_tx_b1[$i]=0; fe_pod_tx_b5[$i]=0
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local is_backend=$( [ $nic_idx -lt 8 ] && echo 1 || echo 0 )
            
            if [ "${before_rx_prio0_bytes[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_bytes[$array_idx]}" == "-1" ]; then
                continue
            fi
            
            # Calculate diffs
            local rx_b0=$((${after_rx_prio0_bytes[$array_idx]:-0} - ${before_rx_prio0_bytes[$array_idx]:-0}))
            local rx_b1=$((${after_rx_prio1_bytes[$array_idx]:-0} - ${before_rx_prio1_bytes[$array_idx]:-0}))
            local rx_b5=$((${after_rx_prio5_bytes[$array_idx]:-0} - ${before_rx_prio5_bytes[$array_idx]:-0}))
            local tx_b0=$((${after_tx_prio0_bytes[$array_idx]:-0} - ${before_tx_prio0_bytes[$array_idx]:-0}))
            local tx_b1=$((${after_tx_prio1_bytes[$array_idx]:-0} - ${before_tx_prio1_bytes[$array_idx]:-0}))
            local tx_b5=$((${after_tx_prio5_bytes[$array_idx]:-0} - ${before_tx_prio5_bytes[$array_idx]:-0}))
            
            if [ $is_backend -eq 1 ]; then
                # Backend NICs (rdma0-7)
                be_pod_rx_b0[$i]=$((${be_pod_rx_b0[$i]} + rx_b0))
                be_pod_rx_b1[$i]=$((${be_pod_rx_b1[$i]} + rx_b1))
                be_pod_rx_b5[$i]=$((${be_pod_rx_b5[$i]} + rx_b5))
                be_pod_tx_b0[$i]=$((${be_pod_tx_b0[$i]} + tx_b0))
                be_pod_tx_b1[$i]=$((${be_pod_tx_b1[$i]} + tx_b1))
                be_pod_tx_b5[$i]=$((${be_pod_tx_b5[$i]} + tx_b5))
            else
                # Frontend NIC (eth0)
                fe_pod_rx_b0[$i]=$((${fe_pod_rx_b0[$i]} + rx_b0))
                fe_pod_rx_b1[$i]=$((${fe_pod_rx_b1[$i]} + rx_b1))
                fe_pod_rx_b5[$i]=$((${fe_pod_rx_b5[$i]} + rx_b5))
                fe_pod_tx_b0[$i]=$((${fe_pod_tx_b0[$i]} + tx_b0))
                fe_pod_tx_b1[$i]=$((${fe_pod_tx_b1[$i]} + tx_b1))
                fe_pod_tx_b5[$i]=$((${fe_pod_tx_b5[$i]} + tx_b5))
            fi
        done
        
        # Accumulate backend totals
        be_total_rx_b0=$((be_total_rx_b0 + ${be_pod_rx_b0[$i]}))
        be_total_rx_b1=$((be_total_rx_b1 + ${be_pod_rx_b1[$i]}))
        be_total_rx_b5=$((be_total_rx_b5 + ${be_pod_rx_b5[$i]}))
        be_total_tx_b0=$((be_total_tx_b0 + ${be_pod_tx_b0[$i]}))
        be_total_tx_b1=$((be_total_tx_b1 + ${be_pod_tx_b1[$i]}))
        be_total_tx_b5=$((be_total_tx_b5 + ${be_pod_tx_b5[$i]}))
        
        # Accumulate frontend totals
        fe_total_rx_b0=$((fe_total_rx_b0 + ${fe_pod_rx_b0[$i]}))
        fe_total_rx_b1=$((fe_total_rx_b1 + ${fe_pod_rx_b1[$i]}))
        fe_total_rx_b5=$((fe_total_rx_b5 + ${fe_pod_rx_b5[$i]}))
        fe_total_tx_b0=$((fe_total_tx_b0 + ${fe_pod_tx_b0[$i]}))
        fe_total_tx_b1=$((fe_total_tx_b1 + ${fe_pod_tx_b1[$i]}))
        fe_total_tx_b5=$((fe_total_tx_b5 + ${fe_pod_tx_b5[$i]}))
    done
    
    # ==========================================
    # BACKEND NICs Summary (rdma0-rdma7)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: Byte Counters - BACKEND NICs (rdma0-rdma7)"
    echo "=============================================================================="
    
    # Sub-heading: RX Bytes
    echo ""
    echo "RX Bytes:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "POD" "rx_prio0_bytes" "rx_prio1_bytes" "rx_prio5_bytes"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
               "${pods_ref[$i]}" "$(format_bytes ${be_pod_rx_b0[$i]})" "$(format_bytes ${be_pod_rx_b1[$i]})" "$(format_bytes ${be_pod_rx_b5[$i]})"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "TOTAL" "$(format_bytes $be_total_rx_b0)" "$(format_bytes $be_total_rx_b1)" "$(format_bytes $be_total_rx_b5)"
    
    # Sub-heading: TX Bytes
    echo ""
    echo "TX Bytes:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "POD" "tx_prio0_bytes" "tx_prio1_bytes" "tx_prio5_bytes"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
               "${pods_ref[$i]}" "$(format_bytes ${be_pod_tx_b0[$i]})" "$(format_bytes ${be_pod_tx_b1[$i]})" "$(format_bytes ${be_pod_tx_b5[$i]})"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "TOTAL" "$(format_bytes $be_total_tx_b0)" "$(format_bytes $be_total_tx_b1)" "$(format_bytes $be_total_tx_b5)"
    
    # ==========================================
    # FRONTEND NIC Summary (eth0)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: Byte Counters - FRONTEND NIC (eth0)"
    echo "=============================================================================="
    
    # Sub-heading: RX Bytes
    echo ""
    echo "RX Bytes:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "POD" "rx_prio0_bytes" "rx_prio1_bytes" "rx_prio5_bytes"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
               "${pods_ref[$i]}" "$(format_bytes ${fe_pod_rx_b0[$i]})" "$(format_bytes ${fe_pod_rx_b1[$i]})" "$(format_bytes ${fe_pod_rx_b5[$i]})"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "TOTAL" "$(format_bytes $fe_total_rx_b0)" "$(format_bytes $fe_total_rx_b1)" "$(format_bytes $fe_total_rx_b5)"
    
    # Sub-heading: TX Bytes
    echo ""
    echo "TX Bytes:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "POD" "tx_prio0_bytes" "tx_prio1_bytes" "tx_prio5_bytes"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
               "${pods_ref[$i]}" "$(format_bytes ${fe_pod_tx_b0[$i]})" "$(format_bytes ${fe_pod_tx_b1[$i]})" "$(format_bytes ${fe_pod_tx_b5[$i]})"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s\n" \
           "TOTAL" "$(format_bytes $fe_total_tx_b0)" "$(format_bytes $fe_total_tx_b1)" "$(format_bytes $fe_total_tx_b5)"
}

# ============================================
# Function to print PFC pause counter summary (split by counts and durations)
# Arguments: $1=pod_names_array_ref
# Separates Backend (rdma0-7) and Frontend (eth0) NICs
# ============================================
print_pfc_pause_summary() {
    local -n pods_ref=$1
    
    # Backend totals (rdma0-7)
    local be_total_tx_p0=0 be_total_rx_p0=0 be_total_tx_p5=0 be_total_rx_p5=0
    local be_total_tx_p0_dur=0 be_total_rx_p0_dur=0 be_total_tx_p5_dur=0 be_total_rx_p5_dur=0
    
    # Frontend totals (eth0)
    local fe_total_tx_p0=0 fe_total_rx_p0=0 fe_total_tx_p5=0 fe_total_rx_p5=0
    local fe_total_tx_p0_dur=0 fe_total_rx_p0_dur=0 fe_total_tx_p5_dur=0 fe_total_rx_p5_dur=0
    
    # Arrays to hold per-pod backend totals
    declare -a be_pod_tx_p0 be_pod_rx_p0 be_pod_tx_p5 be_pod_rx_p5
    declare -a be_pod_tx_p0_dur be_pod_rx_p0_dur be_pod_tx_p5_dur be_pod_rx_p5_dur
    
    # Arrays to hold per-pod frontend totals
    declare -a fe_pod_tx_p0 fe_pod_rx_p0 fe_pod_tx_p5 fe_pod_rx_p5
    declare -a fe_pod_tx_p0_dur fe_pod_rx_p0_dur fe_pod_tx_p5_dur fe_pod_rx_p5_dur
    
    for i in "${!pods_ref[@]}"; do
        # Initialize backend arrays
        be_pod_tx_p0[$i]=0; be_pod_rx_p0[$i]=0; be_pod_tx_p5[$i]=0; be_pod_rx_p5[$i]=0
        be_pod_tx_p0_dur[$i]=0; be_pod_rx_p0_dur[$i]=0; be_pod_tx_p5_dur[$i]=0; be_pod_rx_p5_dur[$i]=0
        
        # Initialize frontend arrays
        fe_pod_tx_p0[$i]=0; fe_pod_rx_p0[$i]=0; fe_pod_tx_p5[$i]=0; fe_pod_rx_p5[$i]=0
        fe_pod_tx_p0_dur[$i]=0; fe_pod_rx_p0_dur[$i]=0; fe_pod_tx_p5_dur[$i]=0; fe_pod_rx_p5_dur[$i]=0
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local is_backend=$( [ $nic_idx -lt 8 ] && echo 1 || echo 0 )
            
            if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
                continue
            fi
            
            # Calculate diffs
            local tx_p0=$((${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
            local rx_p0=$((${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
            local tx_p5=$((${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
            local rx_p5=$((${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
            local tx_p0_dur=$((${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
            local rx_p0_dur=$((${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
            local tx_p5_dur=$((${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
            local rx_p5_dur=$((${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
            
            if [ $is_backend -eq 1 ]; then
                # Backend NICs (rdma0-7)
                be_pod_tx_p0[$i]=$((${be_pod_tx_p0[$i]} + tx_p0))
                be_pod_rx_p0[$i]=$((${be_pod_rx_p0[$i]} + rx_p0))
                be_pod_tx_p5[$i]=$((${be_pod_tx_p5[$i]} + tx_p5))
                be_pod_rx_p5[$i]=$((${be_pod_rx_p5[$i]} + rx_p5))
                be_pod_tx_p0_dur[$i]=$((${be_pod_tx_p0_dur[$i]} + tx_p0_dur))
                be_pod_rx_p0_dur[$i]=$((${be_pod_rx_p0_dur[$i]} + rx_p0_dur))
                be_pod_tx_p5_dur[$i]=$((${be_pod_tx_p5_dur[$i]} + tx_p5_dur))
                be_pod_rx_p5_dur[$i]=$((${be_pod_rx_p5_dur[$i]} + rx_p5_dur))
            else
                # Frontend NIC (eth0)
                fe_pod_tx_p0[$i]=$((${fe_pod_tx_p0[$i]} + tx_p0))
                fe_pod_rx_p0[$i]=$((${fe_pod_rx_p0[$i]} + rx_p0))
                fe_pod_tx_p5[$i]=$((${fe_pod_tx_p5[$i]} + tx_p5))
                fe_pod_rx_p5[$i]=$((${fe_pod_rx_p5[$i]} + rx_p5))
                fe_pod_tx_p0_dur[$i]=$((${fe_pod_tx_p0_dur[$i]} + tx_p0_dur))
                fe_pod_rx_p0_dur[$i]=$((${fe_pod_rx_p0_dur[$i]} + rx_p0_dur))
                fe_pod_tx_p5_dur[$i]=$((${fe_pod_tx_p5_dur[$i]} + tx_p5_dur))
                fe_pod_rx_p5_dur[$i]=$((${fe_pod_rx_p5_dur[$i]} + rx_p5_dur))
            fi
        done
        
        # Accumulate backend totals
        be_total_tx_p0=$((be_total_tx_p0 + ${be_pod_tx_p0[$i]}))
        be_total_rx_p0=$((be_total_rx_p0 + ${be_pod_rx_p0[$i]}))
        be_total_tx_p5=$((be_total_tx_p5 + ${be_pod_tx_p5[$i]}))
        be_total_rx_p5=$((be_total_rx_p5 + ${be_pod_rx_p5[$i]}))
        be_total_tx_p0_dur=$((be_total_tx_p0_dur + ${be_pod_tx_p0_dur[$i]}))
        be_total_rx_p0_dur=$((be_total_rx_p0_dur + ${be_pod_rx_p0_dur[$i]}))
        be_total_tx_p5_dur=$((be_total_tx_p5_dur + ${be_pod_tx_p5_dur[$i]}))
        be_total_rx_p5_dur=$((be_total_rx_p5_dur + ${be_pod_rx_p5_dur[$i]}))
        
        # Accumulate frontend totals
        fe_total_tx_p0=$((fe_total_tx_p0 + ${fe_pod_tx_p0[$i]}))
        fe_total_rx_p0=$((fe_total_rx_p0 + ${fe_pod_rx_p0[$i]}))
        fe_total_tx_p5=$((fe_total_tx_p5 + ${fe_pod_tx_p5[$i]}))
        fe_total_rx_p5=$((fe_total_rx_p5 + ${fe_pod_rx_p5[$i]}))
        fe_total_tx_p0_dur=$((fe_total_tx_p0_dur + ${fe_pod_tx_p0_dur[$i]}))
        fe_total_rx_p0_dur=$((fe_total_rx_p0_dur + ${fe_pod_rx_p0_dur[$i]}))
        fe_total_tx_p5_dur=$((fe_total_tx_p5_dur + ${fe_pod_tx_p5_dur[$i]}))
        fe_total_rx_p5_dur=$((fe_total_rx_p5_dur + ${fe_pod_rx_p5_dur[$i]}))
    done
    
    # ==========================================
    # BACKEND NICs Summary (rdma0-rdma7)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: PFC Counters - BACKEND NICs (rdma0-rdma7) - Priorities 0 and 5"
    echo "=============================================================================="
    
    # Sub-heading: Pause Counts
    echo ""
    echo "Pause Counts:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "POD" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
               "${pods_ref[$i]}" "${be_pod_tx_p0[$i]}" "${be_pod_rx_p0[$i]}" "${be_pod_tx_p5[$i]}" "${be_pod_rx_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
           "TOTAL" "$be_total_tx_p0" "$be_total_rx_p0" "$be_total_tx_p5" "$be_total_rx_p5"
    
    # Sub-heading: Pause Durations
    echo ""
    echo "Pause Durations:"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "POD" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
               "${pods_ref[$i]}" "${be_pod_tx_p0_dur[$i]}" "${be_pod_rx_p0_dur[$i]}" "${be_pod_tx_p5_dur[$i]}" "${be_pod_rx_p5_dur[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
           "TOTAL" "$be_total_tx_p0_dur" "$be_total_rx_p0_dur" "$be_total_tx_p5_dur" "$be_total_rx_p5_dur"
    
    # ==========================================
    # FRONTEND NIC Summary (eth0)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: PFC Counters - FRONTEND NIC (eth0) - Priorities 0 and 5"
    echo "=============================================================================="
    
    # Sub-heading: Pause Counts
    echo ""
    echo "Pause Counts:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "POD" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
               "${pods_ref[$i]}" "${fe_pod_tx_p0[$i]}" "${fe_pod_rx_p0[$i]}" "${fe_pod_tx_p5[$i]}" "${fe_pod_rx_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
           "TOTAL" "$fe_total_tx_p0" "$fe_total_rx_p0" "$fe_total_tx_p5" "$fe_total_rx_p5"
    
    # Sub-heading: Pause Durations
    echo ""
    echo "Pause Durations:"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "POD" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
               "${pods_ref[$i]}" "${fe_pod_tx_p0_dur[$i]}" "${fe_pod_rx_p0_dur[$i]}" "${fe_pod_tx_p5_dur[$i]}" "${fe_pod_rx_p5_dur[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
           "TOTAL" "$fe_total_tx_p0_dur" "$fe_total_rx_p0_dur" "$fe_total_tx_p5_dur" "$fe_total_rx_p5_dur"
}

# ============================================
# Function to print ECN counter summary
# Arguments: $1=pod_names_array_ref
# Separates Backend (rdma0-7) and Frontend (eth0) NICs
# ============================================
print_ecn_summary() {
    local -n pods_ref=$1
    
    # Backend totals (rdma0-7)
    local be_total_ecn=0 be_total_cnp_sent=0 be_total_cnp_handled=0
    
    # Frontend totals (eth0)
    local fe_total_ecn=0 fe_total_cnp_sent=0 fe_total_cnp_handled=0
    
    # Arrays to hold per-pod backend totals
    declare -a be_pod_ecn be_pod_cnp_sent be_pod_cnp_handled
    
    # Arrays to hold per-pod frontend totals
    declare -a fe_pod_ecn fe_pod_cnp_sent fe_pod_cnp_handled
    
    for i in "${!pods_ref[@]}"; do
        be_pod_ecn[$i]=0; be_pod_cnp_sent[$i]=0; be_pod_cnp_handled[$i]=0
        fe_pod_ecn[$i]=0; fe_pod_cnp_sent[$i]=0; fe_pod_cnp_handled[$i]=0
        
        for nic_idx in $(seq 0 $((NICS_PER_POD - 1))); do
            local array_idx=$((i * NICS_PER_POD + nic_idx))
            local is_backend=$( [ $nic_idx -lt 8 ] && echo 1 || echo 0 )
            
            local ecn_diff=$((${after_ecn_marked[$array_idx]:-0} - ${before_ecn_marked[$array_idx]:-0}))
            local cnp_sent_diff=$((${after_cnp_sent[$array_idx]:-0} - ${before_cnp_sent[$array_idx]:-0}))
            local cnp_handled_diff=$((${after_cnp_handled[$array_idx]:-0} - ${before_cnp_handled[$array_idx]:-0}))
            
            if [ $is_backend -eq 1 ]; then
                be_pod_ecn[$i]=$((${be_pod_ecn[$i]} + ecn_diff))
                be_pod_cnp_sent[$i]=$((${be_pod_cnp_sent[$i]} + cnp_sent_diff))
                be_pod_cnp_handled[$i]=$((${be_pod_cnp_handled[$i]} + cnp_handled_diff))
            else
                fe_pod_ecn[$i]=$((${fe_pod_ecn[$i]} + ecn_diff))
                fe_pod_cnp_sent[$i]=$((${fe_pod_cnp_sent[$i]} + cnp_sent_diff))
                fe_pod_cnp_handled[$i]=$((${fe_pod_cnp_handled[$i]} + cnp_handled_diff))
            fi
        done
        
        be_total_ecn=$((be_total_ecn + ${be_pod_ecn[$i]}))
        be_total_cnp_sent=$((be_total_cnp_sent + ${be_pod_cnp_sent[$i]}))
        be_total_cnp_handled=$((be_total_cnp_handled + ${be_pod_cnp_handled[$i]}))
        
        fe_total_ecn=$((fe_total_ecn + ${fe_pod_ecn[$i]}))
        fe_total_cnp_sent=$((fe_total_cnp_sent + ${fe_pod_cnp_sent[$i]}))
        fe_total_cnp_handled=$((fe_total_cnp_handled + ${fe_pod_cnp_handled[$i]}))
    done
    
    # ==========================================
    # BACKEND NICs Summary (rdma0-rdma7)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: ECN Counters - BACKEND NICs (rdma0-rdma7)"
    echo "=============================================================================="
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "POD" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "${pods_ref[$i]}" "${be_pod_ecn[$i]}" "${be_pod_cnp_sent[$i]}" "${be_pod_cnp_handled[$i]}"
    done
    
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "TOTAL" "$be_total_ecn" "$be_total_cnp_sent" "$be_total_cnp_handled"
    
    # ==========================================
    # FRONTEND NIC Summary (eth0)
    # ==========================================
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: ECN Counters - FRONTEND NIC (eth0)"
    echo "=============================================================================="
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "POD" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "${pods_ref[$i]}" "${fe_pod_ecn[$i]}" "${fe_pod_cnp_sent[$i]}" "${fe_pod_cnp_handled[$i]}"
    done
    
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "TOTAL" "$fe_total_ecn" "$fe_total_cnp_sent" "$fe_total_cnp_handled"
}

# ============================================
# Function to print all summaries
# Arguments: $1=pod_names_array_ref
# ============================================
print_all_summaries() {
    print_priority_packet_summary "$1"
    print_byte_summary "$1"
    print_pfc_pause_summary "$1"
    print_ecn_summary "$1"
}

# ============================================
# Function to print final notes
# ============================================
print_final_notes() {
    echo ""
    echo "=============================================="
    echo "Notes:"
    echo "=============================================="
    echo "- Backend NICs: rdma0-rdma7 (8 NICs for RDMA/GPU traffic)"
    echo "- Frontend NIC: eth0 (1 NIC for control plane/external traffic)"
    echo "- PFC is enabled for priorities 0 and 5"
    echo "- ECN counters: ecn_marked=packets marked by network, cnp_sent/handled=congestion notifications"
    echo "- PFC pause_duration: cumulative time paused (in device-specific units, often μs)"
    if [ "${skipped_nics:-0}" -gt 0 ]; then
        echo "- WARNING: $skipped_nics NIC(s) had data fetch failures and were excluded from totals"
    fi
}
