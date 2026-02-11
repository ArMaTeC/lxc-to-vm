#!/usr/bin/env bash

# ==============================================================================
# Proxmox LXC Disk Shrinker
# Version: 1.0.0
# Shrinks an LXC container's disk to current usage + 1GB headroom.
# Supports: LVM-thin, directory-based (raw/qcow2), and ZFS storage.
# License: MIT
# ==============================================================================

set -euo pipefail

VERSION="1.0.0"
LOG_FILE="/var/log/shrink-lxc.log"
HEADROOM_GB=1  # Extra space above used data

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

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
die()  { err "$*"; exit 1; }

usage() {
    cat <<USAGE
${BOLD}Proxmox LXC Disk Shrinker v${VERSION}${NC}

Shrinks an LXC container's root disk to current usage + ${HEADROOM_GB}GB.
This reduces the disk size required for conversion with lxc-to-vm.sh.

Usage: $0 [OPTIONS]

Options:
  -c, --ctid <ID>        Container ID to shrink
  -g, --headroom <GB>    Extra headroom in GB above used space (default: ${HEADROOM_GB})
  -n, --dry-run          Show what would be done without making changes
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0 -c 100                  # Shrink CT 100 to usage + 1GB
  $0 -c 100 -g 2             # Shrink CT 100 to usage + 2GB
  $0 -c 100 --dry-run        # Preview only
USAGE
    exit 0
}

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

mkdir -p "$(dirname "$LOG_FILE")"
echo "--- shrink-lxc run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

CTID="" DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)      CTID="$2";         shift 2 ;;
        -g|--headroom)   HEADROOM_GB="$2";  shift 2 ;;
        -n|--dry-run)    DRY_RUN=true;      shift ;;
        -h|--help)       usage ;;
        -V|--version)    echo "v${VERSION}"; exit 0 ;;
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}     PROXMOX LXC DISK SHRINKER v${VERSION}${NC}"
echo -e "${BOLD}==========================================${NC}"

# Interactive prompt if CTID not provided
[[ -z "$CTID" ]] && read -rp "Enter Container ID to shrink (e.g., 100): " CTID

# Validate
[[ "$CTID" =~ ^[0-9]+$ ]]        || die "Container ID must be a positive integer, got: '$CTID'"
[[ "$HEADROOM_GB" =~ ^[0-9]+$ ]] || die "Headroom must be a positive integer (GB), got: '$HEADROOM_GB'"
[[ "$HEADROOM_GB" -ge 1 ]]       || die "Headroom must be at least 1 GB."

if ! pct config "$CTID" >/dev/null 2>&1; then
    die "Container $CTID does not exist."
fi

# ==============================================================================
# DETECT STORAGE & CURRENT DISK
# ==============================================================================

# Parse rootfs line from container config
ROOTFS_LINE=$(pct config "$CTID" | grep "^rootfs:")
[[ -n "$ROOTFS_LINE" ]] || die "Could not find rootfs config for container $CTID."
log "Config rootfs: $ROOTFS_LINE"

# Extract storage name and volume, and current size
# Format: rootfs: <storage>:<volume>,size=<N>G
ROOTFS_VOL=$(echo "$ROOTFS_LINE" | sed 's/^rootfs: //' | cut -d',' -f1)
STORAGE_NAME=$(echo "$ROOTFS_VOL" | cut -d':' -f1)
VOLUME_ID=$(echo "$ROOTFS_VOL" | cut -d':' -f2)
CURRENT_SIZE_STR=$(echo "$ROOTFS_LINE" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")

log "Storage: $STORAGE_NAME | Volume: $VOLUME_ID | Current size: ${CURRENT_SIZE_STR:-unknown}"

# Detect storage type
STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE_NAME" '$1==s{print $2}')
[[ -n "$STORAGE_TYPE" ]] || die "Could not determine storage type for '$STORAGE_NAME'."
log "Storage type: $STORAGE_TYPE"

# ==============================================================================
# STOP CONTAINER
# ==============================================================================

CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
CT_WAS_RUNNING=false

if [[ "$CT_STATUS" == "running" ]]; then
    CT_WAS_RUNNING=true
    if $DRY_RUN; then
        warn "Container $CTID is running. Would stop it."
    else
        warn "Container $CTID is running. Stopping..."
        pct stop "$CTID"
        sleep 2
    fi
fi

# ==============================================================================
# CALCULATE USED SPACE
# ==============================================================================

log "Mounting container to calculate used space..."

if ! $DRY_RUN; then
    pct mount "$CTID"
fi

# Find the rootfs mount path
LXC_ROOT_MOUNT=""
for candidate in "/var/lib/lxc/${CTID}/rootfs" "/var/lib/lxc/${CTID}/rootfs/"; do
    if [[ -d "$candidate" ]]; then
        LXC_ROOT_MOUNT="$candidate"
        break
    fi
done

if $DRY_RUN && [[ -z "$LXC_ROOT_MOUNT" ]]; then
    # In dry-run we may not have mounted, estimate from pct df
    USED_BYTES=$(pct df "$CTID" 2>/dev/null | awk '/^rootfs/{print $3}' || echo "0")
    # pct df reports in bytes or KB depending on version
    if [[ "$USED_BYTES" -gt 0 ]]; then
        USED_MB=$((USED_BYTES / 1024 / 1024))
    else
        die "Cannot determine used space in dry-run mode. Run without --dry-run."
    fi
else
    [[ -n "$LXC_ROOT_MOUNT" ]] || die "Could not locate rootfs for container $CTID."

    # Calculate used space (excluding virtual filesystems)
    USED_BYTES=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
        --exclude='tmp/*' --exclude='run/*' \
        "${LXC_ROOT_MOUNT}/" 2>/dev/null | awk '{print $1}')
    USED_MB=$(( ${USED_BYTES:-0} / 1024 / 1024 ))
