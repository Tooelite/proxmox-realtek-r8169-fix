#!/usr/bin/env bash
set -euo pipefail

IFACE=${1:-}
if [[ -z "$IFACE" ]]; then
  for n in /sys/class/net/*; do
    n=${n##*/}
    [[ $n =~ ^(lo|vmbr.*|veth.*|fwbr.*|fwpr.*|fwln.*|tap.*)$ ]] && continue
    if ethtool -i "$n" 2>/dev/null | grep -q '^driver: r8169'; then IFACE=$n; break; fi
  done
fi

[[ -n "$IFACE" ]] || { echo "Usage: $0 <iface>  (or auto-detects first r8169)"; exit 1; }

printf "\n=== Interface & driver ===\n"
ethtool -i "$IFACE" || true

printf "\n=== Offload flags (%s) ===\n" "$IFACE"
ethtool -k "$IFACE" | egrep 'rx-checksumming|tx-checksumming|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload' || true

printf "\n=== Kernel cmdline (ASPM) ===\n"
cat /proc/cmdline | sed 's/ \+/\n/g' | egrep 'pcie_aspm|BOOT_IMAGE|root' || true

echo -e "\n=== dmesg ASPM ==="
dmesg | grep -i aspm || true
