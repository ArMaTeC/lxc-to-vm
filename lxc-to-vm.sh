#!/usr/bin/env bash

# ==============================================================================
# Proxmox LXC to VM Converter
# Version: 3.0.0
# Target OS: Debian/Ubuntu based LXCs on Proxmox VE 7.x / 8.x
# License: MIT
# ==============================================================================

set -euo pipefail

VERSION="3.0.0"
LOG_FILE="/var/log/lxc-to-vm.log"

# ==============================================================================
# 0. HELPER FUNCTIONS
# ==============================================================================

# --- Colors & Formatting ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

die() { err "$*"; exit 1; }

# --- Usage / Help ---
usage() {
    cat <<USAGE
${BOLD}Proxmox LXC to VM Converter v${VERSION}${NC}

Usage: $0 [OPTIONS]

Options:
  -c, --ctid <ID>        Source LXC container ID
  -v, --vmid <ID>        Target VM ID
  -s, --storage <NAME>   Proxmox storage target (e.g. local-lvm)
  -d, --disk-size <GB>   Disk size in GB
  -f, --format <FMT>     Disk format: qcow2 (default) | raw | vmdk
  -b, --bridge <NAME>    Network bridge (default: vmbr0)
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0                                       # Interactive mode
  $0 -c 100 -v 200 -s local-lvm -d 32     # Non-interactive
USAGE
    exit 0
}

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

# --- Initialise log ---
mkdir -p "$(dirname "$LOG_FILE")"
echo "--- lxc-to-vm run: $(date -Is) ---" >> "$LOG_FILE"

# --- Dependency installer ---
ensure_dependency() {
    local cmd="$1"
    local pkg="${2:-$1}"  # package name can differ from command name
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Dependency '$cmd' is missing. Installing package '$pkg'..."
        apt-get update -qq >> "$LOG_FILE" 2>&1 && apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "Failed to install '$pkg'. Install manually: apt install $pkg"
        fi
        ok "'$pkg' installed successfully."
    fi
}

# --- Cleanup on exit / error ---
cleanup() {
    echo ""
    log "Cleaning up resources..."

    # Unmount chroot binds (lazy unmount to force it)
    for mp in dev/pts dev proc sys; do
        umount -lf "${MOUNT_POINT:-/nonexistent}/$mp" 2>/dev/null || true
    done

    # Unmount main mount
    umount -lf "${MOUNT_POINT:-/nonexistent}" 2>/dev/null || true

    # Unmount LXC if still mounted
    if [[ -n "${CTID:-}" ]]; then
        pct unmount "$CTID" 2>/dev/null || true
    fi

    # Detach loop device
    if [[ -n "${LOOP_DEV:-}" ]]; then
        kpartx -d "$LOOP_DEV" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    # Remove temp files
    if [[ -d "${TEMP_DIR:-}" ]]; then
        log "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

# ==============================================================================
# 1. ARGUMENT PARSING
# ==============================================================================

CTID="" VMID="" STORAGE="" DISK_SIZE="" DISK_FORMAT="qcow2" BRIDGE="vmbr0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)       CTID="$2";       shift 2 ;;
        -v|--vmid)       VMID="$2";       shift 2 ;;
        -s|--storage)    STORAGE="$2";    shift 2 ;;
        -d|--disk-size)  DISK_SIZE="$2";  shift 2 ;;
        -f|--format)     DISK_FORMAT="$2"; shift 2 ;;
        -b|--bridge)     BRIDGE="$2";     shift 2 ;;
        -h|--help)       usage ;;
        -V|--version)    echo "v${VERSION}"; exit 0 ;;
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

# ==============================================================================
# 2. SETUP & CHECKS
# ==============================================================================

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}   PROXMOX LXC TO VM CONVERTER v${VERSION}${NC}"
echo -e "${BOLD}==========================================${NC}"

# Check Dependencies
ensure_dependency parted
ensure_dependency kpartx
ensure_dependency rsync
ensure_dependency mkfs.ext4 e2fsprogs

# Interactive prompts for missing arguments
[[ -z "$CTID" ]]      && read -rp "Enter Source Container ID (e.g., 100): " CTID
[[ -z "$VMID" ]]      && read -rp "Enter New VM ID (e.g., 200): " VMID
[[ -z "$STORAGE" ]]   && read -rp "Enter Target Storage Name (e.g., local-lvm): " STORAGE
[[ -z "$DISK_SIZE" ]] && read -rp "Enter Disk Size in GB (must be > used space, e.g., 32): " DISK_SIZE

