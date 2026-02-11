#!/usr/bin/env bash

# ==============================================================================
# Proxmox LXC to VM Converter
# Version: 4.0.0
# Target OS: Debian/Ubuntu/Alpine/RHEL/Arch LXCs on Proxmox VE 7.x / 8.x
# License: MIT
# ==============================================================================

set -euo pipefail

VERSION="4.0.0"
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
  -t, --temp-dir <PATH>  Working directory for temp image (default: /var/lib/vz/dump)
  -B, --bios <TYPE>      Firmware type: seabios (default) | ovmf (UEFI)
  -n, --dry-run          Show what would be done without making changes
  -k, --keep-network     Preserve original network config (only add ens18 adapter)
  -S, --start            Auto-start VM and run health checks after conversion
  --shrink               Shrink LXC disk to usage + headroom before converting
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0                                       # Interactive mode
  $0 -c 100 -v 200 -s local-lvm -d 32     # Non-interactive
  $0 -c 100 -v 200 -s local-lvm -d 200 -t /mnt/scratch  # Use alt temp dir
  $0 -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start   # UEFI + auto-start
  $0 -c 100 -v 200 -s local-lvm -d 32 --dry-run         # Preview only
  $0 -c 100 -v 200 -s local-lvm --shrink                # Auto-shrink + convert
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

    # Unmount EFI partition if present
    umount -lf "${MOUNT_POINT:-/nonexistent}/boot/efi" 2>/dev/null || true

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

CTID="" VMID="" STORAGE="" DISK_SIZE="" DISK_FORMAT="qcow2" BRIDGE="vmbr0" WORK_DIR=""
BIOS_TYPE="seabios" DRY_RUN=false KEEP_NETWORK=false AUTO_START=false SHRINK_FIRST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)       CTID="$2";        shift 2 ;;
        -v|--vmid)       VMID="$2";        shift 2 ;;
        -s|--storage)    STORAGE="$2";     shift 2 ;;
        -d|--disk-size)  DISK_SIZE="$2";   shift 2 ;;
        -f|--format)     DISK_FORMAT="$2";  shift 2 ;;
        -b|--bridge)     BRIDGE="$2";      shift 2 ;;
        -t|--temp-dir)   WORK_DIR="$2";    shift 2 ;;
        -B|--bios)       BIOS_TYPE="$2";   shift 2 ;;
        -n|--dry-run)    DRY_RUN=true;      shift ;;
        -k|--keep-network) KEEP_NETWORK=true; shift ;;
        -S|--start)      AUTO_START=true;   shift ;;
        --shrink)        SHRINK_FIRST=true; shift ;;
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
[[ -z "$DISK_SIZE" ]] && ! $SHRINK_FIRST && read -rp "Enter Disk Size in GB (must be > used space, e.g., 32): " DISK_SIZE