fi

USED_GB=$(( (USED_MB + 1023) / 1024 ))  # Round up to nearest GB
NEW_SIZE_GB=$(( USED_GB + HEADROOM_GB ))

# Ensure minimum 1GB
[[ "$NEW_SIZE_GB" -lt 1 ]] && NEW_SIZE_GB=1

USED_HR=$(numfmt --to=iec-i --suffix=B "${USED_BYTES:-0}" 2>/dev/null || echo "${USED_MB}MB")

# Get current size in GB for comparison
CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+' || echo "0")

log "Used space: ${USED_HR} (~${USED_GB}GB)"
log "Current disk: ${CURRENT_SIZE_GB}GB → Target: ${NEW_SIZE_GB}GB (usage ${USED_GB}GB + ${HEADROOM_GB}GB headroom)"

# Unmount for now
if ! $DRY_RUN; then
    pct unmount "$CTID" 2>/dev/null || true
fi

# Check if shrink is needed
if [[ "$NEW_SIZE_GB" -ge "$CURRENT_SIZE_GB" ]]; then
    ok "Disk is already close to optimal size (${CURRENT_SIZE_GB}GB). No shrink needed."
    if $CT_WAS_RUNNING && ! $DRY_RUN; then
        log "Restarting container $CTID..."
        pct start "$CTID"
    fi
    exit 0
fi

SAVINGS_GB=$((CURRENT_SIZE_GB - NEW_SIZE_GB))
log "Potential savings: ${SAVINGS_GB}GB"

# ==============================================================================
# DRY-RUN SUMMARY
# ==============================================================================

if $DRY_RUN; then
    echo ""
    echo -e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    echo -e "  ${BOLD}Container:${NC}    $CTID"
    echo -e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
    echo -e "  ${BOLD}Current disk:${NC} ${CURRENT_SIZE_GB}GB"
    echo -e "  ${BOLD}Used space:${NC}   ${USED_HR} (~${USED_GB}GB)"
    echo -e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB (usage + ${HEADROOM_GB}GB)"
    echo -e "  ${BOLD}Savings:${NC}      ${SAVINGS_GB}GB"
    echo ""
    echo -e "  ${BOLD}Steps that would be performed:${NC}"
    echo "    1. Stop container $CTID"
    case "$STORAGE_TYPE" in
        lvmthin|lvm)
            echo "    2. Run e2fsck on LV"
            echo "    3. Shrink filesystem with resize2fs to ${NEW_SIZE_GB}GB"
            echo "    4. Shrink LV with lvresize to ${NEW_SIZE_GB}GB"
            ;;
        dir|nfs|cifs|glusterfs)
            echo "    2. Mount and shrink filesystem with resize2fs"
            echo "    3. Shrink disk image with qemu-img"
            ;;
        zfspool)
            echo "    2. Create new ${NEW_SIZE_GB}GB ZFS volume"
            echo "    3. Copy data from old volume to new"
            echo "    4. Swap volumes"
            ;;
    esac
    echo "    5. Update container config"
    echo "    6. Restart container (if it was running)"
    echo ""
    ok "Dry run complete. Remove --dry-run to execute."
    if $CT_WAS_RUNNING; then
        log "Restarting container $CTID..."
        pct start "$CTID" 2>/dev/null || true
    fi
    exit 0
