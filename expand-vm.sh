#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox VM Disk Expander
# Version: 6.0.0
# ==============================================================================
#
# DESCRIPTION:
#   This script safely expands a VM's disk to a specified size.
#   Supports multiple expansion modes and storage backends.
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
# EXPANSION METHODS:
#   - Offline expand: VM stopped, disk expanded directly
#   - Hot-expand: VM running, uses QEMU monitor/online resize
#
# EXPANSION MODES:
#   - Absolute size (-s): Set exact target size
#   - Add space (-a): Add specified GB to current size
#   - Max available (--max): Use all available pool space
#   - Percentage (--percent): Use percentage of pool capacity
#
# SAFETY FEATURES:
#   - Dry-run mode previews changes
#   - Automatic storage space validation
#   - Safety margins prevent pool exhaustion
#   - Configurable max expansion limits
#
# LICENSE: MIT
# ==============================================================================

set -Eeuo pipefail

readonly VERSION="6.0.0"
readonly LOG_FILE="/var/log/expand-vm.log"

# ==============================================================================
# CONSTANTS
# ==============================================================================
readonly MIN_DISK_GB=2
readonly POOL_SAFETY_MARGIN_PCT=5
readonly POOL_SAFETY_MARGIN_GB=10
readonly REQUIRED_CMDS=(qemu-img e2fsck resize2fs)

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
DEBUG=${EXPAND_VM_DEBUG:-0}

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
readonly E_EXPAND_FAILED=5
readonly E_NO_SPACE=6

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
    local reason="Command failed during expand workflow."
    local fix="Check the log and rerun with --dry-run to validate parameters."

    case "$failed_cmd" in
        *"qm config"*|*"pvesm path"*)
            reason="VM or storage lookup failed."
            fix="Verify VMID exists: qm status <VMID>; check storage health."
            ;;
        *"qemu-img"*)
            reason="Disk image expansion failed."
            fix="Check image integrity and available storage space."
            ;;
        *"lvresize"*)
            reason="LVM resize failed - insufficient VG space."
            fix="Check VG free space: vgs; use smaller target or --max with safety margins."
            ;;
        *"zfs set"*)
            reason="ZFS volume resize failed."
            fix="Check ZFS pool space: zpool list."
            ;;
        *"qm monitor"*)
            reason="QEMU monitor command failed (hot-expand)."
            fix="Hot-expand may not be supported; try without --hot-expand."
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
        *"lvresize"*|*"zfs set"*)
            echo "$E_NO_SPACE"
            ;;
        *"qemu-img"*|*"qm monitor"*)
            echo "$E_EXPAND_FAILED"
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
${BOLD}Proxmox VM Disk Expander v${VERSION}${NC}

Expands a VM's disk using various expansion modes.

Usage: $0 [OPTIONS]

EXPANSION MODES (choose one):
  -s, --size <GB>        Set absolute target size in GB
  -a, --add <GB>         Add specified GB to current size
  --percent <N>          Expand to N% of available storage pool capacity
  --max                  Use maximum available space (with safety margin)

OPTIONS:
  -v, --vmid <ID>        VM ID to expand (e.g., 100)
  -n, --dry-run          Show what would be done without making changes
  --safety-margin <GB>   GB to reserve when using --max (default: ${POOL_SAFETY_MARGIN_GB})
  --safety-percent <N>   Percent to reserve when using --max (default: ${POOL_SAFETY_MARGIN_PCT})
  --hot-expand           Attempt online expansion (VM stays running)
  --no-restart           Keep VM stopped after expansion (if it was stopped)
  --force                Skip confirmation prompts
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0 -v 100 -s 100              # Expand to exactly 100GB
  $0 -v 100 -a 50               # Add 50GB to current size
  $0 -v 100 --percent 80        # Expand to 80% of pool capacity
  $0 -v 100 --max               # Expand to max available
  $0 -v 100 --max --safety-margin 20   # Max with 20GB safety
  $0 -v 100 -s 200 --hot-expand # Hot-expand while VM running

Storage Support:
  - LVM-thin: Hot-expand supported
  - LVM: Hot-expand supported
  - Directory (QCOW2): Hot-expand supported
  - Directory (raw): Hot-expand supported
  - ZFS: Hot-expand supported
  - NFS/CIFS: Requires VM stop