# --- Input Validation ---
[[ "$CTID" =~ ^[0-9]+$ ]]      || die "Container ID must be a positive integer, got: '$CTID'"
[[ "$VMID" =~ ^[0-9]+$ ]]      || die "VM ID must be a positive integer, got: '$VMID'"
if [[ -n "$DISK_SIZE" ]]; then
    [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || die "Disk size must be a positive integer (GB), got: '$DISK_SIZE'"
    [[ "$DISK_SIZE" -ge 1 ]]       || die "Disk size must be at least 1 GB."
fi
[[ "$DISK_FORMAT" =~ ^(qcow2|raw|vmdk)$ ]] || die "Unsupported disk format: '$DISK_FORMAT' (use qcow2, raw, or vmdk)"
[[ "$BIOS_TYPE" =~ ^(seabios|ovmf)$ ]] || die "Unsupported BIOS type: '$BIOS_TYPE' (use seabios or ovmf)"

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
    if $DRY_RUN; then
        warn "Container $CTID is running. Would stop it for a consistent copy."
    else
        warn "Container $CTID is running. Stopping it for a consistent copy..."
        pct stop "$CTID"
        sleep 2
    fi
fi

# --- Shrink container disk before conversion ---
if $SHRINK_FIRST && ! $DRY_RUN; then
    log "=== PRE-CONVERSION DISK SHRINK ==="

    # Parse rootfs from container config
    SHRINK_ROOTFS_LINE=$(pct config "$CTID" | grep "^rootfs:")
    [[ -n "$SHRINK_ROOTFS_LINE" ]] || die "Could not find rootfs config for container $CTID."
    SHRINK_VOL=$(echo "$SHRINK_ROOTFS_LINE" | sed 's/^rootfs: //' | cut -d',' -f1)
    SHRINK_STORAGE=$(echo "$SHRINK_VOL" | cut -d':' -f1)
    SHRINK_CURRENT_STR=$(echo "$SHRINK_ROOTFS_LINE" | grep -oP 'size=\K[0-9]+' || echo "0")
    SHRINK_STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$SHRINK_STORAGE" '$1==s{print $2}')

    log "Rootfs: $SHRINK_VOL | Current: ${SHRINK_CURRENT_STR}GB | Storage type: $SHRINK_STORAGE_TYPE"

    # Mount and measure used space
    log "Mounting container to measure used space..."
    pct mount "$CTID"
    SHRINK_ROOT="/var/lib/lxc/${CTID}/rootfs"
    if [[ -d "$SHRINK_ROOT" ]]; then
        SHRINK_USED_BYTES=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
            --exclude='tmp/*' --exclude='run/*' "$SHRINK_ROOT/" 2>/dev/null | awk '{print $1}')
        SHRINK_USED_MB=$(( ${SHRINK_USED_BYTES:-0} / 1024 / 1024 ))
        SHRINK_USED_GB=$(( (SHRINK_USED_MB + 1023) / 1024 ))
    else
        pct unmount "$CTID" 2>/dev/null || true
        die "Could not locate rootfs for container $CTID."
    fi
    pct unmount "$CTID" 2>/dev/null || true

    SHRINK_USED_HR=$(numfmt --to=iec-i --suffix=B "${SHRINK_USED_BYTES:-0}" 2>/dev/null || echo "${SHRINK_USED_MB}MB")
    log "Used space: ${SHRINK_USED_HR} (~${SHRINK_USED_GB}GB)"

    # Calculate target size: data + 5% metadata margin (min 512MB) + 1GB headroom
    SHRINK_META_MB=$(( SHRINK_USED_MB * 5 / 100 ))
    [[ "$SHRINK_META_MB" -lt 512 ]] && SHRINK_META_MB=512
    SHRINK_META_GB=$(( (SHRINK_META_MB + 1023) / 1024 ))
    SHRINK_TARGET_GB=$(( SHRINK_USED_GB + SHRINK_META_GB + 1 ))
    [[ "$SHRINK_TARGET_GB" -lt 2 ]] && SHRINK_TARGET_GB=2

    if [[ "$SHRINK_TARGET_GB" -ge "$SHRINK_CURRENT_STR" ]]; then
        ok "Container disk already near optimal (${SHRINK_CURRENT_STR}GB). Skipping shrink."
    else
        SHRINK_SAVINGS=$((SHRINK_CURRENT_STR - SHRINK_TARGET_GB))
        log "Shrink plan: ${SHRINK_CURRENT_STR}GB → ${SHRINK_TARGET_GB}GB (saving ${SHRINK_SAVINGS}GB)"

        case "$SHRINK_STORAGE_TYPE" in
            lvmthin|lvm)
                SHRINK_LV=$(pvesm path "$SHRINK_VOL" 2>/dev/null)
                [[ -n "$SHRINK_LV" && -e "$SHRINK_LV" ]] || die "Could not resolve LV path for $SHRINK_VOL"
                log "LV path: $SHRINK_LV"

                lvchange -ay "$SHRINK_LV" 2>/dev/null || true

                # Filesystem check
                log "Running e2fsck..."
                e2fsck -f -y "$SHRINK_LV" >> "$LOG_FILE" 2>&1 || {
                    e2fsck -f -y "$SHRINK_LV" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                }
                ok "Filesystem check passed."

                # Query true minimum
                log "Querying minimum filesystem size..."
                SHRINK_MIN_OUT=$(resize2fs -P "$SHRINK_LV" 2>&1) || true
                echo "$SHRINK_MIN_OUT" >> "$LOG_FILE"
                SHRINK_MIN_BLOCKS=$(echo "$SHRINK_MIN_OUT" | grep -oP 'minimum size.*?:\s*\K[0-9]+' || echo "0")
                if [[ "$SHRINK_MIN_BLOCKS" -gt 0 ]]; then
                    SHRINK_BLK_SIZE=$(dumpe2fs -h "$SHRINK_LV" 2>/dev/null | awk '/Block size:/{print $3}')
                    SHRINK_BLK_SIZE="${SHRINK_BLK_SIZE:-4096}"
                    SHRINK_MIN_GB=$(( (SHRINK_MIN_BLOCKS * SHRINK_BLK_SIZE / 1073741824) + 1 ))
                    log "Filesystem minimum: ~${SHRINK_MIN_GB}GB"
                    [[ "$SHRINK_TARGET_GB" -lt "$SHRINK_MIN_GB" ]] && SHRINK_TARGET_GB="$SHRINK_MIN_GB"
                fi

                # Shrink filesystem with auto-retry
                SHRINK_OK=false
                SHRINK_TRY="$SHRINK_TARGET_GB"
                for attempt in 1 2 3 4 5; do
                    log "resize2fs to ${SHRINK_TRY}GB (attempt ${attempt}/5)..."
                    SHRINK_R_OUT=""
                    if SHRINK_R_OUT=$(resize2fs "$SHRINK_LV" "${SHRINK_TRY}G" 2>&1); then
                        echo "$SHRINK_R_OUT" >> "$LOG_FILE"
                        ok "Filesystem shrunk to ${SHRINK_TRY}GB."
                        SHRINK_TARGET_GB="$SHRINK_TRY"
                        SHRINK_OK=true
                        break
                    else
                        echo "$SHRINK_R_OUT" >> "$LOG_FILE"
                        warn "resize2fs failed at ${SHRINK_TRY}GB — increasing by 1GB..."
                        SHRINK_TRY=$((SHRINK_TRY + 1))
                    fi
                done
                $SHRINK_OK || die "resize2fs failed after 5 attempts. Container disk unchanged."

                # Shrink LV
                log "Shrinking LV to ${SHRINK_TARGET_GB}GB..."
                if SHRINK_LV_OUT=$(lvresize -y -L "${SHRINK_TARGET_GB}G" "$SHRINK_LV" 2>&1); then
                    echo "$SHRINK_LV_OUT" >> "$LOG_FILE"
                    ok "LV shrunk to ${SHRINK_TARGET_GB}GB."
                else
                    echo "$SHRINK_LV_OUT" >> "$LOG_FILE"
                    e2fsck -f -y "$SHRINK_LV" >> "$LOG_FILE" 2>&1 || true
                    die "lvresize failed. Run manually: lvresize -L ${SHRINK_TARGET_GB}G $SHRINK_LV"
                fi

                # Verify
                e2fsck -f -y "$SHRINK_LV" >> "$LOG_FILE" 2>&1 || true

                # Update container config
                pct set "$CTID" --rootfs "${SHRINK_VOL},size=${SHRINK_TARGET_GB}G"
                ok "Container config updated: ${SHRINK_CURRENT_STR}GB → ${SHRINK_TARGET_GB}GB (saved ${SHRINK_SAVINGS}GB)"
                ;;
            dir|nfs|cifs|glusterfs)
                SHRINK_DISK=$(pvesm path "$SHRINK_VOL" 2>/dev/null)
                [[ -n "$SHRINK_DISK" && -f "$SHRINK_DISK" ]] || die "Could not find disk image: $SHRINK_DISK"
                SHRINK_IMG_FMT=$(qemu-img info "$SHRINK_DISK" 2>/dev/null | awk '/file format:/{print $3}')

                if [[ "$SHRINK_IMG_FMT" == "raw" ]]; then
                    SHRINK_LOOP=$(losetup --show -f "$SHRINK_DISK")
                    e2fsck -f -y "$SHRINK_LOOP" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                    resize2fs "$SHRINK_LOOP" "${SHRINK_TARGET_GB}G" >> "$LOG_FILE" 2>&1 || die "resize2fs failed."
                    losetup -d "$SHRINK_LOOP" 2>/dev/null || true
                    truncate -s "${SHRINK_TARGET_GB}G" "$SHRINK_DISK"
                elif [[ "$SHRINK_IMG_FMT" == "qcow2" ]]; then
                    SHRINK_TEMP="${SHRINK_DISK}.shrink.raw"
                    qemu-img convert -f qcow2 -O raw "$SHRINK_DISK" "$SHRINK_TEMP"
                    SHRINK_LOOP=$(losetup --show -f "$SHRINK_TEMP")
                    e2fsck -f -y "$SHRINK_LOOP" >> "$LOG_FILE" 2>&1 || { losetup -d "$SHRINK_LOOP" 2>/dev/null; rm -f "$SHRINK_TEMP"; die "fsck failed."; }
                    resize2fs "$SHRINK_LOOP" "${SHRINK_TARGET_GB}G" >> "$LOG_FILE" 2>&1 || { losetup -d "$SHRINK_LOOP" 2>/dev/null; rm -f "$SHRINK_TEMP"; die "resize2fs failed."; }
                    losetup -d "$SHRINK_LOOP" 2>/dev/null || true
                    truncate -s "${SHRINK_TARGET_GB}G" "$SHRINK_TEMP"
                    qemu-img convert -f raw -O qcow2 "$SHRINK_TEMP" "$SHRINK_DISK"
                    rm -f "$SHRINK_TEMP"
                else
                    die "Unsupported image format: $SHRINK_IMG_FMT"
                fi
                pct set "$CTID" --rootfs "${SHRINK_VOL},size=${SHRINK_TARGET_GB}G"
                ok "Disk image shrunk: ${SHRINK_CURRENT_STR}GB → ${SHRINK_TARGET_GB}GB"
                ;;
            zfspool)
                SHRINK_ZVOL=$(pvesm path "$SHRINK_VOL" 2>/dev/null)
                SHRINK_ZDS=$(echo "$SHRINK_ZVOL" | sed 's|/dev/zvol/||')
                e2fsck -f -y "$SHRINK_ZVOL" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                resize2fs "$SHRINK_ZVOL" "${SHRINK_TARGET_GB}G" >> "$LOG_FILE" 2>&1 || die "resize2fs failed."
                zfs set volsize="${SHRINK_TARGET_GB}G" "$SHRINK_ZDS" >> "$LOG_FILE" 2>&1 || die "ZFS volsize shrink failed."
                e2fsck -f -y "$SHRINK_ZVOL" >> "$LOG_FILE" 2>&1 || true
                pct set "$CTID" --rootfs "${SHRINK_VOL},size=${SHRINK_TARGET_GB}G"
                ok "ZFS volume shrunk: ${SHRINK_CURRENT_STR}GB → ${SHRINK_TARGET_GB}GB"
                ;;
            *)
                die "Unsupported storage type for shrink: $SHRINK_STORAGE_TYPE"
                ;;
        esac

        SHRINK_SAVINGS=$((SHRINK_CURRENT_STR - SHRINK_TARGET_GB))
    fi

    # Auto-set DISK_SIZE if user didn't provide one
    # Add 3GB overhead for MBR/GPT partition table + ext4 filesystem overhead (journal, inodes, superblocks ~5%)
    if [[ -z "$DISK_SIZE" ]]; then
        DISK_SIZE=$(( SHRINK_TARGET_GB + 3 ))
        ok "Auto-setting VM disk size to ${DISK_SIZE}GB (container: ${SHRINK_TARGET_GB}GB + 3GB partition/ext4 overhead)"
    fi
