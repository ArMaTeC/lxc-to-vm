#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox Disk Clone & Replace Tool
# Version: 1.0.0
# ==============================================================================
#
# DESCRIPTION:
#   Clones a VM or LXC disk to a new volume (optionally larger), then replaces
#   the active disk with the clone. Useful when disk expansion isn't recognized
#   by the guest OS, or for disk migration between storage backends.
#
# USE CASES:
#   - Fix disks that show expanded size in Proxmox but not in guest OS
#   - Migrate disks between storage backends (e.g., local-lvm to ZFS)
#   - Create resized clones for capacity increases
#   - Replace corrupted or problematic disk images
#
# WORKFLOW:
#   1. Stop VM/Container (required for safety)
#   2. Clone source disk to new target disk (with optional resize)
#   3. Detach old disk from config (keep for backup/safety)
#   4. Attach new disk to config
#   5. Remove old disk (optional, with --remove-old flag)
#
# SUPPORTED STORAGE:
#   - LVM-thin, LVM (thick)
#   - Directory (qcow2, raw)
#   - ZFS (zfspool)
#   - Cross-storage cloning supported
#
# SAFETY FEATURES:
#   - Dry-run mode for preview
#   - Original disk kept unless --remove-old specified
#   - Automatic rollback on failure
#   - Snapshots before operations (optional)
#
# LICENSE: MIT
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly LOG_FILE="/var/log/clone-replace-disk.log"

# ==============================================================================
# CONSTANTS
# ==============================================================================
readonly MIN_DISK_GB=2
readonly REQUIRED_CMDS=(qemu-img pvesm)

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
DEBUG=${CLONE_REPLACE_DEBUG:-0}

if [[ "${DEBUG:-0}" -eq 1 ]]; then
    export PS4='[${BASH_SOURCE}:${LINENO}] '
    set -x
fi

debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$LOG_FILE"
}

verbose() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VERBOSE] $*" >> "$LOG_FILE"
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[*]${NC} $*"
    fi
}

readonly E_INVALID_ARG=1
readonly E_NOT_FOUND=2
readonly E_DISK_FULL=3
readonly E_PERMISSION=4
readonly E_CLONE_FAILED=5
readonly E_REPLACE_FAILED=6

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

e() { echo -e "$*"; }
log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
die() { err "$*"; exit "${E_INVALID_ARG}"; }

error_reason_and_fix() {
    local failed_cmd="$1"
    local reason="Command failed during clone/replace workflow."
    local fix="Check the log and verify storage availability."

    case "$failed_cmd" in
        *"pct config"*|*"qm config"*)
            reason="VM/Container configuration read failed."
            fix="Verify ID exists and check Proxmox storage health."
            ;;
        *"qemu-img"*)
            reason="Disk clone operation failed."
            fix="Check storage space and disk image integrity."
            ;;
        *"lvcreate"*)
            reason="LVM volume creation failed."
            fix="Check VG free space: vgs"
            ;;
        *"zfs create"*)
            reason="ZFS volume creation failed."
            fix="Check ZFS pool space: zpool list"
            ;;
        *"pct set"*|*"qm set"*)
            reason="Configuration update failed."
            fix="Check if disk is in use or locked."
            ;;
    esac

    printf '%s|%s\n' "$reason" "$fix"
}

error_exit_code() {
    local failed_cmd="$1"
    case "$failed_cmd" in
        *"pct config"*|*"qm config"*)
            echo "$E_NOT_FOUND"
            ;;
        *"qemu-img"*|*"lvcreate"*|*"zfs create"*)
            echo "$E_CLONE_FAILED"
            ;;
        *"pct set"*|*"qm set"*)
            echo "$E_REPLACE_FAILED"
            ;;
        *)
            echo "$E_INVALID_ARG"
            ;;
    esac
}

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    local src_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    local failed_cmd="${BASH_COMMAND:-unknown}"
    local reason_fix reason fix mapped_code

    trap - ERR
    reason_fix=$(error_reason_and_fix "$failed_cmd")
    reason="${reason_fix%%|*}"
    fix="${reason_fix#*|}"
    mapped_code=$(error_exit_code "$failed_cmd")

    err "Unhandled error (raw exit ${exit_code}, mapped exit ${mapped_code}) at ${src_file}:${line_no}"
    err "Failed command: ${failed_cmd}"
    warn "Likely reason: ${reason}"
    warn "Suggested fix: ${fix}"
    warn "Log tail (${LOG_FILE}):"
    tail -n 40 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' >&2 || true

    # Attempt rollback if we have a backup
    if [[ -n "${OLD_DISK_REF:-}" && -n "${ID:-}" && "${TYPE:-}" == "vm" ]]; then
        warn "Attempting rollback..."
        qm set "$ID" --${DISK_NAME} "${OLD_DISK_REF}" 2>/dev/null || true
    elif [[ -n "${OLD_DISK_REF:-}" && -n "${ID:-}" && "${TYPE:-}" == "lxc" ]]; then
        warn "Attempting rollback..."
        pct set "$ID" --rootfs "${OLD_DISK_REF},size=${CURRENT_SIZE_GB}G" 2>/dev/null || true
    fi

    exit "$mapped_code"
}
trap 'on_error' ERR

