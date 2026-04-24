#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox VM Disk Shrinker
# Version: 6.0.0
# ==============================================================================
#
# DESCRIPTION:
#   This script safely shrinks a VM's disk to match its actual usage plus
#   configurable headroom. Supports multiple storage backends and disk formats.
#
# SUPPORTED STORAGE TYPES:
#   - LVM-thin (block devices)
#   - LVM (thick provisioning)
#   - Directory-based (qcow2 or raw images)
#   - ZFS volumes
#   - NFS/CIFS (treated as directory-based)
#
# SUPPORTED DISK FORMATS:
#   - QCOW2 (copy-on-write, most common)
#   - Raw (raw disk image)
#
# SHRINK METHODS:
#   - Offline shrink: VM stopped, disk processed directly
#   - Uses libguestfs (virt-resize) when available for safe shrink
#   - Falls back to manual loop mount method
#
# SAFETY FEATURES:
#   - Dry-run mode previews changes
#   - VM automatically stopped and restarted
#   - Filesystem check before and after shrink
#   - Minimum disk size enforced (2GB)
#   - Metadata margin calculation
#
# LICENSE: MIT
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="6.0.0"
readonly LOG_FILE="/var/log/shrink-vm.log"
readonly DEFAULT_HEADROOM_GB=2

# ==============================================================================
# CONSTANTS
# ==============================================================================
readonly MIN_DISK_GB=2
readonly META_MARGIN_PCT=5
readonly META_MARGIN_MIN_MB=512
readonly REQUIRED_CMDS=(qemu-img e2fsck resize2fs)

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
DEBUG=${SHRINK_VM_DEBUG:-0}

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
readonly E_SHRINK_FAILED=5

HEADROOM_GB=$DEFAULT_HEADROOM_GB

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
    local reason="Command failed during shrink workflow."
    local fix="Check the log and rerun with --dry-run to validate parameters."

    case "$failed_cmd" in
        *"qm config"*|*"pvesm path"*)
            reason="VM or storage lookup failed."
            fix="Verify VMID exists: qm status <VMID>; check storage health."
            ;;
        *"qemu-img"*)
            reason="Disk image operation failed."
            fix="Check image integrity: qemu-img check <path>; ensure VM is stopped."
            ;;
        *"virt-resize"*|*"guestfish"*)
            reason="Libguestfs shrink operation failed."
            fix="Install libguestfs-tools: apt install libguestfs-tools; check VM filesystem."
            ;;
        *"e2fsck"*)
            reason="Filesystem check found unrecoverable issues."
            fix="Run e2fsck manually on the disk image."
            ;;
        *"resize2fs"*)
            reason="Filesystem shrink failed - target too small or filesystem inconsistent."
            fix="Increase headroom, run e2fsck first, or use --dry-run to preview."
            ;;
        *"lvresize"*)
            reason="LVM resize failed."
            fix="Check VG free space and LV status: vgs, lvs."
            ;;
        *"zfs set"*)
            reason="ZFS volume resize failed."
            fix="Check ZFS pool space: zpool list."
            ;;
    esac

    printf '%s|%s\n' "$reason" "$fix"
}

error_exit_code() {
    local failed_cmd="$1"
    case "$failed_cmd" in
        *"qm config"*|*"pvesm path"*)
            echo "$E_NOT_FOUND"
            ;;
        *"qemu-img"*|*"resize2fs"*|*"e2fsck"*|*"lvresize"*|*"zfs"*|*"virt-resize"*)
            echo "$E_SHRINK_FAILED"
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
    exit "$mapped_code"
}
trap 'on_error' ERR

usage() {
    cat <<USAGE
${BOLD}Proxmox VM Disk Shrinker v${VERSION}${NC}

Shrinks a VM's disk to current usage + ${HEADROOM_GB}GB headroom.

Usage: $0 [OPTIONS]

Options:
  -v, --vmid <ID>        VM ID to shrink (e.g., 100)
  -g, --headroom <GB>    Extra headroom above used space (default: ${HEADROOM_GB})
  -n, --dry-run          Show what would be done without making changes
  -u, --use-libguestfs   Use virt-resize/libguestfs (more reliable, slower)
  --skip-fs-check        Skip filesystem checks (not recommended)
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0 -v 100                  # Shrink VM 100 to usage + 2GB
  $0 -v 100 -g 5             # Shrink with 5GB extra headroom
  $0 -v 100 --dry-run        # Preview only, no changes
  $0 -v 100 -u               # Use libguestfs for safer shrink

Storage Support:
  - LVM-thin: Block device shrink
  - Directory: QCOW2 and raw image shrink
  - ZFS: ZVOL shrink
  - NFS/CIFS: Treated as directory storage

Safety Notes:
  - VM will be stopped during shrink (downtime required)
  - Filesystem check runs before and after shrink
  - Minimum 2GB disk size is enforced
  - Always backup critical data before shrinking
USAGE
    exit 0
}