fi

# If --shrink used in dry-run, show what would happen
if $SHRINK_FIRST && $DRY_RUN; then
    log "Shrink: would shrink container $CTID disk before conversion (details shown below)."
fi

# Final DISK_SIZE check — must be set by now (either by user, prompt, or --shrink)
if [[ -z "$DISK_SIZE" ]] || ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [[ "$DISK_SIZE" -lt 1 ]]; then
    die "Disk size is not set. Provide -d <GB> or use --shrink to auto-calculate."
fi

# --- Dry-run summary ---
if $DRY_RUN; then
    echo ""
    echo -e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    echo -e "  ${BOLD}Source CT:${NC}    $CTID (status: ${CT_STATUS:-unknown})"
    echo -e "  ${BOLD}Target VM:${NC}   $VMID"
    echo -e "  ${BOLD}Storage:${NC}     $STORAGE"
    echo -e "  ${BOLD}Disk:${NC}        ${DISK_SIZE}GB ($DISK_FORMAT)"
    echo -e "  ${BOLD}Firmware:${NC}    $BIOS_TYPE"
    echo -e "  ${BOLD}Bridge:${NC}      $BRIDGE"
    echo -e "  ${BOLD}Keep net:${NC}    $KEEP_NETWORK"
    echo -e "  ${BOLD}Auto-start:${NC}  $AUTO_START"
    echo ""
    # Show LXC config
    LXC_MEM=$(pct config "$CTID" | awk '/^memory:/{print $2}')
    LXC_CORES=$(pct config "$CTID" | awk '/^cores:/{print $2}')
    echo -e "  ${BOLD}LXC Memory:${NC}  ${LXC_MEM:-2048}MB"
    echo -e "  ${BOLD}LXC Cores:${NC}   ${LXC_CORES:-2}"
    echo ""
    # Space check
    DEFAULT_WORK_BASE="/var/lib/vz/dump"
    WORK_CHECK="${WORK_DIR:-$DEFAULT_WORK_BASE}"
    REQUIRED_MB=$(( (DISK_SIZE + 1) * 1024 ))
    AVAIL_MB=$(df -BM --output=avail "$WORK_CHECK" 2>/dev/null | tail -1 | tr -d ' M')
    if [[ "${AVAIL_MB:-0}" -ge "$REQUIRED_MB" ]]; then
        echo -e "  ${GREEN}[✓]${NC} Disk space OK: ${AVAIL_MB}MB available (need ${REQUIRED_MB}MB) in $WORK_CHECK"
    else
        echo -e "  ${RED}[✗]${NC} Insufficient space: ${AVAIL_MB:-0}MB available (need ${REQUIRED_MB}MB) in $WORK_CHECK"
    fi
    echo ""
    echo -e "  ${BOLD}Shrink:${NC}      $SHRINK_FIRST"
    echo ""
    echo -e "  ${BOLD}Steps that would be performed:${NC}"
    if $SHRINK_FIRST; then
        echo "    0. Shrink container disk to usage + headroom before conversion"
    fi
    echo "    1. Create ${DISK_SIZE}GB raw disk image"
    if [[ "$BIOS_TYPE" == "ovmf" ]]; then
        echo "    2. Partition disk (GPT + 512MB EFI System Partition)"
    else
        echo "    2. Partition disk (MBR/BIOS)"
    fi
    echo "    3. Copy container filesystem via rsync"
    echo "    4. Chroot: install kernel + bootloader"
    if ! $KEEP_NETWORK; then
        echo "    5. Chroot: reconfigure networking for VM (ens18/DHCP)"
    else
        echo "    5. Chroot: preserve existing network config, add ens18 adapter"
    fi
    echo "    6. Create VM $VMID, import disk to $STORAGE"
    if $AUTO_START; then
        echo "    7. Auto-start VM and run health checks"
    fi
    echo ""
    ok "Dry run complete. Remove --dry-run to execute."
    exit 0
