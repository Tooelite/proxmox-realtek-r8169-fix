#!/usr/bin/env bash
set -euo pipefail

# proxmox-realtek-r8169-fix — installer
# - Disables NIC offloads now
# - Installs templated systemd unit disable-offloads@.service and enables instance
# - Optionally appends pcie_aspm=off to GRUB

usage() {
  cat <<USAGE
Usage: $0 [--iface IFACE] [--grub] [--no-grub] [--dry-run]

Options:
  --iface IFACE   Interface to fix (e.g. enp1s0). Auto-detects first r8169 if omitted.
  --grub          Ensure GRUB has pcie_aspm=off and run update-grub.
  --no-grub       Do not touch GRUB even if recommended.
  --dry-run       Show actions without applying changes.
USAGE
}
log() { printf "\033[1m[%s]\033[0m %s\n" "$(date +%F\ %T)" "$*"; }
err() { printf "\033[31mERROR:\033[0m %s\n" "$*" 1>&2; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root"; exit 1; }; }
cmd() { local c=("$@"); if [[ ${DRY_RUN:-0} -eq 1 ]] == 1; then echo "+ ${c[*]}"; else "${c[@]}"; fi }

IFACE=""
WANT_GRUB=auto
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE=${2:-}; shift 2;;
    --grub)  WANT_GRUB=yes; shift;;
    --no-grub) WANT_GRUB=no; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

need_root

auto_detect_iface() {
  local n
  for n in /sys/class/net/*; do
    n=${n##*/}
    [[ $n =~ ^(lo|vmbr.*|veth.*|fwbr.*|fwpr.*|fwln.*|tap.*)$ ]] && continue
    if ethtool -i "$n" 2>/dev/null | grep -q '^driver: r8169'; then
      echo "$n"; return 0
    fi
  done
  return 1
}

if [[ -z "$IFACE" ]]; then
  IFACE=$(auto_detect_iface || true)
  [[ -n "$IFACE" ]] || { err "Could not auto-detect r8169 interface. Use --iface enp1s0"; exit 3; }
fi

[[ -e /sys/class/net/$IFACE ]] || { err "Interface $IFACE not found"; exit 4; }

if ! ethtool -i "$IFACE" | grep -q '^driver: r8169'; then
  log "WARN: $IFACE is not r8169 — proceeding anyway (requested)."
fi

log "Target interface: $IFACE"
log "Disabling offloads (tso/gso/gro/lro/rx/tx) on $IFACE"
cmd ethtool -K "$IFACE" tso off gso off gro off lro off rx off tx off || true

HELPER=/usr/local/sbin/realtek-offloads.sh
if [[ ! -f $HELPER ]]; then
  log "Installing helper $HELPER"
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    echo "+ install -Dm0755 /dev/stdin $HELPER <<'SH' ..."
  else
    install -Dm0755 /dev/stdin "$HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFACE=${1:?usage: realtek-offloads.sh <iface>}
for i in {1..60}; do
  [[ -e "/sys/class/net/$IFACE" ]] && break
  sleep 1
  [[ $i -eq 60 ]] && { echo "iface $IFACE not present" >&2; exit 1; }
done
/sbin/ethtool -K "$IFACE" tso off gso off gro off lro off rx off tx off || true
/sbin/ethtool -k "$IFACE" | egrep 'rx-checksumming|tx-checksumming|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload' || true
SH
  fi
else
  log "Helper already present: $HELPER"
fi

UNIT_SRC_DIR=$(dirname "$0")/../systemd
UNIT_DST=/etc/systemd/system/disable-offloads@.service
if [[ ! -f $UNIT_DST ]]; then
  log "Installing systemd unit $UNIT_DST"
  cmd install -Dm0644 "$UNIT_SRC_DIR/disable-offloads@.service" "$UNIT_DST"
else
  log "Unit already present: $UNIT_DST"
fi

log "Enable + start instance: disable-offloads@${IFACE}.service"
cmd systemctl daemon-reload
cmd systemctl enable --now "disable-offloads@${IFACE}.service"
cmd systemctl is-active "disable-offloads@${IFACE}.service"

maybe_patch_grub() {
  local cfg=/etc/default/grub
  [[ -f $cfg ]] || { err "$cfg missing"; return 1; }
  if grep -q 'pcie_aspm=off' "$cfg"; then
    log "GRUB already contains pcie_aspm=off"
    return 0
  fi
  log "Appending pcie_aspm=off to GRUB_CMDLINE_LINUX_DEFAULT"
  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    echo "+ sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=\\\"[^\\\"]*)\\\"/\\1 pcie_aspm=off\\\"/' $cfg"
  else
    install -m0644 "$cfg" "${cfg}.bak.$(date +%F-%H%M%S)"
    sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 pcie_aspm=off\"/' "$cfg"
    update-grub
  fi
}

case "$WANT_GRUB" in
  yes) maybe_patch_grub;;
  no)  log "Skipping GRUB changes (per --no-grub)";;
  auto) log "Hint: run with --grub to add pcie_aspm=off (recommended for Realtek).";;
esac

log "Done. You can verify with: bin/verify.sh"
[[ "$WANT_GRUB" == yes ]] && log "Reboot recommended to apply ASPM setting."
