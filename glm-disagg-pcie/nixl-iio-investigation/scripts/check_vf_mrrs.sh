#!/usr/bin/env bash
# Investigate and attempt to modify VF Max Read Request Size (MRRS).
#
# Background:
#   ConnectX-7 SR-IOV VFs have MRRS=128B (PCIe default), while PFs have
#   MRRS=4096B. A larger MRRS means more bytes in flight per PCIe tag,
#   increasing the NIC-side bandwidth-delay product.
#
# Findings:
#   1. VF DevCtl register is virtualized by ConnectX-7 firmware
#   2. setpci writes are silently dropped (from both pod and host)
#   3. PF with MRRS=4096B achieves identical throughput to VF with MRRS=128B
#      for contiguous memory access (ib_read_bw), ruling out MRRS as the
#      primary bottleneck
#   4. Changing VF MRRS would require kernel driver patches (mlx5 pci_set_readrq)
#      or firmware configuration changes
#
# Usage:
#   Run from inside a pod with VF NIC access, or SSH to the host node.

set -euo pipefail

echo "=============================================="
echo "VF MRRS Investigation"
echo "=============================================="

echo ""
echo "=== Step 1: List all Mellanox VF devices and their MRRS ==="
echo ""

for dev in /sys/class/infiniband/mlx5_*; do
    DEV_NAME=$(basename "$dev")
    PCI_DEV=$(basename "$(readlink -f "$dev/device")")
    MRRS=$(lspci -vvs "$PCI_DEV" 2>/dev/null | grep -o 'MaxReadReq [0-9]* bytes' || echo "N/A")
    DEVCTL=$(setpci -s "$PCI_DEV" CAP_EXP+8.W 2>/dev/null || echo "N/A")
    echo "  $DEV_NAME ($PCI_DEV): $MRRS, DevCtl=0x$DEVCTL"
done

echo ""
echo "=== Step 2: Attempt to increase MRRS via setpci ==="
echo ""
echo "PCIe Device Control Register (DevCtl) layout:"
echo "  Bits [14:12] = Max Read Request Size"
echo "    000 = 128B   001 = 256B   010 = 512B"
echo "    011 = 1024B  100 = 2048B  101 = 4096B"
echo ""
echo "To set MRRS=4096B: write 0x5000 to DevCtl (bits 14:12 = 101)"
echo "  setpci -s <BDF> CAP_EXP+8.W=5000"
echo ""

if [ "${1:-}" = "--try-write" ]; then
    TARGET_BDF="${2:?Usage: $0 --try-write <BDF>}"
    echo "Attempting to set MRRS=4096B on $TARGET_BDF..."

    echo "  Before: DevCtl = 0x$(setpci -s "$TARGET_BDF" CAP_EXP+8.W)"
    setpci -s "$TARGET_BDF" CAP_EXP+8.W=5000 2>&1 || echo "  setpci write failed"
    echo "  After:  DevCtl = 0x$(setpci -s "$TARGET_BDF" CAP_EXP+8.W)"

    echo ""
    echo "If Before == After, the write was silently dropped."
    echo "This confirms VF DevCtl is virtualized by the NIC firmware."
else
    echo "To attempt a write, run: $0 --try-write <BDF>"
    echo "(Expected result: write is silently dropped for VFs)"
fi

echo ""
echo "=== Step 3: Compare PF vs VF performance ==="
echo ""
echo "Use ib_read_bw with PF NIC (MRRS=4096B) vs VF NIC (MRRS=128B)."
echo "For contiguous GPU memory (single buffer), they show identical throughput,"
echo "confirming MRRS is not the bottleneck for contiguous access."
echo ""
echo "PF config example:"
echo "  networking-debug-pod pods use PF NICs (mlx5_0..mlx5_9)"
echo "  MRRS = 4096 bytes"
echo ""
echo "VF config example:"
echo "  test-nic-pcie pods use VF NICs (mlx5_12..mlx5_17)"
echo "  MRRS = 128 bytes (firmware-locked)"
echo ""
echo "=== Conclusion ==="
echo ""
echo "VF MRRS cannot be modified at runtime. The ConnectX-7 firmware"
echo "virtualizes the DevCtl register for VFs, silently dropping writes."
echo "Changing MRRS would require either:"
echo "  1. mlx5 kernel driver patch to call pci_set_readrq() for VFs"
echo "  2. ConnectX-7 firmware configuration change"
echo "  3. Use PF NICs instead (not always possible in multi-tenant environments)"
echo ""
echo "However, since PF (MRRS=4096B) and VF (MRRS=128B) show identical"
echo "throughput for contiguous memory access, MRRS is unlikely to be the"
echo "primary bottleneck for scattered access patterns either."