fi

# ==============================================================================
# CONFIRM
# ==============================================================================

echo ""
echo -e "${YELLOW}${BOLD}WARNING: This will shrink the disk for container $CTID${NC}"
echo -e "  ${BOLD}Current:${NC} ${CURRENT_SIZE_GB}GB → ${BOLD}New:${NC} ${NEW_SIZE_GB}GB (saving ${SAVINGS_GB}GB)"
echo ""
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; $CT_WAS_RUNNING && pct start "$CTID" 2>/dev/null || true; exit 0; }

# ==============================================================================
# PERFORM SHRINK (storage-type specific)
# ==============================================================================

case "$STORAGE_TYPE" in

    # --------------------------------------------------------------------------
    # LVM / LVM-THIN
    # --------------------------------------------------------------------------
    lvmthin|lvm)
        # Resolve the LV device path
        VG_NAME=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null | sed 's|/dev/||' | cut -d'/' -f1)
        LV_PATH=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)

        if [[ -z "$LV_PATH" || ! -e "$LV_PATH" ]]; then
            die "Could not resolve LV path for $ROOTFS_VOL (got: '$LV_PATH')"
        fi
        log "LV path: $LV_PATH"

        # Activate LV if needed
        lvchange -ay "$LV_PATH" 2>/dev/null || true

        # Step 1: Filesystem check (required before shrink)
        log "Running filesystem check (e2fsck)..."
        e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || {
            warn "e2fsck reported issues. Trying once more..."
            e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed. Aborting shrink."
        }
        ok "Filesystem check passed."

        # Step 2: Shrink filesystem
        log "Shrinking filesystem to ${NEW_SIZE_GB}GB..."
        resize2fs "$LV_PATH" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1
        ok "Filesystem shrunk to ${NEW_SIZE_GB}GB."

        # Step 3: Shrink LV
        log "Shrinking LV to ${NEW_SIZE_GB}GB..."
        lvresize -y -L "${NEW_SIZE_GB}G" "$LV_PATH" >> "$LOG_FILE" 2>&1
        ok "LV shrunk to ${NEW_SIZE_GB}GB."

        # Step 4: Run fsck again to verify
        log "Verifying filesystem after shrink..."
        e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || warn "Post-shrink fsck had warnings (usually harmless)."

        # Step 5: Update container config
        log "Updating container config..."
        pct set "$CTID" --rootfs "${ROOTFS_VOL},size=${NEW_SIZE_GB}G"
        ok "Container config updated."
        ;;

    # --------------------------------------------------------------------------
    # DIRECTORY-BASED (raw / qcow2)
    # --------------------------------------------------------------------------
    dir|nfs|cifs|glusterfs)
        # Find the actual disk image file
        DISK_PATH=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)
        [[ -n "$DISK_PATH" && -f "$DISK_PATH" ]] || die "Could not find disk image at: '$DISK_PATH'"
        log "Disk image: $DISK_PATH"

        # Determine image format
        IMG_FORMAT=$(qemu-img info "$DISK_PATH" 2>/dev/null | awk '/file format:/{print $3}')
        log "Image format: $IMG_FORMAT"

        if [[ "$IMG_FORMAT" == "raw" ]]; then
            # Raw image: use losetup + resize2fs + truncate

            # Mount as loop device
            LOOP_DEV=$(losetup --show -f "$DISK_PATH")
            trap "losetup -d '$LOOP_DEV' 2>/dev/null || true" EXIT

            # fsck
            log "Running filesystem check..."
            e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || {
                e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
            }

            # Shrink filesystem
            log "Shrinking filesystem to ${NEW_SIZE_GB}GB..."
            resize2fs "$LOOP_DEV" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1
            ok "Filesystem shrunk."

            # Detach loop
            losetup -d "$LOOP_DEV" 2>/dev/null || true
            trap - EXIT

            # Truncate raw image
            log "Truncating raw image to ${NEW_SIZE_GB}GB..."
            truncate -s "${NEW_SIZE_GB}G" "$DISK_PATH"
            ok "Raw image truncated."

        elif [[ "$IMG_FORMAT" == "qcow2" ]]; then
            # qcow2: convert to temp raw, shrink, convert back

            TEMP_RAW="${DISK_PATH}.shrink.raw"
            trap "rm -f '$TEMP_RAW' 2>/dev/null || true" EXIT

            log "Converting qcow2 to temporary raw image..."
            qemu-img convert -f qcow2 -O raw "$DISK_PATH" "$TEMP_RAW"

            LOOP_DEV=$(losetup --show -f "$TEMP_RAW")

            log "Running filesystem check..."
            e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || {
                e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || {
                    losetup -d "$LOOP_DEV" 2>/dev/null || true
                    die "Filesystem check failed."
                }
            }

            log "Shrinking filesystem to ${NEW_SIZE_GB}GB..."
            resize2fs "$LOOP_DEV" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1

            losetup -d "$LOOP_DEV" 2>/dev/null || true

            log "Truncating to ${NEW_SIZE_GB}GB..."
            truncate -s "${NEW_SIZE_GB}G" "$TEMP_RAW"

            log "Converting back to qcow2..."
            qemu-img convert -f raw -O qcow2 "$TEMP_RAW" "$DISK_PATH"
            rm -f "$TEMP_RAW"
            trap - EXIT
            ok "qcow2 image shrunk."
        else
            die "Unsupported image format: '$IMG_FORMAT'. Only raw and qcow2 are supported."
        fi

        # Update container config
        log "Updating container config..."
        pct set "$CTID" --rootfs "${ROOTFS_VOL},size=${NEW_SIZE_GB}G"
        ok "Container config updated."
        ;;

    # --------------------------------------------------------------------------
    # ZFS
    # --------------------------------------------------------------------------
    zfspool)
        ZFS_VOL=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)
        # pvesm path returns /dev/zvol/... — convert to dataset name
        ZFS_DATASET=$(echo "$ZFS_VOL" | sed 's|/dev/zvol/||')
        [[ -n "$ZFS_DATASET" ]] || die "Could not determine ZFS dataset for $ROOTFS_VOL"
        log "ZFS dataset: $ZFS_DATASET"

        # fsck on the zvol device
        log "Running filesystem check..."
        e2fsck -f -y "$ZFS_VOL" >> "$LOG_FILE" 2>&1 || {
            e2fsck -f -y "$ZFS_VOL" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
        }

        # Shrink filesystem
        log "Shrinking filesystem to ${NEW_SIZE_GB}GB..."
        resize2fs "$ZFS_VOL" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1
        ok "Filesystem shrunk."

        # Shrink ZFS volume
        log "Shrinking ZFS volume to ${NEW_SIZE_GB}GB..."
        zfs set volsize="${NEW_SIZE_GB}G" "$ZFS_DATASET" >> "$LOG_FILE" 2>&1
        ok "ZFS volume shrunk."

        # Verify filesystem
        log "Verifying filesystem..."
        e2fsck -f -y "$ZFS_VOL" >> "$LOG_FILE" 2>&1 || warn "Post-shrink fsck had warnings."

        # Update container config
        log "Updating container config..."
        pct set "$CTID" --rootfs "${ROOTFS_VOL},size=${NEW_SIZE_GB}G"
        ok "Container config updated."
        ;;

    *)
        die "Unsupported storage type: '$STORAGE_TYPE'. Supported: lvmthin, lvm, dir, nfs, zfspool."
        ;;
esac

# ==============================================================================
# RESTART & SUMMARY
# ==============================================================================

if $CT_WAS_RUNNING; then
    log "Restarting container $CTID..."
    pct start "$CTID"
    sleep 3
    NEW_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [[ "$NEW_STATUS" == "running" ]]; then
        ok "Container $CTID is running."
    else
        warn "Container did not start. Check: pct start $CTID"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo -e "${GREEN}${BOLD}          SHRINK COMPLETE${NC}"
echo -e "${GREEN}${BOLD}==========================================${NC}"
echo ""
echo -e "  ${BOLD}Container:${NC}    $CTID"
echo -e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
echo -e "  ${BOLD}Previous:${NC}     ${CURRENT_SIZE_GB}GB"
echo -e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB"
echo -e "  ${BOLD}Saved:${NC}        ${SAVINGS_GB}GB"
echo -e "  ${BOLD}Used space:${NC}   ${USED_HR}"
echo -e "  ${BOLD}Log:${NC}          $LOG_FILE"
echo ""
echo -e "  ${YELLOW}Ready to convert:${NC}"
echo -e "    ${BOLD}./lxc-to-vm.sh -c $CTID -d $NEW_SIZE_GB -s $STORAGE_NAME${NC}"
echo ""