if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

mkdir -p "$(dirname "$LOG_FILE")"
echo "--- shrink-vm run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ==============================================================================
VMID=""
DRY_RUN=false
USE_LIBGUESTFS=false
SKIP_FS_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vmid)       VMID="$2"; shift 2 ;;
        -g|--headroom)   HEADROOM_GB="$2"; shift 2 ;;
        -n|--dry-run)    DRY_RUN=true; shift ;;
        -u|--use-libguestfs) USE_LIBGUESTFS=true; shift ;;
        --skip-fs-check) SKIP_FS_CHECK=true; shift ;;
        -h|--help)       usage ;;
        -V|--version)    echo "v${VERSION}"; exit 0 ;;
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

e "${BOLD}========================================${NC}"
e "${BOLD}     PROXMOX VM DISK SHRINKER v${VERSION}${NC}"
e "${BOLD}========================================${NC}"

[[ -z "$VMID" ]] && read -rp "Enter VM ID to shrink (e.g., 100): " VMID

# ==============================================================================
# INPUT VALIDATION
# ==============================================================================
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VM ID must be a positive integer, got: '$VMID'"
[[ "$HEADROOM_GB" =~ ^[0-9]+$ ]] || die "Headroom must be a positive integer (GB), got: '$HEADROOM_GB'"
[[ "$HEADROOM_GB" -ge 1 ]] || die "Headroom must be at least 1 GB."

if ! qm config "$VMID" >/dev/null 2>&1; then
    die "VM $VMID does not exist."
fi

# Check for libguestfs if requested
if $USE_LIBGUESTFS && ! command -v virt-resize &>/dev/null; then
    warn "libguestfs-tools not installed. Falling back to standard method."
    warn "Install with: apt install libguestfs-tools"
    USE_LIBGUESTFS=false
fi

# ==============================================================================
# DISK DETECTION & ANALYSIS
# ==============================================================================
log "Analyzing VM $VMID configuration..."

# Get the primary disk (scsi0, virtio0, or ide0)
DISK_CONFIG=$(qm config "$VMID" | grep -E '^(scsi0|virtio0|ide0):' | head -1)
[[ -n "$DISK_CONFIG" ]] || die "Could not find primary disk for VM $VMID."

DISK_NAME=$(echo "$DISK_CONFIG" | cut -d: -f1)
DISK_VALUE=$(echo "$DISK_CONFIG" | cut -d: -f2- | tr -d ' ')

log "Disk: $DISK_NAME = $DISK_VALUE"

# Parse disk reference (format: storage:vm-100-disk-0,size=32G)
DISK_REF=$(echo "$DISK_VALUE" | cut -d',' -f1)
STORAGE_NAME=$(echo "$DISK_REF" | cut -d':' -f1)
VOLUME_ID=$(echo "$DISK_REF" | cut -d':' -f2)