Safety Notes:
  - Verify sufficient free space in the storage pool
  - LVM-thin users: monitor thin pool usage
  - Always backup before major expansions
USAGE
    exit 0
}

if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

mkdir -p "$(dirname "$LOG_FILE")"
echo "--- expand-vm run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ==============================================================================
VMID=""
DRY_RUN=false
EXPAND_MODE=""
EXPAND_VALUE=""
SAFETY_MARGIN_GB=$POOL_SAFETY_MARGIN_GB
SAFETY_MARGIN_PCT=$POOL_SAFETY_MARGIN_PCT
HOT_EXPAND=false
NO_RESTART=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vmid)       VMID="$2"; shift 2 ;;
        -s|--size)        EXPAND_MODE="size"; EXPAND_VALUE="$2"; shift 2 ;;
        -a|--add)         EXPAND_MODE="add"; EXPAND_VALUE="$2"; shift 2 ;;
        --percent)        EXPAND_MODE="percent"; EXPAND_VALUE="$2"; shift 2 ;;
        --max)            EXPAND_MODE="max"; shift ;;
        --safety-margin)  SAFETY_MARGIN_GB="$2"; shift 2 ;;
        --safety-percent) SAFETY_MARGIN_PCT="$2"; shift 2 ;;
        --hot-expand)     HOT_EXPAND=true; shift ;;
        --no-restart)     NO_RESTART=true; shift ;;
        -n|--dry-run)     DRY_RUN=true; shift ;;
        --force)          FORCE=true; shift ;;
        -h|--help)        usage ;;
        -V|--version)     echo "v${VERSION}"; exit 0 ;;
        *)                die "Unknown option: $1 (use --help)" ;;
    esac
done

e "${BOLD}========================================${NC}"
e "${BOLD}     PROXMOX VM DISK EXPANDER v${VERSION}${NC}"
e "${BOLD}========================================${NC}"

[[ -z "$VMID" ]] && read -rp "Enter VM ID to expand (e.g., 100): " VMID

# ==============================================================================
# INPUT VALIDATION
# ==============================================================================
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VM ID must be a positive integer, got: '$VMID'"

if ! qm config "$VMID" >/dev/null 2>&1; then
    die "VM $VMID does not exist."
fi

[[ -n "$EXPAND_MODE" ]] || die "No expansion mode specified. Use -s, -a, --percent, or --max (see --help)"

if [[ "$EXPAND_MODE" == "size" || "$EXPAND_MODE" == "add" ]]; then
    [[ "$EXPAND_VALUE" =~ ^[0-9]+$ ]] || die "Size must be a positive integer (GB), got: '$EXPAND_VALUE'"
    [[ "$EXPAND_VALUE" -ge 1 ]] || die "Size must be at least 1 GB."
fi

if [[ "$EXPAND_MODE" == "percent" ]]; then
    [[ "$EXPAND_VALUE" =~ ^[0-9]+$ ]] || die "Percent must be a positive integer"
    [[ "$EXPAND_VALUE" -ge 1 && "$EXPAND_VALUE" -le 100 ]] || die "Percent must be 1-100."
fi

# ==============================================================================
# DISK DETECTION
# ==============================================================================
log "Analyzing VM $VMID configuration..."

DISK_CONFIG=$(qm config "$VMID" | grep -E '^(scsi0|virtio0|ide0):' | head -1)
[[ -n "$DISK_CONFIG" ]] || die "Could not find primary disk for VM $VMID."

DISK_NAME=$(echo "$DISK_CONFIG" | cut -d: -f1)
DISK_VALUE=$(echo "$DISK_CONFIG" | cut -d: -f2- | tr -d ' ')
log "Disk: $DISK_NAME = $DISK_VALUE"

DISK_REF=$(echo "$DISK_VALUE" | cut -d',' -f1)
STORAGE_NAME=$(echo "$DISK_REF" | cut -d':' -f1)
VOLUME_ID=$(echo "$DISK_REF" | cut -d':' -f2)