fi

# --- Disk Space Check ---
# We need at least DISK_SIZE GB for the raw image, plus ~1GB headroom for chroot packages.
REQUIRED_MB=$(( (DISK_SIZE + 1) * 1024 ))
DEFAULT_WORK_BASE="/var/lib/vz/dump"

check_space() {
    local dir="$1"
    local avail_mb
    avail_mb=$(df -BM --output=avail "$dir" 2>/dev/null | tail -1 | tr -d ' M')
    echo "${avail_mb:-0}"
}

pick_work_dir() {
    local base="$1"
    local avail_mb
    avail_mb=$(check_space "$base")

    if [[ "$avail_mb" -ge "$REQUIRED_MB" ]]; then
        log "Workspace: $base — ${avail_mb}MB available (need ${REQUIRED_MB}MB). OK." >&2
        echo "$base"
        return 0
    fi

    echo "" >&2
    warn "Insufficient space in $base: ${avail_mb}MB available, ${REQUIRED_MB}MB required." >&2
    echo -e "  ${YELLOW}Note:${NC} The script needs filesystem space for a temporary ${DISK_SIZE}GB raw image." >&2
    echo -e "  ${YELLOW}      ${NC} LVM/ZFS storage (e.g. local-lvm) cannot be used directly as a working directory." >&2
    echo -e "  ${YELLOW}      ${NC} The temp image is imported to your target storage after creation." >&2

    # Non-interactive: if --temp-dir was explicitly given and it's too small, fail hard
    if [[ -n "$WORK_DIR" ]]; then
        die "Specified --temp-dir '$WORK_DIR' does not have enough space (${avail_mb}MB < ${REQUIRED_MB}MB)."
    fi

    # Collect all suitable mount points
    local -a candidates_mp=()
    local -a candidates_avail=()
    local mp="" avail=""
    while read -r avail mp; do
        avail="${avail%M}"
        [[ "$avail" =~ ^[0-9]+$ ]] || continue
        [[ "$mp" == "/boot"* || "$mp" == "/snap"* || "$mp" == "/run"* || "$mp" == "/dev"* ]] && continue
        if [[ "$avail" -ge "$REQUIRED_MB" ]]; then
            candidates_mp+=("$mp")
            candidates_avail+=("$avail")
        fi
    done < <(df -BM --output=avail,target 2>/dev/null | tail -n +2)

    if [[ ${#candidates_mp[@]} -eq 0 ]]; then
        die "No mount point has enough free space (${REQUIRED_MB}MB). Free up disk space or attach additional storage."
    fi

    # Auto-select if only one candidate
    if [[ ${#candidates_mp[@]} -eq 1 ]]; then
        local auto_path="${candidates_mp[0]}"
        local auto_avail="${candidates_avail[0]}"
        ok "Auto-selecting workspace: $auto_path (${auto_avail}MB free)" >&2
        mkdir -p "$auto_path" 2>/dev/null || die "Cannot create directory: $auto_path"
        echo "$auto_path"
        return 0
    fi

    # Multiple candidates — show numbered menu
    echo "" >&2
    echo -e "${BOLD}Available mount points with sufficient space (>${REQUIRED_MB}MB):${NC}" >&2
    for i in "${!candidates_mp[@]}"; do
        echo -e "  ${GREEN}[$((i+1))]${NC} ${BOLD}${candidates_mp[$i]}${NC}  — ${candidates_avail[$i]}MB free" >&2
    done

    echo "" >&2
    local choice
    read -rp "Select a mount point [1-${#candidates_mp[@]}] or enter a custom path: " choice

    local selected_path=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#candidates_mp[@]} ]]; then
        selected_path="${candidates_mp[$((choice-1))]}"
    elif [[ -n "$choice" ]]; then
        selected_path="$choice"
    else
        # Default to first (largest) option
        selected_path="${candidates_mp[0]}"
    fi

    mkdir -p "$selected_path" 2>/dev/null || die "Cannot create directory: $selected_path"

    local sel_avail
    sel_avail=$(check_space "$selected_path")
    if [[ "$sel_avail" -lt "$REQUIRED_MB" ]]; then
        die "'$selected_path' still insufficient: ${sel_avail}MB available, ${REQUIRED_MB}MB required."
    fi

    ok "Using workspace: $selected_path (${sel_avail}MB available)" >&2
    echo "$selected_path"
}

# Determine the working base directory
WORK_BASE="${WORK_DIR:-$DEFAULT_WORK_BASE}"
mkdir -p "$WORK_BASE" 2>/dev/null || true
WORK_BASE=$(pick_work_dir "$WORK_BASE")

TEMP_DIR="${WORK_BASE}/lxc-to-vm-${CTID}"
IMAGE_FILE="${TEMP_DIR}/disk.raw"
MOUNT_POINT="${TEMP_DIR}/mnt"

log "Source CTID=$CTID  Target VMID=$VMID  Storage=$STORAGE  Disk=${DISK_SIZE}GB  Format=$DISK_FORMAT  Bridge=$BRIDGE"
log "Working directory: $TEMP_DIR"

# Create Workspace
rm -rf "${TEMP_DIR:?}"  # :? guard prevents rm -rf /
mkdir -p "$MOUNT_POINT"

# ==============================================================================
# 3. DISK CREATION
# ==============================================================================

log "Creating virtual disk image (${DISK_SIZE}GB)..."
truncate -s "${DISK_SIZE}G" "$IMAGE_FILE"

EFI_PART=""  # Will hold the EFI partition device path if UEFI mode

if [[ "$BIOS_TYPE" == "ovmf" ]]; then
    log "Partitioning disk (GPT/UEFI with 512MB EFI System Partition)..."
    parted -s "$IMAGE_FILE" mklabel gpt
    parted -s "$IMAGE_FILE" mkpart ESP fat32 1MiB 513MiB
    parted -s "$IMAGE_FILE" set 1 esp on
    parted -s "$IMAGE_FILE" mkpart primary ext4 513MiB 100%

    LOOP_DEV=$(losetup --show -f "$IMAGE_FILE")
    kpartx -a "$LOOP_DEV"
    EFI_PART="/dev/mapper/$(basename "$LOOP_DEV")p1"
    LOOP_MAP="/dev/mapper/$(basename "$LOOP_DEV")p2"

    # Wait for device nodes
    for i in $(seq 1 10); do
        [[ -b "$LOOP_MAP" && -b "$EFI_PART" ]] && break
        sleep 0.5
    done
    [[ -b "$EFI_PART" ]]  || die "EFI partition device $EFI_PART did not appear."
    [[ -b "$LOOP_MAP" ]]  || die "Root partition device $LOOP_MAP did not appear."

    log "Formatting EFI partition ($EFI_PART)..."
    mkfs.fat -F32 "$EFI_PART" >> "$LOG_FILE" 2>&1

    log "Formatting root partition ($LOOP_MAP)..."
    mkfs.ext4 -F "$LOOP_MAP" >> "$LOG_FILE" 2>&1

    mount "$LOOP_MAP" "$MOUNT_POINT"
    mkdir -p "$MOUNT_POINT/boot/efi"
    mount "$EFI_PART" "$MOUNT_POINT/boot/efi"
else
    log "Partitioning disk (MBR/BIOS)..."
    parted -s "$IMAGE_FILE" mklabel msdos
    parted -s "$IMAGE_FILE" mkpart primary ext4 1MiB 100%
    parted -s "$IMAGE_FILE" set 1 boot on

    LOOP_DEV=$(losetup --show -f "$IMAGE_FILE")
    kpartx -a "$LOOP_DEV"
    LOOP_MAP="/dev/mapper/$(basename "$LOOP_DEV")p1"

    for i in $(seq 1 10); do
        [[ -b "$LOOP_MAP" ]] && break
        sleep 0.5
    done
    [[ -b "$LOOP_MAP" ]] || die "Partition device $LOOP_MAP did not appear."

    log "Formatting partition ($LOOP_MAP)..."
    mkfs.ext4 -F "$LOOP_MAP" >> "$LOG_FILE" 2>&1

    mount "$LOOP_MAP" "$MOUNT_POINT"
fi

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

log "Calculating source size (scanning file list)..."
SRC_SIZE=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
    --exclude='tmp/*' --exclude='run/*' --exclude='mnt/*' \
    --exclude='media/*' --exclude='lost+found' \
    "${LXC_ROOT_MOUNT}/" 2>/dev/null | awk '{print $1}')
SRC_SIZE_HR=$(numfmt --to=iec-i --suffix=B "${SRC_SIZE:-0}" 2>/dev/null || echo "${SRC_SIZE:-0} bytes")
log "Source size: ${SRC_SIZE_HR} — starting copy..."

rsync -axHAX --info=progress2 --no-inc-recursive \
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

# Get EFI partition UUID if applicable
EFI_UUID=""
if [[ -n "$EFI_PART" ]]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    log "EFI Partition UUID: $EFI_UUID"
fi

# Copy resolv.conf so package managers can resolve inside chroot
cp -L /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null || true

# --- Detect distro inside the container ---
DISTRO_FAMILY="unknown"
if [[ -f "$MOUNT_POINT/etc/os-release" ]]; then
    # shellcheck disable=SC1091
    DISTRO_ID=$(. "$MOUNT_POINT/etc/os-release" && echo "${ID:-unknown}")
    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop|kali|proxmox) DISTRO_FAMILY="debian" ;;
        alpine)                                    DISTRO_FAMILY="alpine" ;;
        centos|rhel|rocky|alma|fedora|ol)          DISTRO_FAMILY="rhel"   ;;
        arch|manjaro|endeavouros)                  DISTRO_FAMILY="arch"   ;;
        *)                                         DISTRO_FAMILY="debian" ;; # fallback
    esac