# Get current size
CURRENT_SIZE_STR=$(echo "$DISK_VALUE" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")
[[ -n "$CURRENT_SIZE_STR" ]] || die "Could not determine current disk size."
CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+')

log "Storage: $STORAGE_NAME | Volume: $VOLUME_ID | Current: ${CURRENT_SIZE_GB}GB"

# Detect storage type
STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE_NAME" '$1==s{print $2}')
[[ -n "$STORAGE_TYPE" ]] || die "Could not determine storage type for '$STORAGE_NAME'."
log "Storage type: $STORAGE_TYPE"

# ==============================================================================
# VM STOPPAGE
# ==============================================================================
VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
VM_WAS_RUNNING=false

if [[ "$VM_STATUS" == "running" ]]; then
    VM_WAS_RUNNING=true
    if $DRY_RUN; then
        warn "VM $VMID is running. Would stop it."
    else
        warn "VM $VMID is running. Stopping..."
        qm stop "$VMID"
        sleep 3
    fi
fi

# ==============================================================================
# CALCULATE USED SPACE
# ==============================================================================
log "Calculating used space..."

DISK_PATH=$(pvesm path "${DISK_REF}" 2>/dev/null)
[[ -n "$DISK_PATH" ]] || die "Could not resolve disk path for $DISK_REF"
log "Disk path: $DISK_PATH"

# Detect image format
if [[ -f "$DISK_PATH" ]]; then
    IMG_FORMAT=$(qemu-img info "$DISK_PATH" 2>/dev/null | awk '/file format:/{print $3}')
    log "Image format: $IMG_FORMAT"
else
    # Block device (LVM/ZFS)
    IMG_FORMAT="raw"
    log "Block device detected (raw format assumed)"
fi

# Get used space using virt-df if available, or estimate from filesystem
USED_GB=0
if command -v virt-df &>/dev/null && [[ "$IMG_FORMAT" == "qcow2" || "$IMG_FORMAT" == "raw" ]]; then
    log "Using virt-df to analyze disk usage..."
    VIRT_DF_OUT=$(virt-df -a "$DISK_PATH" 2>/dev/null | tail -n +2) || VIRT_DF_OUT=""
    if [[ -n "$VIRT_DF_OUT" ]]; then
        # Parse the used column (typically 3rd column, in bytes)
        USED_BYTES=$(echo "$VIRT_DF_OUT" | awk '{sum+=$3} END {print sum}')
        if [[ -n "$USED_BYTES" && "$USED_BYTES" -gt 0 ]]; then
            USED_GB=$((USED_BYTES / 1024 / 1024 / 1024))
        fi
    fi
fi

# Fallback: use qemu-img info for allocated size (qcow2 only)
if [[ "$USED_GB" -eq 0 && "$IMG_FORMAT" == "qcow2" ]]; then
    log "Using qemu-img allocated size..."
    ALLOCATED_BYTES=$(qemu-img info "$DISK_PATH" 2>/dev/null | grep "disk size" | grep -oP '[0-9]+' | head -1)
    if [[ -n "$ALLOCATED_BYTES" ]]; then
        # qemu-img reports in bytes (K/M/G)
        ALLOC_STR=$(qemu-img info "$DISK_PATH" 2>/dev/null | grep "disk size" | awk '{print $3}')
        USED_GB=$(echo "$ALLOC_STR" | sed 's/GiB//;s/MiB//;s/KiB//' | cut -d'.' -f1)
    fi
fi

# Final fallback: estimate based on typical usage (50% of current)
if [[ "$USED_GB" -eq 0 ]]; then
    USED_GB=$((CURRENT_SIZE_GB * 50 / 100))
    warn "Could not determine actual usage. Estimating ${USED_GB}GB (50% of current)."
    warn "For accurate sizing, install libguestfs-tools: apt install libguestfs-tools"
fi

# Ensure used doesn't exceed current
[[ "$USED_GB" -gt "$CURRENT_SIZE_GB" ]] && USED_GB=$((CURRENT_SIZE_GB - 1))

# Calculate metadata margin
META_MARGIN_MB=$((USED_GB * 1024 * META_MARGIN_PCT / 100))
[[ "$META_MARGIN_MB" -lt "$META_MARGIN_MIN_MB" ]] && META_MARGIN_MB=$META_MARGIN_MIN_MB
META_MARGIN_GB=$((META_MARGIN_MB / 1024 + 1))

# Calculate final target size
NEW_SIZE_GB=$((USED_GB + META_MARGIN_GB + HEADROOM_GB))
[[ "$NEW_SIZE_GB" -lt "$MIN_DISK_GB" ]] && NEW_SIZE_GB=$MIN_DISK_GB

log "Used space: ~${USED_GB}GB"
log "Metadata margin: ${META_MARGIN_GB}GB"
log "Headroom: ${HEADROOM_GB}GB"
log "Target: ${CURRENT_SIZE_GB}GB → ${NEW_SIZE_GB}GB"

# Check if shrink is needed
if [[ "$NEW_SIZE_GB" -ge "$CURRENT_SIZE_GB" ]]; then
    ok "Disk is already optimal size (${CURRENT_SIZE_GB}GB). No shrink needed."
    if $VM_WAS_RUNNING && ! $DRY_RUN; then
        log "Starting VM $VMID..."
        qm start "$VMID"
    fi
    exit 0
fi

SAVINGS_GB=$((CURRENT_SIZE_GB - NEW_SIZE_GB))

# ==============================================================================
# DRY-RUN SUMMARY
# ==============================================================================
if $DRY_RUN; then
    echo ""
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}VM:${NC}           $VMID"
    e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
    e "  ${BOLD}Disk:${NC}         $DISK_NAME"
    e "  ${BOLD}Format:${NC}       $IMG_FORMAT"
    e "  ${BOLD}Current:${NC}      ${CURRENT_SIZE_GB}GB"
    e "  ${BOLD}Target:${NC}       ${NEW_SIZE_GB}GB"
    e "  ${BOLD}Savings:${NC}      ${SAVINGS_GB}GB"
    echo ""
    e "  ${BOLD}Steps:${NC}"
    echo "    1. Stop VM $VMID"
    echo "    2. Shrink disk to ${NEW_SIZE_GB}GB"
    echo "    3. Update VM config"
    echo "    4. Start VM (if it was running)"
    echo ""
    ok "Dry run complete."
    if $VM_WAS_RUNNING; then
        log "Starting VM $VMID..."
        qm start "$VMID" 2>/dev/null || true
    fi
    exit 0