usage() {
    cat <<USAGE
${BOLD}Proxmox Disk Clone & Replace Tool v${VERSION}${NC}

Clones a VM or LXC disk to a new volume and replaces the active disk.

Usage: $0 [OPTIONS]

OPTIONS:
  -t, --type <lxc|vm>    Type: lxc or vm (required)
  -i, --id <ID>          VM or Container ID (required)
  -d, --disk <NAME>      Disk name for VMs: scsi0, virtio0, ide0, sata0 (default: auto-detect)
  -s, --storage <NAME>   Target storage for clone (default: same as source)
  --size <GB>            Target size for clone (default: same as source, or larger to expand)
  --format <raw|qcow2>   Target format (default: same as source)
  --name <NAME>          Custom name for cloned disk (default: auto-generated)
  --remove-old           Remove old disk after successful replace (DANGEROUS)
  --snapshot             Create snapshot before operations (VMs only)
  --keep-old             Keep old disk attached as backup (default behavior)
  -n, --dry-run          Show what would be done without making changes
  --force                Skip confirmation prompts
  -h, --help             Show this help message
  -V, --version          Show version

EXPANSION FIX MODE (for OS not seeing new size):
  $0 -t lxc -i 100 --size 200    # Clone 100's disk, expand to 200GB, replace

MIGRATION MODE (cross-storage):
  $0 -t vm -i 100 -s zfspool     # Clone to ZFS pool, replace original

Examples:
  $0 -t lxc -i 100               # Clone and replace CT 100 disk
  $0 -t vm -i 200 -d scsi0       # Clone and replace VM 200 scsi0
  $0 -t lxc -i 100 --size 150    # Clone with expansion to 150GB
  $0 -t vm -i 200 --remove-old   # Clone, replace, remove original

Safety Notes:
  - VM/Container will be stopped during operation
  - Old disk is kept by default (use --remove-old to delete)
  - Always backup critical data before operations
USAGE
    exit 0
}

if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

mkdir -p "$(dirname "$LOG_FILE")"
echo "--- clone-replace-disk run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ==============================================================================
TYPE=""
ID=""
DISK_NAME=""
TARGET_STORAGE=""
TARGET_SIZE=""
TARGET_FORMAT=""
CUSTOM_NAME=""
REMOVE_OLD=false
SNAPSHOT=false
KEEP_OLD=true
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)       TYPE="$2"; shift 2 ;;
        -i|--id)         ID="$2"; shift 2 ;;
        -d|--disk)       DISK_NAME="$2"; shift 2 ;;
        -s|--storage)    TARGET_STORAGE="$2"; shift 2 ;;
        --size)          TARGET_SIZE="$2"; shift 2 ;;
        --format)        TARGET_FORMAT="$2"; shift 2 ;;
        --name)          CUSTOM_NAME="$2"; shift 2 ;;
        --remove-old)    REMOVE_OLD=true; KEEP_OLD=false; shift ;;
        --snapshot)      SNAPSHOT=true; shift ;;
        --keep-old)      KEEP_OLD=true; REMOVE_OLD=false; shift ;;
        -n|--dry-run)    DRY_RUN=true; shift ;;
        --force)         FORCE=true; shift ;;
        -h|--help)       usage ;;
        -V|--version)    echo "v${VERSION}"; exit 0 ;;
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

e "${BOLD}========================================${NC}"
e "${BOLD}  DISK CLONE & REPLACE TOOL v${VERSION}${NC}"
e "${BOLD}========================================${NC}"

# ==============================================================================
# INPUT VALIDATION
# ==============================================================================
[[ -z "$TYPE" ]] && read -rp "Type (lxc or vm): " TYPE
[[ -z "$ID" ]] && read -rp "ID: " ID