elif [[ -f "$MOUNT_POINT/etc/alpine-release" ]]; then
    DISTRO_FAMILY="alpine"
elif [[ -f "$MOUNT_POINT/etc/redhat-release" ]]; then
    DISTRO_FAMILY="rhel"
fi
log "Detected distro family: $DISTRO_FAMILY (ID: ${DISTRO_ID:-unknown})"

# --- Build the chroot script dynamically ---
CHROOT_SCRIPT="$TEMP_DIR/chroot-setup.sh"
cat > "$CHROOT_SCRIPT" <<'CHROOT_HEADER'
#!/bin/bash
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CHROOT_HEADER

# Append fstab
cat >> "$CHROOT_SCRIPT" <<FSTAB_BLOCK
# --- FSTAB ---
echo "UUID=${NEW_UUID} / ext4 errors=remount-ro 0 1" > /etc/fstab
FSTAB_BLOCK

if [[ -n "$EFI_UUID" ]]; then
    cat >> "$CHROOT_SCRIPT" <<EFI_FSTAB
echo "UUID=${EFI_UUID} /boot/efi vfat umask=0077 0 1" >> /etc/fstab
EFI_FSTAB
fi

# Append hostname
cat >> "$CHROOT_SCRIPT" <<'HOSTNAME_BLOCK'
# --- Hostname ---
if [ ! -s /etc/hostname ]; then
    echo "converted-vm" > /etc/hostname