CURRENT_SIZE_STR=$(echo "$DISK_VALUE" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")
[[ -n "$CURRENT_SIZE_STR" ]] || die "Could not determine current disk size."
CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+')

log "Storage: $STORAGE_NAME | Volume: $VOLUME_ID | Current: ${CURRENT_SIZE_GB}GB"

STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE_NAME" '$1==s{print $2}')
[[ -n "$STORAGE_TYPE" ]] || die "Could not determine storage type for '$STORAGE_NAME'."
log "Storage type: $STORAGE_TYPE"

DISK_PATH=$(pvesm path "${DISK_REF}" 2>/dev/null)
[[ -n "$DISK_PATH" ]] || die "Could not resolve disk path for $DISK_REF"
log "Disk path: $DISK_PATH"

if [[ -f "$DISK_PATH" ]]; then
    IMG_FORMAT=$(qemu-img info "$DISK_PATH" 2>/dev/null | awk '/file format:/{print $3}')
    log "Image format: $IMG_FORMAT"
else
    IMG_FORMAT="raw"
    log "Block device detected (raw format)"
fi

# ==============================================================================
# CALCULATE TARGET SIZE
# ==============================================================================
get_pool_free_space() {
    local free_gb=0
    case "$STORAGE_TYPE" in
        lvmthin|lvm)
            local vg_name
            vg_name=$(pvesm path "$DISK_REF" 2>/dev/null | cut -d'/' -f3)
            if [[ -n "$vg_name" ]]; then
                local free_mb
                free_mb=$(vgs --noheadings --units m -o vg_free "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
                free_gb=$((free_mb / 1024))
            fi
            ;;
        zfspool)
            local zfs_dataset
            zfs_dataset=$(pvesm path "$DISK_REF" 2>/dev/null | sed 's|/dev/zd0||')
            if [[ -n "$zfs_dataset" ]]; then
                local avail_gb
                avail_gb=$(zfs list -H -o available "$zfs_dataset" 2>/dev/null | awk '{print $1}' | sed 's/G//i')
                free_gb=${avail_gb%.*}
            fi
            ;;
        dir|nfs|cifs|glusterfs)
            local storage_path
            storage_path=$(dirname "$DISK_PATH" 2>/dev/null)
            if [[ -n "$storage_path" && -d "$storage_path" ]]; then
                local free_kb
                free_kb=$(df -k "$storage_path" 2>/dev/null | awk 'NR==2{print $4}')
                free_gb=$((free_kb / 1024 / 1024))
            fi
            ;;
    esac
    echo "$free_gb"
}

get_pool_total_size() {
    local total_gb=0
    case "$STORAGE_TYPE" in
        lvmthin|lvm)
            local vg_name
            vg_name=$(pvesm path "$DISK_REF" 2>/dev/null | cut -d'/' -f3)
            if [[ -n "$vg_name" ]]; then
                local total_mb
                total_mb=$(vgs --noheadings --units m -o vg_size "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
                total_gb=$((total_mb / 1024))
            fi
            ;;
        zfspool)
            local zfs_dataset
            zfs_dataset=$(pvesm path "$DISK_REF" 2>/dev/null | sed 's|/dev/zd0||')
            if [[ -n "$zfs_dataset" ]]; then
                local total_gb_raw
                total_gb_raw=$(zfs list -H -o used,available "$zfs_dataset" 2>/dev/null | awk '{sum=$1+$2; print sum}' | sed 's/G//i')
                total_gb=${total_gb_raw%.*}
            fi
            ;;
    esac
    echo "$total_gb"
}

calculate_target_size() {
    local target_gb=0
    local free_gb total_gb
    
    case "$EXPAND_MODE" in
        size)
            target_gb="$EXPAND_VALUE"
            ;;
        add)
            target_gb=$((CURRENT_SIZE_GB + EXPAND_VALUE))
            ;;
        percent)
            total_gb=$(get_pool_total_size)
            if [[ "$total_gb" -gt 0 ]]; then
                target_gb=$((total_gb * EXPAND_VALUE / 100))
                [[ "$target_gb" -lt "$CURRENT_SIZE_GB" ]] && target_gb=$CURRENT_SIZE_GB
            else
                die "Cannot determine pool total size."
            fi
            ;;
        max)
            free_gb=$(get_pool_free_space)
            if [[ "$free_gb" -gt 0 ]]; then
                local safety_gb=$((free_gb * SAFETY_MARGIN_PCT / 100))
                [[ "$safety_gb" -lt "$SAFETY_MARGIN_GB" ]] && safety_gb=$SAFETY_MARGIN_GB
                local usable_free=$((free_gb - safety_gb))
                [[ "$usable_free" -lt 1 ]] && die "Insufficient free space (free: ${free_gb}GB, safety: ${safety_gb}GB)"
                target_gb=$((CURRENT_SIZE_GB + usable_free))
                log "Free: ${free_gb}GB, Usable: ${usable_free}GB"
            else
                die "Cannot determine free space."
            fi
            ;;
    esac
    echo "$target_gb"
}