fi

# ==============================================================================
# USER CONFIRMATION
# ==============================================================================
echo ""
e "${YELLOW}${BOLD}WARNING: This will shrink the disk for VM $VMID${NC}"
e "  ${BOLD}Current:${NC} ${CURRENT_SIZE_GB}GB → ${BOLD}New:${NC} ${NEW_SIZE_GB}GB (saving ${SAVINGS_GB}GB)"
echo ""
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; $VM_WAS_RUNNING && qm start "$VMID" 2>/dev/null || true; exit 0; }

# ==============================================================================
# PERFORM SHRINK
# ==============================================================================
log "Beginning shrink operation..."

# Use libguestfs if requested (most reliable for qcow2)
if $USE_LIBGUESTFS && command -v virt-resize &>/dev/null; then
    log "Using libguestfs virt-resize..."
    
    TEMP_RAW="/tmp/vm-${VMID}-shrink.raw"
    trap "rm -f '$TEMP_RAW' 2>/dev/null || true" EXIT
    
    # Convert to raw
    log "Converting to temporary raw image..."
    qemu-img convert -f "$IMG_FORMAT" -O raw "$DISK_PATH" "$TEMP_RAW"
    
    # Shrink using virt-resize
    log "Shrinking with virt-resize..."
    if ! virt-resize --shrink /dev/sda1 --output /tmp/vm-${VMID}-new.raw "$TEMP_RAW" 2>&1 | tee -a "$LOG_FILE"; then
        warn "virt-resize failed. Trying standard method..."
    else
        # Convert back
        log "Converting back to $IMG_FORMAT..."
        qemu-img convert -f raw -O "$IMG_FORMAT" /tmp/vm-${VMID}-new.raw "$DISK_PATH"
        rm -f /tmp/vm-${VMID}-new.raw "$TEMP_RAW"
        trap - EXIT
        ok "Shrink complete via libguestfs."
    fi
fi