fi
HOSTNAME_BLOCK

# --- Networking block (depends on --keep-network) ---
if $KEEP_NETWORK; then
    cat >> "$CHROOT_SCRIPT" <<'NET_KEEP_BLOCK'
# --- Networking (preserve mode) ---
# Only add ens18 adapter without touching existing config
if [ -f /etc/network/interfaces ]; then
    if ! grep -q "auto lo" /etc/network/interfaces; then
        printf '\nauto lo\niface lo inet loopback\n' >> /etc/network/interfaces
    fi
    # Add ens18 alongside existing config
    if ! grep -q "ens18" /etc/network/interfaces; then
        printf '\nallow-hotplug ens18\niface ens18 inet dhcp\n' >> /etc/network/interfaces
    fi
    # Translate eth0 -> ens18 in existing entries (non-destructive rename)
    sed -i 's/\beth0\b/ens18/g' /etc/network/interfaces
fi
# Netplan: add ens18 without removing existing configs
if [ -d /etc/netplan ]; then
    if ! grep -rq "ens18" /etc/netplan/ 2>/dev/null; then
        cat > /etc/netplan/99-vm-ens18.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: true
NETPLAN
    fi
fi
NET_KEEP_BLOCK
else
    cat >> "$CHROOT_SCRIPT" <<'NET_REPLACE_BLOCK'
# --- Networking (replace mode) ---
if [ -f /etc/network/interfaces ]; then
    if ! grep -q "auto lo" /etc/network/interfaces; then
        printf '\nauto lo\niface lo inet loopback\n' >> /etc/network/interfaces
    fi
    if ! grep -q "ens18" /etc/network/interfaces; then
        printf '\nallow-hotplug ens18\niface ens18 inet dhcp\n' >> /etc/network/interfaces
    fi
    sed -i 's/^auto eth0/#auto eth0/' /etc/network/interfaces
    sed -i 's/^iface eth0/#iface eth0/' /etc/network/interfaces
fi
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
NET_REPLACE_BLOCK
fi

# --- Kernel + Bootloader install (distro-specific) ---
case "$DISTRO_FAMILY" in
    debian)
        if [[ "$BIOS_TYPE" == "ovmf" ]]; then
            cat >> "$CHROOT_SCRIPT" <<DEBIAN_EFI
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic systemd-sysv grub-efi-amd64 2>/dev/null \
    || apt-get install -y linux-image-amd64 systemd-sysv grub-efi-amd64
grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck --no-nvram --force --removable
update-grub
DEBIAN_EFI
        else
            cat >> "$CHROOT_SCRIPT" <<DEBIAN_BIOS
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic systemd-sysv grub-pc 2>/dev/null \
    || apt-get install -y linux-image-amd64 systemd-sysv grub-pc
grub-install --target=i386-pc --recheck --force "${LOOP_DEV}"
update-grub
DEBIAN_BIOS
        fi
        ;;
    alpine)
        if [[ "$BIOS_TYPE" == "ovmf" ]]; then
            cat >> "$CHROOT_SCRIPT" <<ALPINE_EFI
apk update
apk add linux-lts linux-firmware grub grub-efi efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --force --removable
grub-mkconfig -o /boot/grub/grub.cfg
# Alpine needs an init system for VM boot
apk add openrc
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit
rc-update add networking boot
rc-update add hostname boot
ALPINE_EFI
        else
            cat >> "$CHROOT_SCRIPT" <<ALPINE_BIOS
apk update
apk add linux-lts linux-firmware grub grub-bios
grub-install --target=i386-pc --recheck --force "${LOOP_DEV}"
grub-mkconfig -o /boot/grub/grub.cfg
apk add openrc
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit
rc-update add networking boot
rc-update add hostname boot
ALPINE_BIOS
        fi
        ;;
    rhel)
        if [[ "$BIOS_TYPE" == "ovmf" ]]; then
            cat >> "$CHROOT_SCRIPT" <<RHEL_EFI