# --- Input Validation ---
[[ "$CTID" =~ ^[0-9]+$ ]]      || die "Container ID must be a positive integer, got: '$CTID'"
[[ "$VMID" =~ ^[0-9]+$ ]]      || die "VM ID must be a positive integer, got: '$VMID'"
[[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || die "Disk size must be a positive integer (GB), got: '$DISK_SIZE'"
[[ "$DISK_SIZE" -ge 1 ]]       || die "Disk size must be at least 1 GB."
[[ "$DISK_FORMAT" =~ ^(qcow2|raw|vmdk)$ ]] || die "Unsupported disk format: '$DISK_FORMAT' (use qcow2, raw, or vmdk)"

if ! pct config "$CTID" >/dev/null 2>&1; then
    die "Container $CTID does not exist."
fi

if qm config "$VMID" >/dev/null 2>&1; then
    die "VM ID $VMID already exists. Choose a different ID."
fi

# Validate storage exists
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
    die "Storage '$STORAGE' not found. Available: $(pvesm status | awk 'NR>1{print $1}' | tr '\n' ', ')"
fi

# Check LXC is stopped
CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
if [[ "$CT_STATUS" == "running" ]]; then
    warn "Container $CTID is running. Stopping it for a consistent copy..."
    pct stop "$CTID"
    sleep 2
fi

log "Source CTID=$CTID  Target VMID=$VMID  Storage=$STORAGE  Disk=${DISK_SIZE}GB  Format=$DISK_FORMAT  Bridge=$BRIDGE"

TEMP_DIR="/var/lib/vz/dump/lxc-to-vm-${CTID}"
IMAGE_FILE="${TEMP_DIR}/disk.raw"
MOUNT_POINT="${TEMP_DIR}/mnt"

# Create Workspace
rm -rf "${TEMP_DIR:?}"  # :? guard prevents rm -rf /
mkdir -p "$MOUNT_POINT"

# ==============================================================================
# 3. DISK CREATION
# ==============================================================================

log "Creating virtual disk image (${DISK_SIZE}GB)..."
truncate -s "${DISK_SIZE}G" "$IMAGE_FILE"

log "Partitioning disk (MBR/BIOS)..."
parted -s "$IMAGE_FILE" mklabel msdos
parted -s "$IMAGE_FILE" mkpart primary ext4 1MiB 100%
parted -s "$IMAGE_FILE" set 1 boot on

# Map loop device
LOOP_DEV=$(losetup --show -f "$IMAGE_FILE")
kpartx -a "$LOOP_DEV"
LOOP_MAP="/dev/mapper/$(basename "$LOOP_DEV")p1"

# Wait for device node to appear
for i in $(seq 1 10); do
    [[ -b "$LOOP_MAP" ]] && break
    sleep 0.5
done
[[ -b "$LOOP_MAP" ]] || die "Partition device $LOOP_MAP did not appear."

# Format
log "Formatting partition ($LOOP_MAP)..."
mkfs.ext4 -F "$LOOP_MAP" >> "$LOG_FILE" 2>&1

# Mount
mount "$LOOP_MAP" "$MOUNT_POINT"

# ==============================================================================
# 4. DATA COPY
# ==============================================================================

log "Mounting LXC container $CTID..."
pct mount "$CTID"

# Detect rootfs mount path (handles both legacy and new paths)
LXC_ROOT_MOUNT=""
for candidate in "/var/lib/lxc/${CTID}/rootfs" "/var/lib/lxc/${CTID}/rootfs/"; do
    if [[ -d "$candidate" ]]; then
        LXC_ROOT_MOUNT="$candidate"
        break
    fi
done
[[ -n "$LXC_ROOT_MOUNT" ]] || die "Could not locate rootfs for container $CTID."
log "LXC rootfs found at: $LXC_ROOT_MOUNT"

log "Copying filesystem (this may take a while)..."
rsync -axHAX --info=progress2 \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/tmp/*' \
    --exclude='/run/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/lost+found' \
    "${LXC_ROOT_MOUNT}/" "${MOUNT_POINT}/"

log "Unmounting LXC container..."
pct unmount "$CTID"

# ==============================================================================
# 5. BOOTLOADER INJECTION (CHROOT)
# ==============================================================================

log "Preparing for bootloader injection..."

# Bind mount system directories
mount --bind /dev  "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys  "$MOUNT_POINT/sys"

# Get UUID of new partition
NEW_UUID=$(blkid -s UUID -o value "$LOOP_MAP")
[[ -n "$NEW_UUID" ]] || die "Failed to determine UUID for $LOOP_MAP."
log "Partition UUID: $NEW_UUID"

# Copy resolv.conf so apt can resolve inside chroot
cp -L /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null || true

log "Entering chroot to install kernel and GRUB..."

cat <<CHROOT_EOF | chroot "$MOUNT_POINT" /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. Update FSTAB
echo "UUID=${NEW_UUID} / ext4 errors=remount-ro 0 1" > /etc/fstab

# 2. Hostname — keep existing or set a safe default
if [ ! -s /etc/hostname ]; then
    echo "converted-vm" > /etc/hostname
fi

# 3. Networking Fixes
if [ -f /etc/network/interfaces ]; then
    # Ensure standard loopback exists
    if ! grep -q "auto lo" /etc/network/interfaces; then
        printf '\nauto lo\niface lo inet loopback\n' >> /etc/network/interfaces
    fi

    # Add ens18 (Proxmox default virtio NIC)
    if ! grep -q "ens18" /etc/network/interfaces; then
        printf '\nallow-hotplug ens18\niface ens18 inet dhcp\n' >> /etc/network/interfaces
    fi

    # Comment out old eth0 entries
    sed -i 's/^auto eth0/#auto eth0/' /etc/network/interfaces
    sed -i 's/^iface eth0/#iface eth0/' /etc/network/interfaces
fi

# Ubuntu Netplan Fix
if [ -d /etc/netplan ]; then
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/01-netcfg.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: true
NETPLAN
fi

# 4. Install Kernel + GRUB
apt-get update -qq
apt-get install -y linux-image-generic systemd-sysv grub-pc 2>/dev/null \
    || apt-get install -y linux-image-amd64 systemd-sysv grub-pc

# 5. Install GRUB to the loop device
grub-install --target=i386-pc --recheck --force "${LOOP_DEV}"
update-grub

# 6. Enable serial console (useful for Proxmox noVNC/xterm)
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
CHROOT_EOF

# ==============================================================================
# 6. VM CREATION
# ==============================================================================

log "Unmounting image before import..."
for mp in dev/pts dev proc sys; do
    umount -lf "$MOUNT_POINT/$mp" 2>/dev/null || true
done
umount -lf "$MOUNT_POINT" 2>/dev/null || true
kpartx -d "$LOOP_DEV"
losetup -d "$LOOP_DEV"
LOOP_DEV=""  # Clear so cleanup trap doesn't double-free

log "Creating VM $VMID..."

# Pull settings from the source LXC config
MEMORY=$(pct config "$CTID" | awk '/^memory:/{print $2}')
[[ -z "$MEMORY" || "$MEMORY" -lt 512 ]] && MEMORY=2048
CORES=$(pct config "$CTID" | awk '/^cores:/{print $2}')
[[ -z "$CORES" || "$CORES" -lt 1 ]] && CORES=2

# Attempt to detect OS type for Proxmox hint
OSTYPE="l26"  # Linux 2.6+ kernel (generic)
if [[ -f "$MOUNT_POINT/etc/os-release" ]]; then
    source "$MOUNT_POINT/etc/os-release" 2>/dev/null || true
fi

# Create VM shell
qm create "$VMID" \
    --name "converted-ct${CTID}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --bios seabios \
    --ostype "$OSTYPE" \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --agent enabled=1

# Import disk
log "Importing disk to $STORAGE (format=$DISK_FORMAT)..."
qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$DISK_FORMAT"

# Attach disk & set boot order
IMPORTED_DISK="${STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --scsi0 "$IMPORTED_DISK"
qm set "$VMID" --boot order=scsi0
qm resize "$VMID" scsi0 "${DISK_SIZE}G" 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo -e "${GREEN}${BOLD}         CONVERSION COMPLETE${NC}"
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo ""
echo -e "  ${BOLD}VM ID:${NC}       $VMID"
echo -e "  ${BOLD}Memory:${NC}      ${MEMORY}MB"
echo -e "  ${BOLD}Cores:${NC}       $CORES"
echo -e "  ${BOLD}Disk:${NC}        ${DISK_SIZE}GB ($DISK_FORMAT)"
echo -e "  ${BOLD}Network:${NC}     DHCP on ens18 (bridge: $BRIDGE)"
echo -e "  ${BOLD}Log:${NC}         $LOG_FILE"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    1. Review VM config:  ${BOLD}qm config $VMID${NC}"
echo -e "    2. Start the VM:      ${BOLD}qm start $VMID${NC}"
echo -e "    3. Open console:      ${BOLD}qm terminal $VMID -iface serial0${NC}"
echo ""