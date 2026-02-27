#!/bin/bash

# GPU to HCA Mapping Script
# Finds PCIe topologically closest HCA for each GPU (AMD or NVIDIA)
# Only shows HCAs that have corresponding IP interfaces

set -e

# Colors for output (disabled if not tty)
if [ -t 1 ]; then
    BOLD='\033[1m'
    NC='\033[0m'
else
    BOLD=''
    NC=''
fi

# Function to get NUMA node for a PCI device
get_numa_node() {
    local pci_addr="$1"
    local numa_file="/sys/bus/pci/devices/$pci_addr/numa_node"
    if [ -f "$numa_file" ]; then
        cat "$numa_file"
    else
        echo "-1"
    fi
}

# Function to get the PCI path components (domain:bus:device.function)
parse_pci_addr() {
    local addr="$1"
    # Handle both formats: 0000:11:00.0 and 11:00.0
    if [[ "$addr" =~ ^[0-9a-fA-F]{4}: ]]; then
        echo "$addr"
    else
        echo "0000:$addr"
    fi
}

# Function to get PCI bus number from address (as decimal)
get_pci_bus() {
    local addr="$1"
    # Extract bus from 0000:XX:00.0 format and convert to decimal
    local bus_hex=$(echo "$addr" | sed -E 's/^[0-9a-fA-F]{4}:([0-9a-fA-F]{2}):.*/\1/')
    printf "%d" "0x$bus_hex" 2>/dev/null || echo "0"
}