yum install -y kernel grub2-efi-x64 grub2-efi-x64-modules shim-x64 efibootmgr 2>/dev/null \
    || dnf install -y kernel grub2-efi-x64 grub2-efi-x64-modules shim-x64 efibootmgr
grub2-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --force --removable 2>/dev/null || true
grub2-mkconfig -o /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null \
    || grub2-mkconfig -o /boot/grub2/grub.cfg
RHEL_EFI
        else
            cat >> "$CHROOT_SCRIPT" <<RHEL_BIOS
yum install -y kernel grub2 grub2-pc 2>/dev/null \
    || dnf install -y kernel grub2 grub2-pc
grub2-install --target=i386-pc --recheck --force "${LOOP_DEV}"
grub2-mkconfig -o /boot/grub2/grub.cfg
RHEL_BIOS
        fi
        ;;
    arch)
        if [[ "$BIOS_TYPE" == "ovmf" ]]; then
            cat >> "$CHROOT_SCRIPT" <<ARCH_EFI
pacman -Sy --noconfirm linux linux-firmware grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --force --removable
grub-mkconfig -o /boot/grub/grub.cfg
ARCH_EFI
        else
            cat >> "$CHROOT_SCRIPT" <<ARCH_BIOS
pacman -Sy --noconfirm linux linux-firmware grub
grub-install --target=i386-pc --recheck --force "${LOOP_DEV}"
grub-mkconfig -o /boot/grub/grub.cfg
ARCH_BIOS
        fi
        ;;
esac

# Append serial console enablement
cat >> "$CHROOT_SCRIPT" <<'SERIAL_BLOCK'
# --- Enable serial console ---
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
elif [ -f /etc/inittab ]; then
    # For Alpine/sysvinit
    grep -q ttyS0 /etc/inittab || echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" >> /etc/inittab
fi
SERIAL_BLOCK

log "Entering chroot to install kernel and GRUB ($DISTRO_FAMILY / $BIOS_TYPE)..."
chmod +x "$CHROOT_SCRIPT"
cp "$CHROOT_SCRIPT" "$MOUNT_POINT/tmp/chroot-setup.sh"
chroot "$MOUNT_POINT" /bin/bash /tmp/chroot-setup.sh
rm -f "$MOUNT_POINT/tmp/chroot-setup.sh"

# ==============================================================================
# 6. VM CREATION
# ==============================================================================

# Pull settings from the source LXC config (before unmount)
MEMORY=$(pct config "$CTID" | awk '/^memory:/{print $2}')
[[ -z "$MEMORY" || "$MEMORY" -lt 512 ]] && MEMORY=2048
CORES=$(pct config "$CTID" | awk '/^cores:/{print $2}')
[[ -z "$CORES" || "$CORES" -lt 1 ]] && CORES=2
OSTYPE="l26"  # Linux 2.6+ kernel (generic)

log "Unmounting image before import..."

# Flush all pending writes — critical for large disks
sync

# Unmount EFI partition first (if mounted)
if [[ -n "$EFI_PART" ]]; then
    umount -lf "$MOUNT_POINT/boot/efi" 2>/dev/null || true
fi

for mp in dev/pts dev proc sys; do
    umount -lf "$MOUNT_POINT/$mp" 2>/dev/null || true
done
umount -lf "$MOUNT_POINT" 2>/dev/null || true

# Allow kernel time to release the device after unmount
sync
sleep 2

# Detach partition mapping (retry up to 5 times for large disks)
for attempt in $(seq 1 5); do
    kpartx -d "$LOOP_DEV" 2>/dev/null && break
    warn "kpartx -d attempt $attempt failed, retrying in 3s..."
    sleep 3
done

# Detach loop device (retry up to 5 times)
for attempt in $(seq 1 5); do
    losetup -d "$LOOP_DEV" 2>/dev/null && break
    warn "losetup -d attempt $attempt failed, retrying in 3s..."
    sleep 3
done
LOOP_DEV=""  # Clear so cleanup trap doesn't double-free

log "Creating VM $VMID..."

# Create VM shell
qm create "$VMID" \
    --name "converted-ct${CTID}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --bios "$BIOS_TYPE" \
    --ostype "$OSTYPE" \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --agent enabled=1

# Add EFI disk for UEFI mode
if [[ "$BIOS_TYPE" == "ovmf" ]]; then
    log "Adding EFI disk for UEFI boot..."
    qm set "$VMID" --efidisk0 "${STORAGE}:1,format=${DISK_FORMAT},efitype=4m,pre-enrolled-keys=0"
fi