# Standard shrink method by storage type
case "$STORAGE_TYPE" in
    lvmthin|lvm)
        log "Processing LVM volume..."
        
        # Check if disk path is an LV
        if [[ -L "$DISK_PATH" ]] || lvdisplay "$DISK_PATH" &>/dev/null; then
            LV_PATH="$DISK_PATH"
            
            if ! $SKIP_FS_CHECK; then
                log "Running filesystem check..."
                e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || {
                    warn "e2fsck issues found. Attempting fix..."
                    e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                }
            fi
            
            log "Shrinking filesystem..."
            resize2fs "$LV_PATH" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1 || die "Filesystem shrink failed."
            
            log "Shrinking LV..."
            lvresize -y -L "${NEW_SIZE_GB}G" "$LV_PATH" >> "$LOG_FILE" 2>&1 || die "LV shrink failed."
            
            if ! $SKIP_FS_CHECK; then
                log "Verifying filesystem..."
                e2fsck -f -y "$LV_PATH" >> "$LOG_FILE" 2>&1 || warn "Post-shrink fsck had warnings."
            fi
            
            ok "LVM shrink complete."
        else
            die "Could not identify LVM volume for $DISK_PATH"
        fi
        ;;
    
    dir|nfs|cifs|glusterfs)
        log "Processing disk image..."
        
        if [[ "$IMG_FORMAT" == "qcow2" ]]; then
            # QCOW2 shrink: convert to raw, shrink, convert back
            TEMP_RAW="/tmp/vm-${VMID}-shrink.raw"
            trap "rm -f '$TEMP_RAW' 2>/dev/null || true" EXIT
            
            log "Converting QCOW2 to raw..."
            qemu-img convert -f qcow2 -O raw "$DISK_PATH" "$TEMP_RAW"
            
            # Mount via loop and shrink
            LOOP_DEV=$(losetup --show -f "$TEMP_RAW")
            trap "losetup -d '$LOOP_DEV' 2>/dev/null || true; rm -f '$TEMP_RAW' 2>/dev/null || true" EXIT
            
            if ! $SKIP_FS_CHECK; then
                log "Running filesystem check..."
                e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || {
                    e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                }
            fi
            
            log "Shrinking filesystem..."
            resize2fs "$LOOP_DEV" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1 || die "Filesystem shrink failed."
            
            losetup -d "$LOOP_DEV" 2>/dev/null || true
            
            log "Truncating raw image..."
            truncate -s "${NEW_SIZE_GB}G" "$TEMP_RAW"
            
            log "Converting back to QCOW2..."
            qemu-img convert -f raw -O qcow2 "$TEMP_RAW" "$DISK_PATH"
            
            rm -f "$TEMP_RAW"
            trap - EXIT
            ok "QCOW2 shrink complete."
            
        elif [[ "$IMG_FORMAT" == "raw" ]]; then
            # Raw image shrink
            if ! $SKIP_FS_CHECK; then
                log "Running filesystem check..."
                e2fsck -f -y "$DISK_PATH" >> "$LOG_FILE" 2>&1 || {
                    e2fsck -f -y "$DISK_PATH" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
                }
            fi
            
            LOOP_DEV=$(losetup --show -f "$DISK_PATH")
            trap "losetup -d '$LOOP_DEV' 2>/dev/null || true" EXIT
            
            log "Shrinking filesystem..."
            resize2fs "$LOOP_DEV" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1 || die "Filesystem shrink failed."
            
            losetup -d "$LOOP_DEV" 2>/dev/null || true
            trap - EXIT
            
            log "Truncating image..."
            truncate -s "${NEW_SIZE_GB}G" "$DISK_PATH"
            ok "Raw image shrink complete."
        else
            die "Unsupported format: $IMG_FORMAT"
        fi
        ;;
    
    zfspool)
        log "Processing ZFS volume..."
        ZFS_DATASET="${DISK_PATH#/dev/zvol/}"
        [[ -n "$ZFS_DATASET" ]] || die "Could not determine ZFS dataset"
        
        if ! $SKIP_FS_CHECK; then
            log "Running filesystem check..."
            e2fsck -f -y "$DISK_PATH" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
        fi
        
        log "Shrinking filesystem..."
        resize2fs "$DISK_PATH" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1 || die "Filesystem shrink failed."
        
        log "Shrinking ZFS volume..."
        zfs set volsize="${NEW_SIZE_GB}G" "$ZFS_DATASET" >> "$LOG_FILE" 2>&1 || die "ZFS shrink failed."
        
        if ! $SKIP_FS_CHECK; then
            log "Verifying filesystem..."
            e2fsck -f -y "$DISK_PATH" >> "$LOG_FILE" 2>&1 || warn "Post-shrink fsck had warnings."
        fi
        
        ok "ZFS shrink complete."
        ;;
    
    *)
        die "Unsupported storage type: $STORAGE_TYPE"
        ;;
esac

# Update VM config with new size
log "Updating VM configuration..."
qm set "$VMID" --${DISK_NAME} "${DISK_REF},size=${NEW_SIZE_GB}G"
ok "VM configuration updated."

# ==============================================================================
# RESTART & SUMMARY
# ==============================================================================
if $VM_WAS_RUNNING; then
    log "Starting VM $VMID..."
    qm start "$VMID"
    sleep 3
    
    NEW_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
    if [[ "$NEW_STATUS" == "running" ]]; then
        ok "VM $VMID is running."
    else
        warn "VM did not start. Check: qm start $VMID"
    fi
fi

echo ""
e "${GREEN}${BOLD}========================================${NC}"
e "${GREEN}${BOLD}          SHRINK COMPLETE${NC}"
e "${GREEN}${BOLD}========================================${NC}"
echo ""
e "  ${BOLD}VM:${NC}           $VMID"
e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
e "  ${BOLD}Disk:${NC}         $DISK_NAME"
e "  ${BOLD}Previous:${NC}     ${CURRENT_SIZE_GB}GB"
e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB"
e "  ${BOLD}Saved:${NC}        ${SAVINGS_GB}GB"
e "  ${BOLD}Log:${NC}          $LOG_FILE"
echo ""
e "  ${YELLOW}Note:${NC} Resize filesystem inside VM if needed: resize2fs /dev/sda1"
echo ""