[[ "$TYPE" =~ ^(lxc|vm)$ ]] || die "Type must be 'lxc' or 'vm', got: '$TYPE'"
[[ "$ID" =~ ^[0-9]+$ ]] || die "ID must be a positive integer, got: '$ID'"

# Validate ID exists
if [[ "$TYPE" == "lxc" ]]; then
    if ! pct config "$ID" >/dev/null 2>&1; then
        die "Container $ID does not exist."
    fi
else
    if ! qm config "$ID" >/dev/null 2>&1; then
        die "VM $ID does not exist."
    fi
fi

if [[ -n "$TARGET_SIZE" ]]; then
    [[ "$TARGET_SIZE" =~ ^[0-9]+$ ]] || die "Size must be a positive integer (GB), got: '$TARGET_SIZE'"
    [[ "$TARGET_SIZE" -ge "$MIN_DISK_GB" ]] || die "Size must be at least ${MIN_DISK_GB}GB."
fi

# ==============================================================================
# DETECT SOURCE DISK
# ==============================================================================
log "Analyzing $TYPE $ID..."

if [[ "$TYPE" == "lxc" ]]; then
    # LXC: Get rootfs
    DISK_CONFIG=$(pct config "$ID" | grep "^rootfs:")
    [[ -n "$DISK_CONFIG" ]] || die "Could not find rootfs for CT $ID."
    
    DISK_REF=$(echo "$DISK_CONFIG" | sed 's/^rootfs: //' | cut -d',' -f1)
    SOURCE_STORAGE=$(echo "$DISK_REF" | cut -d':' -f1)
    CURRENT_SIZE_STR=$(echo "$DISK_CONFIG" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")
    
else
    # VM: Get disk (auto-detect or use specified)
    if [[ -z "$DISK_NAME" ]]; then
        DISK_CONFIG=$(qm config "$ID" | grep -E '^(scsi0|virtio0|ide0|sata0):' | head -1)
        [[ -n "$DISK_CONFIG" ]] || die "Could not find primary disk for VM $ID."
        DISK_NAME=$(echo "$DISK_CONFIG" | cut -d: -f1)
    else
        DISK_CONFIG=$(qm config "$ID" | grep "^${DISK_NAME}:")
        [[ -n "$DISK_CONFIG" ]] || die "Could not find disk $DISK_NAME for VM $ID."
    fi
    
    DISK_REF=$(echo "$DISK_CONFIG" | cut -d: -f2- | tr -d ' ' | cut -d',' -f1)
    SOURCE_STORAGE=$(echo "$DISK_REF" | cut -d':' -f1)
    CURRENT_SIZE_STR=$(echo "$DISK_CONFIG" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")
fi

[[ -n "$DISK_REF" ]] || die "Could not determine disk reference."
[[ -n "$CURRENT_SIZE_STR" ]] || die "Could not determine current disk size."
CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+')

log "Source disk: $DISK_REF"
log "Source storage: $SOURCE_STORAGE"
log "Current size: ${CURRENT_SIZE_GB}GB"

# Determine source format
SOURCE_PATH=$(pvesm path "$DISK_REF" 2>/dev/null)
if [[ -f "$SOURCE_PATH" ]]; then
    SOURCE_FORMAT=$(qemu-img info "$SOURCE_PATH" 2>/dev/null | awk '/file format:/{print $3}')
else
    SOURCE_FORMAT="raw"
fi
log "Source format: $SOURCE_FORMAT"

# ==============================================================================
# SET DEFAULTS
# ==============================================================================
TARGET_STORAGE="${TARGET_STORAGE:-$SOURCE_STORAGE}"
TARGET_SIZE="${TARGET_SIZE:-$CURRENT_SIZE_GB}"
TARGET_FORMAT="${TARGET_FORMAT:-$SOURCE_FORMAT}"

# Generate target name
if [[ -n "$CUSTOM_NAME" ]]; then
    TARGET_VOLUME="$CUSTOM_NAME"
else
    # Generate name: vm-{id}-disk-clone-{timestamp}
    TIMESTAMP=$(date +%s)
    if [[ "$TYPE" == "lxc" ]]; then
        TARGET_VOLUME="vm-${ID}-disk-clone-${TIMESTAMP}"
    else
        TARGET_VOLUME="vm-${ID}-disk-clone-${TIMESTAMP}"
    fi
fi

TARGET_REF="${TARGET_STORAGE}:${TARGET_VOLUME}"

log "Target: $TARGET_REF"
log "Target size: ${TARGET_SIZE}GB"
log "Target format: $TARGET_FORMAT"

# ==============================================================================
# CHECK STATUS
# ==============================================================================
if [[ "$TYPE" == "lxc" ]]; then
    STATUS=$(pct status "$ID" 2>/dev/null | awk '{print $2}')
else
    STATUS=$(qm status "$ID" 2>/dev/null | awk '{print $2}')
fi

WAS_RUNNING=false
if [[ "$STATUS" == "running" ]]; then
    WAS_RUNNING=true
    log "$TYPE $ID is running. Will stop for disk operations."
fi

# ==============================================================================
# DRY-RUN SUMMARY
# ==============================================================================
if $DRY_RUN; then
    echo ""
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}Type:${NC}         $TYPE"
    e "  ${BOLD}ID:${NC}           $ID"
    e "  ${BOLD}Source:${NC}       $DISK_REF (${CURRENT_SIZE_GB}GB, $SOURCE_FORMAT)"
    e "  ${BOLD}Target:${NC}       $TARGET_REF (${TARGET_SIZE}GB, $TARGET_FORMAT)"
    [[ -n "${DISK_NAME:-}" ]] && e "  ${BOLD}VM Disk:${NC}       $DISK_NAME"
    echo ""
    e "  ${BOLD}Steps:${NC}"
    $WAS_RUNNING && echo "    1. Stop $TYPE $ID"
    echo "    2. Clone disk: $DISK_REF → $TARGET_REF"
    [[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]] && echo "    3. Expand clone to ${TARGET_SIZE}GB"
    echo "    4. Detach old disk from config"
    echo "    5. Attach new disk to config"
    $REMOVE_OLD && echo "    6. Remove old disk (DANGEROUS)"
    $WAS_RUNNING && echo "    7. Start $TYPE $ID"
    echo ""
    ok "Dry run complete."
    exit 0
fi

# ==============================================================================
# USER CONFIRMATION
# ==============================================================================
if ! $FORCE; then
    echo ""
    e "${YELLOW}${BOLD}WARNING: This will clone and replace the disk for $TYPE $ID${NC}"
    e "  ${BOLD}Source:${NC} $DISK_REF (${CURRENT_SIZE_GB}GB)"
    e "  ${BOLD}Target:${NC} $TARGET_REF (${TARGET_SIZE}GB)"
    [[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]] && e "  ${YELLOW}Expansion: +$((TARGET_SIZE - CURRENT_SIZE_GB))GB${NC}"
    $REMOVE_OLD && e "  ${RED}Old disk will be REMOVED!${NC}"
    ! $REMOVE_OLD && e "  ${GREEN}Old disk will be kept as backup${NC}"
    echo ""
    read -rp "Continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 0; }
fi

# ==============================================================================
# CREATE SNAPSHOT (VM only)
# ==============================================================================
if $SNAPSHOT && [[ "$TYPE" == "vm" ]]; then
    SNAP_NAME="pre-clone-$(date +%s)"
    log "Creating snapshot: $SNAP_NAME"
    qm snapshot "$ID" "$SNAP_NAME" || warn "Snapshot creation failed, continuing..."
fi

# ==============================================================================
# STOP VM/CONTAINER
# ==============================================================================
if $WAS_RUNNING; then
    log "Stopping $TYPE $ID..."
    if [[ "$TYPE" == "lxc" ]]; then
        pct stop "$ID"
    else
        qm stop "$ID"
    fi
    sleep 3
fi

# ==============================================================================
# CLONE DISK
# ==============================================================================
log "Cloning disk..."
log "Source: $SOURCE_PATH"

# Determine target storage type
TARGET_STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$TARGET_STORAGE" '$1==s{print $2}')
log "Target storage type: $TARGET_STORAGE_TYPE"

# Create clone based on storage type
case "$TARGET_STORAGE_TYPE" in
    lvmthin|lvm)
        # For LVM, we need to create LV and then copy
        log "Creating LVM volume: $TARGET_VOLUME (${TARGET_SIZE}G)"
        VG_NAME=$(pvesm path "$TARGET_REF" 2>/dev/null | cut -d'/' -f3 || vgs --noheadings -o vg_name | head -1 | tr -d ' ')
        [[ -n "$VG_NAME" ]] || die "Could not determine VG name for $TARGET_STORAGE"
        
        LV_PATH="/dev/${VG_NAME}/${TARGET_VOLUME}"
        
        # Create LV
        if ! lvcreate -y -L "${TARGET_SIZE}G" -n "$TARGET_VOLUME" "$VG_NAME" 2>&1 | tee -a "$LOG_FILE"; then
            die "Failed to create LVM volume"
        fi
        
        # Copy data
        log "Copying data to LVM volume..."
        if [[ "$SOURCE_FORMAT" == "qcow2" ]]; then
            qemu-img convert -f qcow2 -O raw "$SOURCE_PATH" "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"
        else
            qemu-img convert -f raw -O raw "$SOURCE_PATH" "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        # Expand if needed
        if [[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]]; then
            log "Expanding filesystem to ${TARGET_SIZE}GB..."
            e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || true
            resize2fs "$LV_PATH" >> "$LOG_FILE" 2>&1 || warn "Filesystem resize had issues"
        fi
        ;;
    
    zfspool)
        log "Creating ZFS volume..."
        ZFS_POOL=$(pvesm path "$TARGET_REF" 2>/dev/null | sed 's|/dev/zvol/||' | cut -d'/' -f1)
        [[ -n "$ZFS_POOL" ]] || die "Could not determine ZFS pool"
        
        ZFS_PATH="${ZFS_POOL}/${TARGET_VOLUME}"
        
        # Create ZVOL
        if ! zfs create -V "${TARGET_SIZE}G" "$ZFS_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            die "Failed to create ZFS volume"
        fi
        
        ZVOL_DEV="/dev/zvol/${ZFS_PATH}"
        
        # Copy data
        log "Copying data to ZFS volume..."
        if [[ "$SOURCE_FORMAT" == "qcow2" ]]; then
            qemu-img convert -f qcow2 -O raw "$SOURCE_PATH" "$ZVOL_DEV" 2>&1 | tee -a "$LOG_FILE"
        else
            qemu-img convert -f raw -O raw "$SOURCE_PATH" "$ZVOL_DEV" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        # Expand if needed
        if [[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]]; then
            log "Expanding filesystem..."
            e2fsck -f -y "$ZVOL_DEV" >> "$LOG_FILE" 2>&1 || true
            resize2fs "$ZVOL_DEV" >> "$LOG_FILE" 2>&1 || warn "Filesystem resize had issues"
        fi
        ;;
    
    dir|nfs|cifs|glusterfs)
        # Directory-based storage
        TARGET_DIR=$(pvesm path "$TARGET_STORAGE:dummy" 2>/dev/null | xargs dirname)
        [[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]] || die "Could not determine target directory"
        
        TARGET_PATH="${TARGET_DIR}/${TARGET_VOLUME}"
        
        # Determine extension based on format
        if [[ "$TARGET_FORMAT" == "qcow2" ]]; then
            TARGET_PATH="${TARGET_PATH}.qcow2"
        fi
        
        log "Creating disk image: $TARGET_PATH"
        
        # Create/convert image
        if [[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]]; then
            # Clone then resize
            log "Cloning and expanding to ${TARGET_SIZE}GB..."
            qemu-img convert -f "$SOURCE_FORMAT" -O "$TARGET_FORMAT" "$SOURCE_PATH" "$TARGET_PATH" 2>&1 | tee -a "$LOG_FILE"
            qemu-img resize -f "$TARGET_FORMAT" "$TARGET_PATH" "${TARGET_SIZE}G" 2>&1 | tee -a "$LOG_FILE"
            
            # Mount and expand filesystem
            if [[ "$TARGET_FORMAT" == "raw" ]]; then
                LOOP_DEV=$(losetup --show -f "$TARGET_PATH")
                trap "losetup -d '$LOOP_DEV' 2>/dev/null || true" EXIT
                e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || true
                resize2fs "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || warn "Filesystem resize had issues"
                losetup -d "$LOOP_DEV" 2>/dev/null || true
                trap - EXIT
            fi
        else
            # Just clone
            qemu-img convert -f "$SOURCE_FORMAT" -O "$TARGET_FORMAT" "$SOURCE_PATH" "$TARGET_PATH" 2>&1 | tee -a "$LOG_FILE"
        fi
        ;;
    
    *)
        die "Unsupported target storage type: $TARGET_STORAGE_TYPE"
        ;;
