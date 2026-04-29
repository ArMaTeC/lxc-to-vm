# Troubleshooting Guide

Common issues and solutions for the Proxmox LXC ↔️ VM Converter suite.

---

## Table of Contents

1. [General Issues](#general-issues)
2. [lxc-to-vm.sh Issues](#lxc-to-vmsh-issues)
3. [vm-to-lxc.sh Issues](#vm-to-lxcsh-issues)
4. [expand-lxc.sh Issues](#expand-lxcsh-issues)
5. [expand-vm.sh Issues](#expand-vmsh-issues)
6. [shrink-vm.sh Issues](#shrink-vmsh-issues)
7. [clone-replace-disk.sh Issues](#clone-replace-disksh-issues)
8. [Network Issues](#network-issues)
9. [Disk/Storage Issues](#diskstorage-issues)
10. [Permission Issues](#permission-issues)
11. [Debug Mode](#debug-mode)
12. [Getting Help](#getting-help)

---

## General Issues

### Script Not Found

**Problem:**

```bash
./lxc-to-vm.sh: command not found
```

**Solution:**

```bash
# Check if file exists
ls -la lxc-to-vm.sh

# Make executable
chmod +x lxc-to-vm.sh

# Run with full path
sudo ./lxc-to-vm.sh
```

### Dependency Missing

**Problem:**

```bash
ERROR: Missing required dependency: qemu-img
```

**Solution:**

```bash
# Install dependencies (auto-installed on first run, or manually)
apt-get update
apt-get install -y rsync qemu-utils parted kpartx libguestfs-tools curl jq
```

### Permission Denied

**Problem:**

```bash
Permission denied
```

**Solution:**

```bash
# Run as root
sudo ./lxc-to-vm.sh ...

# Or ensure you're root
whoami  # should show 'root'
```

---

## lxc-to-vm.sh Issues

### VM Won't Boot

**Symptoms:** VM starts but gets stuck at boot screen

**Diagnosis:**

```bash
# Check VM config
qm config 200

# Check disk attached correctly
qm config 200 | grep -E '^(scsi|virtio|ide|sata)'

# View serial console
qm console 200

# Check logs
cat /var/log/lxc-to-vm.log | tail -100
```

**Solutions:**

1. **Bootloader not installed:**

```bash
# Remount disk and reinstall grub
qm stop 200
# Mount disk
# chroot /mnt/disk
# grub-install /dev/sda
# update-grub
```

1. **Wrong boot mode:**

```bash
# Try UEFI instead of BIOS
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --uefi
```

### Disk Space Error

**Symptoms:** Conversion fails with "insufficient disk space"

**Diagnosis:**

```bash
# Check available space
pvesm status | grep local-lvm
df -h
```

**Solutions:**

1. **Shrink container first:**

```bash
sudo ./shrink-lxc.sh -c 100 --resize
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm
```

1. **Specify smaller disk:**

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 5G
```

1. **Use different storage:**

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s other-storage
```

### Container Not Found

**Symptoms:** "Container 100 does not exist"

**Diagnosis:**

```bash
# List containers
pct list

# Check specific container
pct config 100
```

**Solution:**

Verify correct CTID and container exists on current node.

### Health Check Failed

**Symptoms:** "Post-conversion health check failed"

**Diagnosis:**

```bash
# Check VM status
qm status 200
qm log 200

# Try starting manually
qm start 200
qm console 200
```

**Solutions:**

1. **Check QEMU agent:**

```bash
qm guest exec 200 -- /bin/hostname
```

1. **Manual fix and retry:**

```bash
# Fix boot issue manually
# Then re-run conversion with --resume
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --resume
```

---

## vm-to-lxc.sh Issues

### Container Doesn't Start

**Symptoms:** Container created but won't start

**Diagnosis:**

```bash
# Check container config
pct config 100

# Check rootfs
pct config 100 | grep rootfs

# Try starting with debug
pct start 100 --debug
```

**Solutions:**

1. **Check filesystem:**

```bash
# Verify rootfs exists
ls -la $(pct config 100 | grep rootfs | awk '{print $2}')

# Check for corruption
pct fsck 100
```

1. **Reconfigure network:**

```bash
# Check network config
pct config 100 | grep net0

# Fix if needed
pct set 100 --net0 name=eth0,bridge=vmbr0,ip=dhcp
```

### No Network in Container

**Symptoms:** Container starts but no network connectivity

**Diagnosis:**

```bash
# Check network inside container
pct exec 100 -- ip a
pct exec 100 -- cat /etc/network/interfaces 2>/dev/null || \
  pct exec 100 -- ls /etc/netplan/
```

**Solutions:**

1. **Netplan issues (Ubuntu):**

```bash
pct exec 100 -- netplan apply
```

1. **Interface naming:**

```bash
# If --keep-network was used, interface may be ens18
# Either rename or reconfigure:
pct set 100 --net0 name=ens18,bridge=vmbr0,ip=dhcp
```

### VM Disk Not Detected

**Symptoms:** "No disk found for VM 200"

**Diagnosis:**

```bash
# Check VM disk config
qm config 200 | grep -E '^(scsi|virtio|ide|sata)0:'

# Check if disk exists
pvesm path local-lvm:vm-200-disk-0
```

**Solutions:**

1. **Use different disk:**

```bash
# If virtio0 doesn't exist, check for scsi0, ide0, etc.
# Script checks in order: virtio0, scsi0, ide0, sata0
```

1. **Manual disk specification:**

Edit script or convert disk manually first.

### NBD Module Issues

**Symptoms:** "Failed to setup NBD device"

**Diagnosis:**

```bash
# Check NBD module
lsmod | grep nbd

# Check available devices
ls /dev/nbd*
```

**Solution:**

```bash
# Load NBD module
modprobe nbd max_part=8

# Make persistent
echo "nbd" >> /etc/modules
```

---

## expand-lxc.sh Issues

### Container size did not change after expansion

**Symptoms:** `expand-lxc.sh` reports success but `df -h` inside the container shows old size.

**Diagnosis:**

```bash
# Check the rootfs config
pct config <CTID> | grep rootfs

# Check actual LV/volume size
pvesm path <storage>:<volume>
```

**Solutions:**

1. **Filesystem not resized (QCOW2 without qemu-nbd):**

```bash
# Install qemu-utils for qemu-nbd support
apt install qemu-utils

# Then re-run expansion
sudo ./expand-lxc.sh -c 100 -s 100
```

1. **Use clone-replace-disk for a fresh expansion:**

```bash
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 100
```

### Insufficient pool space

**Symptoms:** `E_NO_SPACE` error or LVM/ZFS resize failure.

**Diagnosis:**

```bash
pvesm status
vgs        # For LVM
zpool list # For ZFS
```

**Solution:** Use `--max` mode with a safety margin, or free space in the pool first.

### Hot-expand: container reports old size after --no-restart

**Symptoms:** `--no-restart` used but filesystem not growing.

**Solution:** The filesystem resize happens inside the container. After hot-expand completes, verify:

```bash
pct exec <CTID> -- resize2fs /dev/sda2
pct exec <CTID> -- df -h /
```

---

## expand-vm.sh Issues

### VM filesystem not showing new size after expansion

**Symptoms:** `expand-vm.sh` completes but `df -h` inside VM shows old size.

**Explanation:** `expand-vm.sh` expands the disk at the Proxmox/storage level. The filesystem inside the VM must be resized manually (or the OS must support auto-grow via cloud-init/growpart).

**Solution:**

```bash
# Inside the VM
growpart /dev/sda 1         # Expand the partition
resize2fs /dev/sda1         # Resize ext4 filesystem
# For XFS:
xfs_growfs /                # Resize XFS filesystem
```

### Hot-expand not working (--hot-expand)

**Symptoms:** QEMU monitor command fails or VM doesn't see new size.

**Diagnosis:**

```bash
# Check qemu-guest-agent is running inside VM
qm agent <VMID> ping

# View expand-vm log
tail -50 /var/log/expand-vm.log
```

**Solutions:**

1. **Without hot-expand (safer):** Stop VM, expand, restart:

```bash
sudo ./expand-vm.sh -v 100 -s 200
```

1. **Ensure QEMU guest agent is installed** inside the VM:

```bash
# Debian/Ubuntu
apt install qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

---

## shrink-vm.sh Issues

### Filesystem shrink failed

**Symptoms:** `resize2fs` error, or `Filesystem shrink failed` message.

**Diagnosis:**

```bash
tail -80 /var/log/shrink-vm.log
```

**Solutions:**

1. **Increase headroom:**

```bash
sudo ./shrink-vm.sh -v 100 -g 10
```

1. **Use libguestfs for safer shrink:**

```bash
apt install libguestfs-tools
sudo ./shrink-vm.sh -v 100 -u
```

1. **Run filesystem check manually first:**

```bash
# Mount disk and run e2fsck
qm stop 100
# Identify disk path
qm config 100 | grep -E '^(scsi|virtio|ide)0'
pvesm path local-lvm:vm-100-disk-0
e2fsck -f -y /dev/pve/vm-100-disk-0
```

### Shrink reports disk is already optimal

**Symptoms:** `Disk is already optimal size. No shrink needed.`

This is not an error — the calculated target (usage + margin + headroom) is already equal to or larger than the current disk. Reduce headroom or free space inside the VM first.

### Usage detection returned 50% estimate

**Symptoms:** Warning: `Could not determine actual usage. Estimating X GB (50% of current).`

**Solution:** Install `libguestfs-tools` for accurate measurement:

```bash
apt install libguestfs-tools
sudo ./shrink-vm.sh -v 100
```

---

## clone-replace-disk.sh Issues

### Clone failed: LVM volume creation error

**Symptoms:** `Failed to create LVM volume` or `lvcreate` error.

**Diagnosis:**

```bash
vgs   # Check VG free space
lvs   # List existing volumes
```

**Solution:** Free space in the VG or target a different storage with more space:

```bash
sudo ./clone-replace-disk.sh -t lxc -i 100 -s other-storage --size 200
```

### Old disk not removed after --remove-old

**Symptoms:** Script reports old disk removed, but `pvesm status` still shows it.

**Solution:** Remove manually using `pvesm free`:

```bash
pvesm free local-lvm:vm-100-disk-0
```

### VM/Container won't start after disk replace

**Symptoms:** VM/container fails to start with new disk.

**Diagnosis:**

```bash
# Check new disk is attached
qm config <VMID> | grep -E '^(scsi|virtio|ide)0'
pct config <CTID> | grep rootfs
```

**Recovery:** Roll back to old disk (kept by default):

```bash
# For VM
qm set <VMID> --scsi0 <old-disk-ref>,size=<N>G

# For LXC
pct set <CTID> --rootfs <old-disk-ref>,size=<N>G
```

---

## Network Issues

### Bridge Not Found

**Symptoms:** "Bridge vmbr0 does not exist"

**Solution:**

```bash
# List available bridges
ip link show type bridge

# Use existing bridge
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -b vmbr1
```

### Wrong IP After Conversion

**Problem:** VM/container gets different IP than expected

**Solutions:**

1. **Use static IP:**

```bash
# For VMs
qm set 200 --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1

# For containers
pct set 100 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.100/24,gw=192.168.1.1
```

1. **Preserve MAC address:**

```bash
# Get original MAC
pct config 100 | grep net0

# Set on new VM
qm set 200 --net0 virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0
```

---

## Disk/Storage Issues

### Storage Not Found

**Symptoms:** "Storage 'local-lvm' does not exist"

**Diagnosis:**

```bash
# List storage
pvesm status

# Check specific storage
pvesm path local-lvm
```

**Solution:**

```bash
# Use available storage
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local
```

### Import Failed

**Symptoms:** "Failed to import disk to Proxmox"

**Diagnosis:**

```bash
# Check disk image
qemu-img info /var/lib/vz/dump/vm-200-disk.raw

# Check storage space
pvesm status | grep local-lvm
```

**Solutions:**

1. **Check image integrity:**

```bash
qemu-img check /var/lib/vz/dump/vm-200-disk.raw
```

1. **Use different storage:**

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s other-storage
```

---

## Permission Issues

### Permission Denied on Hooks

**Symptoms:** "Hook execution failed: Permission denied"

**Solution:**

```bash
# Fix hook permissions
chmod +x /var/lib/lxc-to-vm/hooks/*
chown root:root /var/lib/lxc-to-vm/hooks/*
```

### API Permission Denied

**Symptoms:** "API call failed: 403 Forbidden"

**Solution:**

1. Check API token permissions
2. Ensure token has required privileges:
   - `VM.Audit`, `VM.Config.Disk`
   - `Datastore.AllocateSpace`
   - `Sys.Modify` (for migration)

---

## Debug Mode

Each script has a dedicated debug environment variable and log file:

| Script | Debug Variable | Log File |
| ------ | -------------- | -------- |
| `lxc-to-vm.sh` | `DEBUG=1` | `/var/log/lxc-to-vm.log` |
| `vm-to-lxc.sh` | `DEBUG=1` | `/var/log/vm-to-lxc.log` |
| `shrink-lxc.sh` | `SHRINK_LXC_DEBUG=1` | `/var/log/shrink-lxc.log` |
| `expand-lxc.sh` | `EXPAND_LXC_DEBUG=1` | `/var/log/expand-lxc.log` |
| `shrink-vm.sh` | `SHRINK_VM_DEBUG=1` | `/var/log/shrink-vm.log` |
| `expand-vm.sh` | `EXPAND_VM_DEBUG=1` | `/var/log/expand-vm.log` |
| `clone-replace-disk.sh` | `CLONE_REPLACE_DEBUG=1` | `/var/log/clone-replace-disk.log` |

### Enable debug for a specific script

```bash
# lxc-to-vm
DEBUG=1 sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm

# expand-lxc
EXPAND_LXC_DEBUG=1 sudo ./expand-lxc.sh -c 100 -a 20

# shrink-vm
SHRINK_VM_DEBUG=1 sudo ./shrink-vm.sh -v 100

# expand-vm
EXPAND_VM_DEBUG=1 sudo ./expand-vm.sh -v 100 -s 200

# clone-replace-disk
CLONE_REPLACE_DEBUG=1 sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200
```

### View logs in real time

```bash
tail -f /var/log/lxc-to-vm.log
tail -f /var/log/expand-lxc.log
tail -f /var/log/shrink-vm.log
tail -f /var/log/expand-vm.log
tail -f /var/log/clone-replace-disk.log
```

---

## Getting Help

If issues persist:

1. **Check the relevant log file** (see [Debug Mode](#debug-mode) for full list)
2. **Run with `--dry-run`:** Preview without making changes
3. **Test with `--validate-only`:** Check pre-flight conditions (lxc-to-vm / vm-to-lxc)
4. **Create issue:** Report on GitHub with:
   - Script version (`--version`)
   - Proxmox version (`pveversion`)
   - Full error message
   - Relevant log excerpts

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - LXC to VM guide
- **[vm-to-lxc.sh](vm-to-lxc)** - VM to LXC guide
- **[shrink-lxc.sh](shrink-lxc)** - Shrink LXC disks
- **[expand-lxc.sh](expand-lxc)** - Expand LXC disks
- **[shrink-vm.sh](shrink-vm)** - Shrink VM disks
- **[expand-vm.sh](expand-vm)** - Expand VM disks
- **[clone-replace-disk.sh](clone-replace-disk)** - Clone and replace disks
- **[Installation](Installation)** - Setup guide