# Import disk
log "Importing disk to $STORAGE (format=$DISK_FORMAT)..."
IMPORT_OUTPUT=$(qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$DISK_FORMAT" 2>&1)
echo "$IMPORT_OUTPUT" >> "$LOG_FILE"
log "Import complete."

# Discover the imported disk reference from the VM config (shows as unused0)
IMPORTED_DISK=$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^unused0:/{print $2}')

# Fallback: parse the importdisk output line if unused0 is missing
if [[ -z "$IMPORTED_DISK" ]]; then
    IMPORTED_DISK=$(echo "$IMPORT_OUTPUT" | grep -oP "(?<=as ')unused0:\K[^']+" 2>/dev/null || true)
fi

# Last resort: guess the conventional name
if [[ -z "$IMPORTED_DISK" ]]; then
    if [[ "$BIOS_TYPE" == "ovmf" ]]; then
        IMPORTED_DISK="${STORAGE}:vm-${VMID}-disk-1"
    else
        IMPORTED_DISK="${STORAGE}:vm-${VMID}-disk-0"
    fi
    warn "Could not auto-detect imported disk name. Guessing: $IMPORTED_DISK"
fi

log "Attaching disk: $IMPORTED_DISK"
qm set "$VMID" --scsi0 "$IMPORTED_DISK"
qm set "$VMID" --boot order=scsi0
qm resize "$VMID" scsi0 "${DISK_SIZE}G" 2>/dev/null || true

# ==============================================================================
# 7. POST-CONVERSION VALIDATION
# ==============================================================================

log "Running post-conversion validation..."

CHECKS_PASSED=0
CHECKS_TOTAL=0

run_check() {
    local name="$1"
    local result="$2"  # 0 = pass, non-zero = fail
    local detail="${3:-}"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    if [[ "$result" -eq 0 ]]; then
        ok "CHECK: $name ${detail:+— $detail}"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        err "CHECK: $name ${detail:+— $detail}"
    fi
}

# Check 1: VM config exists
qm config "$VMID" >/dev/null 2>&1
run_check "VM config exists" $? ""

# Check 2: Disk is attached
DISK_ATTACHED=$(qm config "$VMID" 2>/dev/null | grep -c "scsi0:")
run_check "Disk attached (scsi0)" $([[ "$DISK_ATTACHED" -ge 1 ]] && echo 0 || echo 1) ""

# Check 3: Boot order set
BOOT_ORDER=$(qm config "$VMID" 2>/dev/null | grep "^boot:" | head -1)
run_check "Boot order configured" $([[ -n "$BOOT_ORDER" ]] && echo 0 || echo 1) "$BOOT_ORDER"

# Check 4: Network configured
NET_CONFIG=$(qm config "$VMID" 2>/dev/null | grep "^net0:")
run_check "Network interface (net0)" $([[ -n "$NET_CONFIG" ]] && echo 0 || echo 1) ""

# Check 5: EFI disk (if UEFI)
if [[ "$BIOS_TYPE" == "ovmf" ]]; then
    EFI_DISK=$(qm config "$VMID" 2>/dev/null | grep -c "efidisk0:")
    run_check "EFI disk attached" $([[ "$EFI_DISK" -ge 1 ]] && echo 0 || echo 1) ""
fi

# Check 6: QEMU agent enabled
AGENT_SET=$(qm config "$VMID" 2>/dev/null | grep -c "agent:")
run_check "QEMU guest agent enabled" $([[ "$AGENT_SET" -ge 1 ]] && echo 0 || echo 1) ""

log "Validation: ${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed."

# --- Auto-start & live health checks ---
if $AUTO_START; then
    if [[ "$CHECKS_PASSED" -lt "$CHECKS_TOTAL" ]]; then
        warn "Not all checks passed. Starting VM anyway (some issues may exist)..."
    fi

    log "Starting VM $VMID..."
    qm start "$VMID"

    # Wait for QEMU guest agent (up to 120 seconds)
    log "Waiting for VM to boot and guest agent to respond (up to 120s)..."
    AGENT_OK=false
    for i in $(seq 1 24); do
        if qm agent "$VMID" ping >/dev/null 2>&1; then
            AGENT_OK=true
            break
        fi
        sleep 5
    done

    if $AGENT_OK; then
        ok "Guest agent is responding!"

        # Get network info from agent
        GUEST_IP=$(qm agent "$VMID" network-get-interfaces 2>/dev/null \
            | grep -A5 '"name": "ens18"' \
            | grep '"ip-address"' \
            | head -1 \
            | grep -oP '"ip-address"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")

        if [[ "$GUEST_IP" != "unknown" && -n "$GUEST_IP" ]]; then
            ok "VM network is up — IP: $GUEST_IP"
            # Quick reachability test
            if ping -c 1 -W 3 "$GUEST_IP" >/dev/null 2>&1; then
                ok "VM is reachable at $GUEST_IP"
            else
                warn "VM has IP $GUEST_IP but is not responding to ping (firewall?)"
            fi
        else
            warn "Could not determine VM IP address via guest agent."
        fi

        # Get OS info from agent
        GUEST_OS=$(qm agent "$VMID" get-osinfo 2>/dev/null \
            | grep -oP '"pretty-name"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
        [[ "$GUEST_OS" != "unknown" ]] && ok "Guest OS: $GUEST_OS"
    else
        warn "Guest agent did not respond within 120s. VM may still be booting."
        warn "Check manually: qm terminal $VMID -iface serial0"
    fi
fi

# ==============================================================================
# 8. COMPLETION SUMMARY
# ==============================================================================

echo ""
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo -e "${GREEN}${BOLD}         CONVERSION COMPLETE${NC}"
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo ""
echo -e "  ${BOLD}VM ID:${NC}       $VMID"
echo -e "  ${BOLD}Memory:${NC}      ${MEMORY}MB"
echo -e "  ${BOLD}Cores:${NC}       $CORES"
echo -e "  ${BOLD}Disk:${NC}        ${DISK_SIZE}GB ($DISK_FORMAT)"
echo -e "  ${BOLD}Firmware:${NC}    $BIOS_TYPE"
echo -e "  ${BOLD}Distro:${NC}      $DISTRO_FAMILY (${DISTRO_ID:-unknown})"
echo -e "  ${BOLD}Network:${NC}     $($KEEP_NETWORK && echo 'preserved' || echo 'DHCP on ens18') (bridge: $BRIDGE)"
echo -e "  ${BOLD}Validation:${NC}  ${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed"
echo -e "  ${BOLD}Log:${NC}         $LOG_FILE"
echo ""
if ! $AUTO_START; then
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "    1. Review VM config:  ${BOLD}qm config $VMID${NC}"
    echo -e "    2. Start the VM:      ${BOLD}qm start $VMID${NC}"
    echo -e "    3. Open console:      ${BOLD}qm terminal $VMID -iface serial0${NC}"
else
    echo -e "  ${GREEN}VM $VMID is running.${NC}"
    echo -e "  Open console: ${BOLD}qm terminal $VMID -iface serial0${NC}"
fi
echo ""