esac

ok "Disk cloned successfully."

# ==============================================================================
# UPDATE CONFIG - REPLACE DISK
# ==============================================================================
log "Updating configuration..."

# Store old reference for potential rollback
OLD_DISK_REF="$DISK_REF"

if [[ "$TYPE" == "lxc" ]]; then
    # LXC: Replace rootfs
    log "Updating LXC rootfs..."
    pct set "$ID" --rootfs "${TARGET_REF},size=${TARGET_SIZE}G"
    
    # Verify
    NEW_CONFIG=$(pct config "$ID" | grep "^rootfs:")
    log "New config: $NEW_CONFIG"
else
    # VM: Replace disk
    log "Updating VM disk $DISK_NAME..."
    
    # First, detach old disk (don't delete yet)
    qm set "$ID" --delete "$DISK_NAME" 2>&1 | tee -a "$LOG_FILE" || warn "Detach may have issues, continuing..."
    
    # Attach new disk
    qm set "$ID" --${DISK_NAME} "${TARGET_REF},size=${TARGET_SIZE}G" 2>&1 | tee -a "$LOG_FILE"
    
    # Verify
    NEW_CONFIG=$(qm config "$ID" | grep "^${DISK_NAME}:")
    log "New config: $NEW_CONFIG"
fi

ok "Configuration updated."

