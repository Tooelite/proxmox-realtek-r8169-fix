# proxmox-realtek-r8169-fix

Workaround scripts to **stabilize and speed up networking on Proxmox VE 8/9** hosts that use a **Realtek RTL8111/8168/8411** NIC driven by the **r8169** kernel driver.

The project:
- Disables fragile NIC offloads (TSO/GSO/GRO/LRO, RX/TX checksum) **on the Proxmox host** for the chosen interface (e.g. `enp1s0`).
- Installs a templated **systemd unit** so settings persist across reboots: `disable-offloads@<iface>.service`.
- Can optionally append **`pcie_aspm=off`** to GRUB and run `update-grub` to disable PCIe-ASPM (often implicated in Realtek instability).
- Ships **verify** and **uninstall/rollback** helpers.

> ⚠️ This operates on the **host** (Debian bookworm/trixie base under Proxmox VE). It does **not** modify guests and does **not** build `r8168-dkms`.

---

## Symptoms this fix targets

- Upload **to** VMs is very slow (SFTP/SMB/HTTP), while downloads look fine or only slightly degraded.
- Many TCP **retransmissions** / duplicate ACKs under real workloads.
- `iperf3` forward looks okay, but protocols collapse under sustained TX load to a bridged VM.
- Occasionally kernel messages like:
  ```
  NETDEV WATCHDOG: enp1s0 (r8169): transmit queue timed out
  r8169 ... rtl_ocp_read_cond ... failed
  ```

**Root causes mitigated:**
- Buggy/fragile Realtek offload features with Linux bridges & KVM (segmentation/checksum offloads).
- **PCIe ASPM** power saving causing latency spikes / packet loss on Realtek controllers.

---

## Requirements

- Proxmox VE **8 or 9** host, root shell.
- Realtek NIC bound to `r8169` (e.g. PCI ID `10ec:8168`).

Check:
```bash
lspci -nnk | grep -A3 Ethernet
# … should show RTL8111/8168/8411 and: Kernel driver in use: r8169
```

---

## Quick start

```bash
# 1) Put this project somewhere on the host
mkdir -p /root/proxmox-realtek-r8169-fix && cd /root/proxmox-realtek-r8169-fix
unzip proxmox-realtek-r8169-fix-full.zip
chmod +x bin/*.sh

# 2) Install (auto-detects the first r8169 iface); add --iface enp1s0 to be explicit
bash bin/install.sh --grub

# 3) Verify
bash bin/verify.sh

# 4) Reboot recommended (to apply ASPM change)
reboot
```

**Notes**
- Use `--no-grub` to skip GRUB changes. You can later run `bin/install.sh --iface enp1s0 --grub` to add ASPM.
- The systemd unit is **templated**; if you have multiple Realtek ports, enable one instance per iface:
  ```bash
  systemctl enable --now disable-offloads@enp1s0.service
  systemctl enable --now disable-offloads@enp2s0.service
  ```

---

## Rollback

```bash
bash bin/uninstall.sh --iface enp1s0 --grub   # removes unit, tries to re-enable offloads, and drops pcie_aspm=off
update-grub && reboot
```

---

## What exactly gets installed?

```
/usr/local/sbin/realtek-offloads.sh        # helper that disables all offloads on the given iface
/etc/systemd/system/disable-offloads@.service  # templated oneshot unit calling the helper
```

The installer also **applies the offload settings immediately** (no reboot required for that part) and optionally patches `/etc/default/grub` to add `pcie_aspm=off` followed by `update-grub`.

---

## File tree

```
.
├─ README.md
├─ bin/
│  ├─ install.sh       # main installer (idempotent)
│  ├─ verify.sh        # driver/offload/ASPM status
│  └─ uninstall.sh     # rollback
└─ systemd/
   └─ disable-offloads@.service
```

---

## Security & Data Integrity FAQ

**Q: Is disabling RX/TX checksum / TSO/GSO/GRO/LRO dangerous?**  
**A:** No. It moves segmentation and checksumming from the NIC hardware to the Linux kernel (software). Data integrity is preserved; CPU cost at 1 Gbit/s is negligible on modern CPUs. In practice you get **more reliable** transfers because buggy hardware offloads no longer corrupt/fragment frames.

**Q: Why not install `r8168-dkms`?**  
**A:** DKMS adds maintenance overhead and can break on kernel updates. The offload+ASPM workaround is simple, robust, and sufficient for 1 Gbit/s. If you need a long‑term clean solution, consider a small **Intel I210/I350** PCIe NIC.

**Q: Does this affect guests?**  
**A:** No changes inside VMs. The fix is on the host NIC; guests benefit automatically via the bridge (`vmbr0`).

---

## Troubleshooting

- Verify the active settings:
  ```bash
  bin/verify.sh enp1s0
  # check: offload flags show 'off'; /proc/cmdline contains pcie_aspm=off; dmesg shows 'PCIe ASPM is disabled'
  ```
- If the NIC name differs (`ip link`), pass it explicitly: `--iface <name>`.
- If you still see timeouts/retransmits after the fix:
  - Ensure **virtio-net** in the VM, not e1000/rtl8139.
  - Check Windows AV on the client (downloads often bottleneck due to on-access scanning).
  - Consider swapping the Realtek NIC for an **Intel** card.

---

## License

MIT
