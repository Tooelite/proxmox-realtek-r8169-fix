#!/usr/bin/env bash
set -euo pipefail

usage(){ echo "Usage: $0 --iface IFACE [--grub]"; }
IFACE=""; WANT_GRUB=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE=${2:-}; shift 2;;
    --grub) WANT_GRUB=yes; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done
[[ -n "$IFACE" ]] || { usage; exit 1; }

systemctl disable --now "disable-offloads@${IFACE}.service" || true
rm -f "/etc/systemd/system/disable-offloads@.service" || true
systemctl daemon-reload || true

/sbin/ethtool -K "$IFACE" rx on tx on tso on gso on gro on 2>/dev/null || true

if [[ "$WANT_GRUB" == yes ]]; then
  CFG=/etc/default/grub
  if grep -q 'pcie_aspm=off' "$CFG"; then
    cp "$CFG" "${CFG}.bak.$(date +%F-%H%M%S)"
    sed -i -E 's/(pcie_aspm=off) ?//g' "$CFG"
    update-grub
    echo "Removed pcie_aspm=off from GRUB; reboot recommended"
  fi
fi

echo "Uninstall complete."