# ==============================================================================
# REMOVE OLD DISK (if requested)
# ==============================================================================
if $REMOVE_OLD; then
    log "Removing old disk: $DISK_REF"
    warn "This is IRREVERSIBLE!"
    sleep 2
    
    # Determine old disk path and remove
    OLD_PATH=$(pvesm path "$DISK_REF" 2>/dev/null || true)
    if [[ -n "$OLD_PATH" && -e "$OLD_PATH" ]]; then
        if [[ -f "$OLD_PATH" ]]; then
            rm -f "$OLD_PATH"
        elif [[ -L "$OLD_PATH" ]] || lvdisplay "$OLD_PATH" &>/dev/null; then
            lvremove -y "$OLD_PATH" 2>&1 | tee -a "$LOG_FILE" || warn "Could not remove LVM volume"
        elif [[ "$OLD_PATH" == *"/zvol/"* ]]; then
            ZFS_OLD="${OLD_PATH#/dev/zvol/}"
            zfs destroy "$ZFS_OLD" 2>&1 | tee -a "$LOG_FILE" || warn "Could not destroy ZFS volume"
        fi
    fi
    
    # Try using pvesm free if available
    pvesm free "$DISK_REF" 2>/dev/null || true
    
    ok "Old disk removed."
else
    log "Old disk kept as backup: $DISK_REF"
    log "To remove later: pvesm free $DISK_REF"
