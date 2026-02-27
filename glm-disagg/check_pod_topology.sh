#!/bin/bash

# Check GPU and NIC PCIe topology for all model server pods in a namespace.
# Auto-detects glm-agg vs glm-disagg deployments.
# Usage: ./check_pod_topology.sh [namespace]

set -euo pipefail

NAMESPACE="${1:-raj-network-debug}"

ALL_PODS=$(kubectl get pods -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

PODS=()
# Disagg pods
while IFS= read -r p; do
    [ -n "$p" ] && PODS+=("$p")
done < <(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice" || true)

# Agg pods
if [ ${#PODS[@]} -eq 0 ]; then
    while IFS= read -r p; do
        [ -n "$p" ] && PODS+=("$p")
    done < <(echo "$ALL_PODS" | grep "^ms-glm-agg-llm-d-modelservice" || true)
fi

if [ ${#PODS[@]} -eq 0 ]; then
    echo "No model server pods found in namespace $NAMESPACE"
    exit 1
fi

# Script to run inside each pod
read -r -d '' INNER_SCRIPT << 'INNEREOF' || true
#!/bin/bash

SEP="+--------+-----------------+------+--------+-----------------+------+-----------+"
HDR="| GPU ID | GPU PCI Address | NUMA | HCA    | HCA PCI Address | NUMA | Interface |"

# Collect GPUs
declare -a gpu_pcis
if command -v amd-smi &>/dev/null; then
    while IFS= read -r line; do
        if [[ "$line" =~ BDF:\ *([0-9a-fA-F:\.]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            [[ "$addr" =~ ^[0-9a-fA-F]{4}: ]] || addr="0000:$addr"
            gpu_pcis+=("$addr")
        fi
    done < <(amd-smi list 2>/dev/null || true)
elif command -v nvidia-smi &>/dev/null; then
    while IFS=',' read -r _ pci_addr; do
        pci_addr=$(echo "$pci_addr" | tr -d ' ' | sed 's/^0000//')
        [[ "$pci_addr" =~ ^[0-9a-fA-F]{4}: ]] || pci_addr="0000:$pci_addr"
        gpu_pcis+=("$pci_addr")
    done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null || true)
fi

if [ ${#gpu_pcis[@]} -eq 0 ]; then
    echo "  No GPUs detected"
    exit 0
fi

# Collect HCAs and their net interfaces
declare -A hca_pci hca_iface
for hca_path in /sys/class/infiniband/*; do
    [ ! -d "$hca_path" ] && continue
    name=$(basename "$hca_path")
    pci_link=$(readlink "$hca_path/device" 2>/dev/null || echo "")
    [ -z "$pci_link" ] && continue
    pci=$(basename "$pci_link")
    [[ "$pci" =~ ^[0-9a-fA-F]{4}: ]] || pci="0000:$pci"
    hca_pci[$name]="$pci"
    hca_iface[$name]=""
done

for iface_path in /sys/class/net/*; do
    [ ! -d "$iface_path" ] && continue
    iface_name=$(basename "$iface_path")
    [ "$iface_name" = "lo" ] || [ "$iface_name" = "eth0" ] && continue
    ib_path="$iface_path/device/infiniband"
    [ ! -d "$ib_path" ] && continue
    found_hca=$(ls "$ib_path" 2>/dev/null | head -n 1)
    [ -n "$found_hca" ] && hca_iface[$found_hca]="$iface_name"
done

get_numa() {
    local f="/sys/bus/pci/devices/$1/numa_node"
    [ -f "$f" ] && cat "$f" || echo "-1"
}

get_sysfs_root() {
    local p=$(readlink -f "/sys/bus/pci/devices/$1" 2>/dev/null)
    echo "$p" | grep -oE 'pci[0-9a-fA-F]{4}:[0-9a-fA-F]{2}' | head -1
}

get_distance() {
    local p1=$(readlink -f "/sys/bus/pci/devices/$1" 2>/dev/null)
    local p2=$(readlink -f "/sys/bus/pci/devices/$2" 2>/dev/null)
    [ -z "$p1" ] || [ -z "$p2" ] && { echo "9999"; return; }
    local IFS='/'
    local -a a1=($p1) a2=($p2)
    local len1=${#a1[@]} len2=${#a2[@]}
    local min=$len1; [ $len2 -lt $min ] && min=$len2
    local common=0 i=0
    while [ $i -lt $min ]; do
        [ "${a1[$i]}" = "${a2[$i]}" ] && common=$((common+1)) || break
        i=$((i+1))
    done
    echo $(( (len1-common) + (len2-common) ))
}

short() { echo "$1" | sed -E 's/^[0-9a-fA-F]{4}://'; }

# --- Section 1: All GPUs ---
echo ""
echo "GPUs (${#gpu_pcis[@]}):"
GPU_SEP="+--------+-----------------+------+"
GPU_HDR="| GPU ID | PCI Address     | NUMA |"
echo "$GPU_SEP"
echo "$GPU_HDR"
echo "$GPU_SEP"
for idx in "${!gpu_pcis[@]}"; do
    gpu_pci="${gpu_pcis[$idx]}"
    gpu_numa=$(get_numa "$gpu_pci")
    printf "| %-6s | %-15s | %-4s |\n" "GPU $idx" "$(short "$gpu_pci")" "$gpu_numa"
done
echo "$GPU_SEP"

# --- Section 2: All NICs ---
# Sort HCA names for consistent output
hca_sorted=($(echo "${!hca_pci[@]}" | tr ' ' '\n' | sort))
echo ""
echo "NICs (${#hca_sorted[@]}):"
NIC_SEP="+------------+-----------------+------+-----------+"
NIC_HDR="| HCA        | PCI Address     | NUMA | Interface |"
echo "$NIC_SEP"
echo "$NIC_HDR"
echo "$NIC_SEP"
for hca in "${hca_sorted[@]}"; do
    hpci="${hca_pci[$hca]}"
    hn=$(get_numa "$hpci")
    hi="${hca_iface[$hca]:-N/A}"
    printf "| %-10s | %-15s | %-4s | %-9s |\n" "$hca" "$(short "$hpci")" "$hn" "$hi"
done
echo "$NIC_SEP"

# --- Section 3: GPU-to-nearest-NIC mapping ---
echo ""
echo "GPU -> Nearest NIC mapping:"
MAP_SEP="+--------+-----------------+------------+-----------------+----------+"
MAP_HDR="| GPU ID | GPU PCI Address | Nearest NIC| NIC PCI Address | Distance |"
echo "$MAP_SEP"
echo "$MAP_HDR"
echo "$MAP_SEP"

for idx in "${!gpu_pcis[@]}"; do
    gpu_pci="${gpu_pcis[$idx]}"

    best_hca="" best_dist=999999
    for hca in "${!hca_pci[@]}"; do
        [ -z "${hca_iface[$hca]:-}" ] && continue
        d=$(get_distance "$gpu_pci" "${hca_pci[$hca]}")
        if [ "$d" -lt "$best_dist" ]; then
            best_dist=$d
            best_hca="$hca"
        fi
    done

    if [ -n "$best_hca" ]; then
        hpci="${hca_pci[$best_hca]}"
        printf "| %-6s | %-15s | %-10s | %-15s | %-8s |\n" \
            "GPU $idx" "$(short "$gpu_pci")" "$best_hca" "$(short "$hpci")" "$best_dist"
    else
        printf "| %-6s | %-15s | %-10s | %-15s | %-8s |\n" \
            "GPU $idx" "$(short "$gpu_pci")" "N/A" "N/A" "N/A"
    fi
done

echo "$MAP_SEP"
INNEREOF

for POD in "${PODS[@]}"; do
    # Determine role from pod name
    if [[ "$POD" == *"-prefill-"* ]]; then
        ROLE="prefill"
    elif [[ "$POD" == *"-decode-"* ]]; then
        ROLE="decode"
    else
        ROLE="agg"
    fi

    NODE=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.spec.nodeName}')

    echo ""
    echo "=============================================="
    echo "Pod:  $POD"
    echo "Role: $ROLE  |  Node: $NODE"
    echo "=============================================="

    kubectl exec -n "$NAMESPACE" "$POD" -c vllm -- bash -c "$INNER_SCRIPT" 2>/dev/null || \
        kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "$INNER_SCRIPT" 2>/dev/null || \
        echo "  (could not exec into pod)"
done