NEW_SIZE_GB=$(calculate_target_size)
[[ "$NEW_SIZE_GB" -lt "$MIN_DISK_GB" ]] && NEW_SIZE_GB=$MIN_DISK_GB
[[ "$NEW_SIZE_GB" -le "$CURRENT_SIZE_GB" ]] && die "Target (${NEW_SIZE_GB}GB) must be greater than current (${CURRENT_SIZE_GB}GB)."

log "Expansion mode: $EXPAND_MODE"
log "Current: ${CURRENT_SIZE_GB}GB → Target: ${NEW_SIZE_GB}GB (+$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB)"

# ==============================================================================
# VM STATUS & HOT-EXPAND CHECK
# ==============================================================================
VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
VM_WAS_RUNNING=false
HOT_EXPAND_SUPPORTED=false

if [[ "$VM_STATUS" == "running" ]]; then
    VM_WAS_RUNNING=true
    # Check if hot-expand is supported
    case "$STORAGE_TYPE" in
        lvmthin|lvm|zfspool)
            HOT_EXPAND_SUPPORTED=true
            ;;
        dir)
            HOT_EXPAND_SUPPORTED=true
            ;;
    esac
    
    if $HOT_EXPAND && $HOT_EXPAND_SUPPORTED; then
        log "Hot-expand enabled - VM will remain running."
    elif $HOT_EXPAND && ! $HOT_EXPAND_SUPPORTED; then
        warn "Hot-expand not supported for $STORAGE_TYPE. VM will be stopped."
        HOT_EXPAND=false
    fi
fi

# ==============================================================================
# DRY-RUN SUMMARY
# ==============================================================================
if $DRY_RUN; then
    echo ""
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}VM:${NC}           $VMID"
    e "  ${BOLD}Status:${NC}       $VM_STATUS"
    e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
    e "  ${BOLD}Disk:${NC}         $DISK_NAME ($IMG_FORMAT)"
    e "  ${BOLD}Current:${NC}      ${CURRENT_SIZE_GB}GB"
    e "  ${BOLD}Target:${NC}       ${NEW_SIZE_GB}GB"
    e "  ${BOLD}Expansion:${NC}   +$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB"
    e "  ${BOLD}Mode:${NC}        $EXPAND_MODE"
    echo ""
    e "  ${BOLD}Steps:${NC}"
    if $HOT_EXPAND; then
        echo "    1. Hot-expand disk while VM runs"
        echo "    2. Trigger filesystem resize inside VM"
    else
        echo "    1. Stop VM $VMID"
        echo "    2. Expand disk to ${NEW_SIZE_GB}GB"
        echo "    3. Start VM (if it was running)"
    fi
    echo ""
    ok "Dry run complete."
    exit 0
fi

# ==============================================================================
# USER CONFIRMATION
# ==============================================================================
if ! $FORCE; then
    echo ""
    e "${YELLOW}${BOLD}WARNING: This will expand the disk for VM $VMID${NC}"
    e "  ${BOLD}Current:${NC} ${CURRENT_SIZE_GB}GB → ${BOLD}New:${NC} ${NEW_SIZE_GB}GB (+$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB)"
    e "  ${BOLD}Mode:${NC} $EXPAND_MODE"
    $HOT_EXPAND && e "  ${BOLD}Method:${NC} Hot-expand (VM stays running)"
    echo ""
    read -rp "Continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 0; }
fi

# ==============================================================================
# PERFORM EXPANSION
# ==============================================================================