fi

# ==============================================================================
# RESTART
# ==============================================================================
if $WAS_RUNNING; then
    log "Starting $TYPE $ID..."
    if [[ "$TYPE" == "lxc" ]]; then
        pct start "$ID"
    else
        qm start "$ID"
    fi
    sleep 3
    
    if [[ "$TYPE" == "lxc" ]]; then
        NEW_STATUS=$(pct status "$ID" 2>/dev/null | awk '{print $2}')
    else
        NEW_STATUS=$(qm status "$ID" 2>/dev/null | awk '{print $2}')
    fi
    
    if [[ "$NEW_STATUS" == "running" ]]; then
        ok "$TYPE $ID is running."
    else
        warn "$TYPE $ID did not start. Check manually."
    fi
fi

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
echo ""
e "${GREEN}${BOLD}========================================${NC}"
e "${GREEN}${BOLD}    CLONE & REPLACE COMPLETE${NC}"
e "${GREEN}${BOLD}========================================${NC}"
echo ""
e "  ${BOLD}Type:${NC}         $TYPE"
e "  ${BOLD}ID:${NC}           $ID"
e "  ${BOLD}Old Disk:${NC}     $DISK_REF (${CURRENT_SIZE_GB}GB)"
e "  ${BOLD}New Disk:${NC}     $TARGET_REF (${TARGET_SIZE}GB)"
[[ "$TARGET_SIZE" -gt "$CURRENT_SIZE_GB" ]] && e "  ${BOLD}Expanded:${NC}     +$((TARGET_SIZE - CURRENT_SIZE_GB))GB"
$REMOVE_OLD && e "  ${BOLD}Old disk:${NC}     ${RED}REMOVED${NC}"
! $REMOVE_OLD && e "  ${BOLD}Old disk:${NC}     ${GREEN}Kept as backup${NC}"
e "  ${BOLD}Log:${NC}         $LOG_FILE"
echo ""
e "  ${YELLOW}Next steps:${NC}"
e "    - Verify disk inside guest: df -h"
e "    - If expanding: resize2fs /dev/sda1 (or appropriate device)"
! $REMOVE_OLD && e "    - Remove old disk when ready: pvesm free $DISK_REF"
echo ""
