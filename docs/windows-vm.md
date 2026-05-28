<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: windows-vm.md
     Description: Windows vm
     License: MIT
     ============================================================================== -->
# Windows VM Disk Operations

## Overview

The lxc-to-vm suite now supports Windows virtual machines for disk shrink, expand, and clone-replace operations. Windows VMs use NTFS filesystems, which require different tools than the Linux `e2fsck`/`resize2fs` path.

## Prerequisites

Install the required packages on your Proxmox host:

```bash
apt-get update && apt-get install -y libguestfs-tools ntfs-3g
```

Verify NTFS support in libguestfs:

```bash
virt-resize --help | grep -i ntfs
```

## Supported Operations

### Shrink Windows VM Disk

```bash
# Interactive mode (auto-detects Windows)
sudo ./shrink-vm.sh -v 100

# Non-interactive with custom headroom
sudo ./shrink-vm.sh -v 100 -g 5

# Dry-run preview
sudo ./shrink-vm.sh -v 100 --dry-run

# Force shrink below 30 GB minimum
sudo ./shrink-vm.sh -v 100 --force
```

**Note**: Windows VMs have a 30 GB safety minimum to accommodate Windows Update and temporary files. Use `--force` to override.

### Expand Windows VM Disk

```bash
# Offline expand to 200 GB
sudo ./expand-vm.sh -v 100 -s 200

# Add 50 GB to current size
sudo ./expand-vm.sh -v 100 -a 50

# Hot-expand while VM is running (requires QEMU guest agent inside Windows)
sudo ./expand-vm.sh -v 100 -s 200 --hot-expand
```

### Clone & Replace Windows Disk

```bash
# Clone Windows VM disk and expand to 300 GB
sudo ./clone-replace-disk.sh -t vm -i 100 -d scsi0 --size 300

# Clone to different storage
sudo ./clone-replace-disk.sh -t vm -i 100 -d scsi0 --size 300 -s zfspool

# Replace old disk after clone
sudo ./clone-replace-disk.sh -t vm -i 100 -d scsi0 --size 300 --remove-old
```

## OS Detection

All three scripts automatically detect Windows VMs using `libguestfs` inspection. If `libguestfs` is unavailable, they fall back to partition-type heuristics (`fdisk` / `file`).

You can override auto-detection with `--os-type windows` or `--os-type linux`.

## Tool Paths

| Operation | Primary Tool | Fallback Tool |
|-----------|-------------|---------------|
| Shrink | `virt-resize` (libguestfs) | `ntfsresize` |
| Expand (offline) | `virt-resize` (libguestfs) | `ntfsresize` |
| Expand (hot) | QEMU monitor `block_resize` | N/A |
| Clone | `virt-resize` (libguestfs) | `qemu-img convert` |

## Troubleshooting

### "libguestfs not available"

Install `libguestfs-tools` on the Proxmox host. The script will fall back to `ntfsresize`, which is less safe.

### "NTFS dirty flag detected"

The Windows VM was not shut down cleanly. Start the VM, run `chkdsk C: /f`, shut down cleanly, then retry.

### "QEMU guest agent not responding" during hot-expand

Ensure the QEMU guest agent service is running inside the Windows VM. Hot-expand will fall back to offline mode.

### "Minimum disk size 30 GB enforced"

Windows requires more space than Linux for updates and temporary files. Use `--force` with caution.

## Limitations

- BitLocker-encrypted disks are **not supported**
- ReFS filesystems are **not supported**
- Windows LXC containers are **not supported** (Proxmox LXC is Linux-only)
- In-place Windows OS activation or licensing changes are **not supported**