# Function to find PCIe topological distance between two devices
# Returns the number of hops (lower = closer)
get_pci_distance() {
    local pci1="$1"
    local pci2="$2"
    
    # Get the upstream bridge/switch path for each device
    local path1=$(readlink -f "/sys/bus/pci/devices/$pci1" 2>/dev/null || echo "")
    local path2=$(readlink -f "/sys/bus/pci/devices/$pci2" 2>/dev/null || echo "")
    
    if [ -z "$path1" ] || [ -z "$path2" ]; then
        echo "9999"
        return
    fi
    
    # Count path components
    local IFS='/'
    local -a parts1=($path1)
    local -a parts2=($path2)
    
    local len1=${#parts1[@]}
    local len2=${#parts2[@]}
    local min_len=$len1
    [ $len2 -lt $min_len ] && min_len=$len2
    
    # Find common prefix length
    local common=0
    local i=0
    while [ $i -lt $min_len ]; do
        if [ "${parts1[$i]}" = "${parts2[$i]}" ]; then
            common=$((common + 1))
        else
            break
        fi
        i=$((i + 1))
    done
    
    # Distance = hops from pci1 to common ancestor + hops from common ancestor to pci2
    local distance=$(( (len1 - common) + (len2 - common) ))
    echo "$distance"
}

# Function to find network interface for an HCA
get_hca_interface() {
    local hca="$1"
    local iface=""
    
    # Search for network interface associated with this HCA
    for iface_path in /sys/class/net/*; do
        [ ! -d "$iface_path" ] && continue
        local iface_name=$(basename "$iface_path")
        [ "$iface_name" = "lo" ] && continue
        
        # Check if this interface has the HCA as its infiniband device
        local ib_path="$iface_path/device/infiniband"
        if [ -d "$ib_path" ]; then
            local found_hca=$(ls "$ib_path" 2>/dev/null | head -n 1)
            if [ "$found_hca" = "$hca" ]; then
                # Check if interface has an IP address
                if ip -4 addr show dev "$iface_name" 2>/dev/null | grep -q "inet "; then
                    echo "$iface_name"
                    return
                fi
            fi
        fi
    done
    
    echo ""
}

# Function to get short PCI address (without domain)
short_pci_addr() {
    local addr="$1"
    echo "$addr" | sed -E 's/^[0-9a-fA-F]{4}://'
}

# Collect all GPUs visible to this container/pod
declare -A gpu_pci_addrs
declare -a gpu_ids

gpu_idx=0

# Method 1: Try amd-smi for AMD GPUs (container-aware)
if command -v amd-smi &>/dev/null; then
    while IFS= read -r line; do
        if [[ "$line" =~ BDF:\ *([0-9a-fA-F:\.]+) ]]; then
            pci_addr="${BASH_REMATCH[1]}"
            pci_addr=$(parse_pci_addr "$pci_addr")
            gpu_pci_addrs[$gpu_idx]="$pci_addr"
            gpu_ids+=($gpu_idx)
            gpu_idx=$((gpu_idx + 1))
        fi
    done < <(amd-smi list 2>/dev/null || true)
fi

# Method 2: Try nvidia-smi for NVIDIA GPUs (container-aware)
if command -v nvidia-smi &>/dev/null && [ ${#gpu_ids[@]} -eq 0 ]; then
    while IFS=',' read -r idx pci_addr; do
        # nvidia-smi returns format like " 00000000:8B:00.0"
        pci_addr=$(echo "$pci_addr" | tr -d ' ' | sed 's/^0000//')
        pci_addr=$(parse_pci_addr "$pci_addr")
        gpu_pci_addrs[$gpu_idx]="$pci_addr"
        gpu_ids+=($gpu_idx)
        gpu_idx=$((gpu_idx + 1))
    done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null || true)
fi

# Method 3: Fallback - scan sysfs for GPUs (less accurate in containers)
if [ ${#gpu_ids[@]} -eq 0 ]; then
    for dev in /sys/bus/pci/devices/*; do
        [ ! -d "$dev" ] && continue
        vendor=$(cat "$dev/vendor" 2>/dev/null | sed 's/^0x//' || echo "")
        class=$(cat "$dev/class" 2>/dev/null || echo "")
        
        # AMD GPU: vendor 1002, display class (0x03xxxx) or processing accelerator (0x12xxxx)
        if [ "$vendor" = "1002" ] && [[ "$class" == 0x03* || "$class" == 0x12* ]]; then
            pci_addr=$(basename "$dev")
            if [ -d "$dev/drm" ] || [[ "$class" == 0x12* ]]; then
                gpu_pci_addrs[$gpu_idx]="$pci_addr"
                gpu_ids+=($gpu_idx)
                gpu_idx=$((gpu_idx + 1))
            fi
        fi
        
        # NVIDIA GPU: vendor 10de, display class or processing accelerator
        if [ "$vendor" = "10de" ] && [[ "$class" == 0x03* || "$class" == 0x12* ]]; then
            pci_addr=$(basename "$dev")
            if [ -d "$dev/drm" ] || [ -d "$dev/nvidia" ] || [[ "$class" == 0x12* ]]; then
                gpu_pci_addrs[$gpu_idx]="$pci_addr"
                gpu_ids+=($gpu_idx)
                gpu_idx=$((gpu_idx + 1))
            fi
        fi
    done
fi

# Method 4: Try lspci as last resort
if [ ${#gpu_ids[@]} -eq 0 ]; then
    while IFS= read -r line; do
        pci_addr=$(echo "$line" | awk '{print $1}')
        pci_addr=$(parse_pci_addr "$pci_addr")
        gpu_pci_addrs[$gpu_idx]="$pci_addr"
        gpu_ids+=($gpu_idx)
        gpu_idx=$((gpu_idx + 1))
    done < <(lspci -D | grep -iE '(VGA|3D|Display|Processing accelerator)' | grep -iE '(AMD|ATI|NVIDIA)' 2>/dev/null || true)
fi

if [ ${#gpu_ids[@]} -eq 0 ]; then
    echo "No GPUs found on this system."
    exit 1
fi

# Collect all HCAs with IP interfaces
declare -A hca_pci_addrs
declare -A hca_interfaces
declare -a hca_names

for hca_path in /sys/class/infiniband/*; do
    [ ! -d "$hca_path" ] && continue
    hca_name=$(basename "$hca_path")
    
    # Get PCI address
    pci_link=$(readlink "$hca_path/device" 2>/dev/null || echo "")
    if [ -z "$pci_link" ]; then
        continue
    fi
    pci_addr=$(basename "$pci_link")
    pci_addr=$(parse_pci_addr "$pci_addr")
    
    # Get interface (only if it has an IP)
    iface=$(get_hca_interface "$hca_name")
    
    hca_pci_addrs[$hca_name]="$pci_addr"
    hca_interfaces[$hca_name]="$iface"
    hca_names+=("$hca_name")
done

if [ ${#hca_names[@]} -eq 0 ]; then
    echo "No HCAs found on this system."
    exit 1
fi

# For each GPU, find the closest HCA(s) with IP interface
declare -A gpu_to_hcas
declare -A gpu_to_hca_distances

for gpu_id in "${gpu_ids[@]}"; do
    gpu_pci="${gpu_pci_addrs[$gpu_id]}"
    gpu_numa=$(get_numa_node "$gpu_pci")
    
    best_distance=999999
    best_hcas=()
    declare -A hca_distances
    
    for hca_name in "${hca_names[@]}"; do
        hca_pci="${hca_pci_addrs[$hca_name]}"
        hca_iface="${hca_interfaces[$hca_name]}"
        
        # Skip HCAs without IP interface
        [ -z "$hca_iface" ] && continue
        
        hca_numa=$(get_numa_node "$hca_pci")
        
        # Calculate distance (PCIe hops - lower = closer)
        distance=$(get_pci_distance "$gpu_pci" "$hca_pci")
        
        # Add penalty for different NUMA node
        if [ "$gpu_numa" != "$hca_numa" ] || [ "$gpu_numa" = "-1" ]; then
            distance=$((distance + 100))
        fi
        
        hca_distances[$hca_name]=$distance
        
        if [ $distance -lt $best_distance ]; then
            best_distance=$distance
            best_hcas=("$hca_name")
        elif [ $distance -eq $best_distance ]; then
            best_hcas+=("$hca_name")
        fi
    done
    
    gpu_to_hcas[$gpu_id]="${best_hcas[*]}"
    # Store distances for each HCA
    for hca in "${best_hcas[@]}"; do
        gpu_to_hca_distances["${gpu_id}:${hca}"]="${hca_distances[$hca]}"
    done
    unset hca_distances
done

# Print the table
print_separator() {
    printf "+--------+-----------------+-----------------------------+-----------+------------+\n"
}

print_header() {
    printf "| %-6s | %-15s | %-27s | %-9s | %-10s |\n" "GPU ID" "GPU PCI Address" "Nearest HCA PCI Addr (dist)" "Interface" "HCA Device"
}

print_row() {
    local gpu_id="$1"
    local gpu_pci="$2"
    local hca_pci="$3"
    local iface="$4"
    local hca_name="$5"
    printf "| %-6s | %-15s | %-27s | %-9s | %-10s |\n" "$gpu_id" "$gpu_pci" "$hca_pci" "$iface" "$hca_name"
}

print_separator
print_header
print_separator

for gpu_id in "${gpu_ids[@]}"; do
    gpu_pci="${gpu_pci_addrs[$gpu_id]}"
    gpu_pci_short=$(short_pci_addr "$gpu_pci")
    
    hcas="${gpu_to_hcas[$gpu_id]}"
    
    if [ -z "$hcas" ]; then
        print_row "GPU $gpu_id" "$gpu_pci_short" "N/A" "N/A" "N/A"
    else
        first=true
        for hca_name in $hcas; do
            hca_pci="${hca_pci_addrs[$hca_name]}"
            hca_pci_short=$(short_pci_addr "$hca_pci")
            hca_iface="${hca_interfaces[$hca_name]}"
            distance="${gpu_to_hca_distances[${gpu_id}:${hca_name}]}"
            hca_with_dist="${hca_pci_short} (${distance})"
            
            if $first; then
                print_row "GPU $gpu_id" "$gpu_pci_short" "$hca_with_dist" "$hca_iface" "$hca_name"
                first=false
            else
                # Additional HCAs for same GPU (same distance)
                print_row "" "" "$hca_with_dist" "$hca_iface" "$hca_name"
            fi
        done
    fi
done

print_separator
