# Troubleshooting Guide

Common issues and solutions for the Proxmox LXC ↔️ VM Converter suite.

---

## Table of Contents

1. [General Issues](#general-issues)
2. [lxc-to-vm.sh Issues](#lxc-to-vmsh-issues)
3. [vm-to-lxc.sh Issues](#vm-to-lxcsh-issues)
4. [Network Issues](#network-issues)
5. [Disk/Storage Issues](#diskstorage-issues)
6. [Permission Issues](#permission-issues)
7. [Debug Mode](#debug-mode)
8. [Getting Help](#getting-help)

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

Enable verbose debugging:

```bash
# Set debug flag
export DEBUG=1

# Run script
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm
```

Or check logs:

```bash
# View conversion log
tail -f /var/log/lxc-to-vm.log

# View vm-to-lxc log
tail -f /var/log/vm-to-lxc.log
```

---

## Getting Help

If issues persist:

1. **Check logs:** `/var/log/lxc-to-vm.log` or `/var/log/vm-to-lxc.log`
2. **Run with `--dry-run`:** Preview without making changes
3. **Test with `--validate-only`:** Check pre-flight conditions
4. **Create issue:** Report on GitHub with:
   - Script version (`--version`)
   - Proxmox version (`pveversion`)
   - Full error message
   - Relevant log excerpts

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - LXC to VM guide
- **[vm-to-lxc.sh](vm-to-lxc)** - VM to LXC guide
- **[Installation](Installation)** - Setup guide