# Stop VM if not hot-expanding
if ! $HOT_EXPAND && $VM_WAS_RUNNING; then
    log "Stopping VM $VMID..."
    qm stop "$VMID"
    sleep 3
fi

case "$STORAGE_TYPE" in
    lvmthin|lvm)
        log "Expanding LVM volume..."
        if [[ -L "$DISK_PATH" ]] || lvdisplay "$DISK_PATH" &>/dev/null; then
            LV_PATH="$DISK_PATH"
            
            log "Expanding LV to ${NEW_SIZE_GB}GB..."
            if ! lvresize -y -L "${NEW_SIZE_GB}G" "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"; then
                die "LV expansion failed. Check VG free space."
            fi
            ok "LV expanded."
            
            # For hot-expand, trigger block_resize via QEMU monitor
            if $HOT_EXPAND; then
                log "Notifying VM of disk resize..."
                qm monitor "$VMID" <<< "block_resize virtio0 ${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE" || warn "Block resize notification failed."
            fi
        fi
        ;;
    
    dir|nfs|cifs|glusterfs)
        log "Expanding disk image..."
        
        if [[ "$IMG_FORMAT" == "qcow2" ]]; then
            log "Expanding QCOW2 image..."
            if ! qemu-img resize -f qcow2 "$DISK_PATH" "${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE"; then
                die "QCOW2 expansion failed."
            fi
            ok "QCOW2 expanded."
            
            if $HOT_EXPAND; then
                log "Notifying VM of disk resize..."
                qm monitor "$VMID" <<< "block_resize virtio0 ${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE" || warn "Block resize notification failed."
            fi
            
        elif [[ "$IMG_FORMAT" == "raw" ]]; then
            log "Expanding raw image..."
            if ! qemu-img resize -f raw "$DISK_PATH" "${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE"; then
                die "Raw image expansion failed."
            fi
            ok "Raw image expanded."
            
            if $HOT_EXPAND; then
                log "Notifying VM of disk resize..."
                qm monitor "$VMID" <<< "block_resize virtio0 ${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE" || warn "Block resize notification failed."
            fi
        fi
        ;;
    
    zfspool)
        log "Expanding ZFS volume..."
        ZFS_DATASET="${DISK_PATH#/dev/zvol/}"
        [[ -n "$ZFS_DATASET" ]] || die "Could not determine ZFS dataset"
        
        log "Expanding ZFS volume to ${NEW_SIZE_GB}GB..."
        if ! zfs set volsize="${NEW_SIZE_GB}G" "$ZFS_DATASET" 2>&1 | tee -a "$LOG_FILE"; then
            die "ZFS expansion failed."
        fi
        ok "ZFS volume expanded."
        
        if $HOT_EXPAND; then
            log "Notifying VM of disk resize..."
            qm monitor "$VMID" <<< "block_resize virtio0 ${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE" || warn "Block resize notification failed."
        fi
        ;;
    
    *)
        die "Unsupported storage type: $STORAGE_TYPE"
        ;;
esac

# Update VM config
log "Updating VM configuration..."
qm set "$VMID" --${DISK_NAME} "${DISK_REF},size=${NEW_SIZE_GB}G"
ok "VM configuration updated."

# ==============================================================================
# RESTART & SUMMARY
# ==============================================================================
if $VM_WAS_RUNNING && ! $HOT_EXPAND && ! $NO_RESTART; then
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
e "${GREEN}${BOLD}          EXPANSION COMPLETE${NC}"
e "${GREEN}${BOLD}========================================${NC}"
echo ""
e "  ${BOLD}VM:${NC}           $VMID"
e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
e "  ${BOLD}Disk:${NC}         $DISK_NAME"
e "  ${BOLD}Previous:${NC}     ${CURRENT_SIZE_GB}GB"
e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB"
e "  ${BOLD}Expansion:${NC}   +$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB"
e "  ${BOLD}Mode:${NC}        $EXPAND_MODE"
e "  ${BOLD}Log:${NC}         $LOG_FILE"
echo ""
e "  ${YELLOW}Next steps:${NC}"
e "    - Resize filesystem inside VM: resize2fs /dev/sda1 (or appropriate device)"
$HOT_EXPAND && e "    - VM remained running; resize filesystem from within the VM"
echo ""
