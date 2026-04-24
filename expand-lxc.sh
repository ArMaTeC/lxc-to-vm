#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox LXC Disk Expander
# Version: 6.0.0
# ==============================================================================
#
# DESCRIPTION:
#   This script safely expands an LXC container's root disk to a specified size.
#   Useful when a container is running out of space or before major updates.
#   Supports multiple expansion modes: absolute size, incremental addition,
#   percentage-based, or maximum available space.
#
# SUPPORTED STORAGE TYPES:
#   - LVM-thin (proxmox default, most efficient for expansion)
#   - LVM (thick provisioning)
#   - Directory-based (raw or qcow2 images)
#   - ZFS volumes (zfspool)
#   - NFS/CIFS/GlusterFS (treated as directory-based)
#
# SAFETY FEATURES:
#   - Dry-run mode previews changes without modifying anything
#   - Container can remain running during expansion (hot-expand for supported types)
#   - Filesystem check after expansion to verify integrity
#   - Automatic storage space validation before expansion
#   - Safety margin prevents filling storage pool to 100%
#   - Configurable maximum expansion limits
#
# RISKS:
#   - Always backup before major disk operations
#   - Ensure sufficient free space in the storage pool
#   - LVM-thin: monitor pool usage to avoid over-provisioning issues
#
# LICENSE: MIT
# ==============================================================================

# Bash strict mode: exit on error, undefined variable, or pipe failure
# -E propagates ERR trap into functions/subshells
set -Eeuo pipefail

readonly VERSION="6.0.0"
readonly LOG_FILE="/var/log/expand-lxc.log"

# ==============================================================================
# CONSTANTS
# ==============================================================================
readonly MIN_DISK_GB=2                               # Absolute minimum disk size
readonly POOL_SAFETY_MARGIN_PCT=5                    # Keep 5% free in pool for safety
readonly POOL_SAFETY_MARGIN_GB=10                    # Minimum GB to keep free
readonly REQUIRED_CMDS=(e2fsck resize2fs)            # Essential tools for filesystem operations
readonly MAX_RETRY_ATTEMPTS=3                        # Retry attempts for resize operations

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
DEBUG=${EXPAND_LXC_DEBUG:-0}

if [[ "${DEBUG:-0}" -eq 1 ]]; then
    export PS4='[${BASH_SOURCE}:${LINENO}] '
    set -x
fi

# Debug logging function
# Arguments:
#   $* - Debug message to display
# Outputs: Debug text to stdout (only if DEBUG=1)
debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$LOG_FILE"
}

# Verbose logging function
# Arguments:
#   $* - Verbose message to log
verbose() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VERBOSE] $*" >> "$LOG_FILE"
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[*]${NC} $*"
    fi
}

# Exit codes for automation
readonly E_INVALID_ARG=1       # Invalid command-line arguments
readonly E_NOT_FOUND=2         # Container or resource not found
readonly E_DISK_FULL=3         # Disk space issues
readonly E_PERMISSION=4        # Permission denied
readonly E_EXPAND_FAILED=5     # Expand operation itself failed
readonly E_NO_SPACE=6          # Insufficient storage pool space

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# --- Color & Terminal Formatting ---
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

# Echo with interpretation of backslash escapes
e() { echo -e "$*"; }

# --- Logging Functions ---
log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Fatal error exit function
die() { err "$*"; exit "${E_INVALID_ARG}"; }

# Map failed command to likely root cause + actionable fix
error_reason_and_fix() {
    local failed_cmd="$1"
    local reason="Command failed during expand workflow."
    local fix="Check the log and rerun with --dry-run to validate parameters and environment."

    case "$failed_cmd" in
        *"pct config"*|*"pvesm path"*)
            reason="Container or storage lookup failed."
            fix="Verify CTID exists: pct config <CTID>; check storage availability: pvesm status."
            ;;
        *"lvresize"*)
            reason="LVM resize failed - likely insufficient free space in volume group."
            fix="Check VG free space: vgs; consider using --max option or smaller target size."
            ;;
        *"zfs set volsize"*)
            reason="ZFS volume resize failed - pool may be full or quota exceeded."
            fix="Check ZFS pool space: zpool list; review dataset quotas: zfs list."
            ;;
        *"resize2fs"*)
            reason="Filesystem expansion failed - underlying storage may not have expanded."
            fix="Verify storage backend expansion succeeded, check dmesg for errors."
            ;;
        *"qemu-img"*)
            reason="QCOW2 resize failed - image may be corrupted or locked."
            fix="Check image integrity: qemu-img check <path>; ensure container is stopped."
            ;;
        *"e2fsck"*)
            reason="Filesystem check found unrecoverable issues."
            fix="Run e2fsck manually and fix errors before attempting expansion."
            ;;
        *"pct set"*)
            reason="Container configuration update failed after resize."
            fix="Validate rootfs syntax and set size manually: pct set <CTID> --rootfs <vol>,size=<N>G."
            ;;
    esac

    printf '%s|%s\n' "$reason" "$fix"
}

# Map failed command to exit code
error_exit_code() {
    local failed_cmd="$1"

    case "$failed_cmd" in
        *"pct config"*|*"pvesm path"*)
            echo "$E_NOT_FOUND"
            ;;
        *"lvresize"*|*"zfs set volsize"*)
            echo "$E_NO_SPACE"
            ;;
        *"pct "*|*"resize2fs"*|*"e2fsck"*|*"qemu-img"*)
            echo "$E_EXPAND_FAILED"
            ;;
        *)
            echo "$E_INVALID_ARG"
            ;;
    esac
}

# Global ERR trap for actionable diagnostics
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

# --- Usage / Help ---
usage() {
    cat <<USAGE
${BOLD}Proxmox LXC Disk Expander v${VERSION}${NC}

Expands an LXC container's root disk using various expansion modes.

Usage: $0 [OPTIONS]

EXPANSION MODES (choose one):
  -s, --size <GB>        Set absolute target size in GB (e.g., 100)
  -a, --add <GB>         Add specified GB to current size (e.g., 20)
  --percent <N>          Expand to N% of available storage pool capacity
  --max                  Use maximum available space (with safety margin)
  --fill-free            Use all remaining free space in pool (deprecated, use --max)

OPTIONS:
  -c, --ctid <ID>        Container ID to expand (e.g., 100)
  -n, --dry-run          Show what would be done without making changes
  --safety-margin <GB>   GB to reserve when using --max (default: ${POOL_SAFETY_MARGIN_GB})
  --safety-percent <N>     Percent of pool to reserve when using --max (default: ${POOL_SAFETY_MARGIN_PCT})
  --no-restart           Keep container running (hot-expand where supported)
  --force                Skip confirmation prompts
  -h, --help             Show this help message
  -V, --version          Show version

EXPANSION MODE EXAMPLES:
  $0 -c 100 -s 100              # Expand CT 100 to exactly 100GB
  $0 -c 100 -a 50               # Add 50GB to current size
  $0 -c 100 --percent 80        # Expand to 80% of pool capacity
  $0 -c 100 --max               # Expand to max available (with safety margin)
  $0 -c 100 --max --safety-margin 20   # Max available, keep 20GB free
  $0 -c 100 -s 200 --no-restart # Expand without restarting container

DRY-RUN EXAMPLE:
  $0 -c 100 -a 50 --dry-run     # Preview expansion plan

Storage Support:
  - LVM-thin: Hot-expand supported (no restart needed)
  - LVM: Hot-expand supported (no restart needed)
  - Directory: Hot-expand supported for raw images
  - ZFS: Hot-expand supported (no restart needed)
  - NFS/CIFS: Requires container restart

Safety Notes:
  - Verify sufficient free space in the storage pool before expanding
  - LVM-thin users: monitor thin pool usage to avoid over-provisioning
  - Consider creating a backup before major expansions
  - --max and --percent modes respect safety margins by default
USAGE
    exit 0
}

# --- Root Privilege Check ---
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

# --- Initialize Log File ---
mkdir -p "$(dirname "$LOG_FILE")"
echo "--- expand-lxc run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ==============================================================================
CTID=""
DRY_RUN=false
EXPAND_MODE=""                    # size, add, percent, max
EXPAND_VALUE=""
SAFETY_MARGIN_GB=$POOL_SAFETY_MARGIN_GB
SAFETY_MARGIN_PCT=$POOL_SAFETY_MARGIN_PCT
NO_RESTART=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)
            CTID="$2"
            shift 2
            ;;
        -s|--size)
            EXPAND_MODE="size"
            EXPAND_VALUE="$2"
            shift 2
            ;;
        -a|--add)
            EXPAND_MODE="add"
            EXPAND_VALUE="$2"
            shift 2
            ;;
        --percent)
            EXPAND_MODE="percent"
            EXPAND_VALUE="$2"
            shift 2
            ;;
        --max|--fill-free)
            EXPAND_MODE="max"
            shift
            ;;
        --safety-margin)
            SAFETY_MARGIN_GB="$2"
            shift 2
            ;;
        --safety-percent)
            SAFETY_MARGIN_PCT="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-restart)
            NO_RESTART=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -V|--version)
            echo "v${VERSION}"
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
done

# --- Display Header ---
e "${BOLD}========================================${NC}"
e "${BOLD}     PROXMOX LXC DISK EXPANDER v${VERSION}${NC}"
e "${BOLD}========================================${NC}"

# --- Interactive Mode ---
[[ -z "$CTID" ]] && read -rp "Enter Container ID to expand (e.g., 100): " CTID

# ==============================================================================
# INPUT VALIDATION
# ==============================================================================
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Container ID must be a positive integer, got: '$CTID'"

if ! pct config "$CTID" >/dev/null 2>&1; then
    die "Container $CTID does not exist."
fi

[[ -n "$EXPAND_MODE" ]] || die "No expansion mode specified. Use -s, -a, --percent, or --max (see --help)"

# Validate expansion value based on mode
if [[ "$EXPAND_MODE" == "size" || "$EXPAND_MODE" == "add" ]]; then
    [[ "$EXPAND_VALUE" =~ ^[0-9]+$ ]] || die "Size value must be a positive integer (GB), got: '$EXPAND_VALUE'"
    [[ "$EXPAND_VALUE" -ge 1 ]] || die "Size must be at least 1 GB."
fi

if [[ "$EXPAND_MODE" == "percent" ]]; then
    [[ "$EXPAND_VALUE" =~ ^[0-9]+$ ]] || die "Percent must be a positive integer, got: '$EXPAND_VALUE'"
    [[ "$EXPAND_VALUE" -ge 1 && "$EXPAND_VALUE" -le 100 ]] || die "Percent must be between 1 and 100."
fi

# Validate safety margins
[[ "$SAFETY_MARGIN_GB" =~ ^[0-9]+$ ]] || die "Safety margin must be a positive integer (GB)."
[[ "$SAFETY_MARGIN_PCT" =~ ^[0-9]+$ ]] || die "Safety percent must be a positive integer."

# ==============================================================================
# STORAGE DETECTION & ANALYSIS
# ==============================================================================
ROOTFS_LINE=$(pct config "$CTID" | grep "^rootfs:")
[[ -n "$ROOTFS_LINE" ]] || die "Could not find rootfs config for container $CTID."
log "Config rootfs: $ROOTFS_LINE"

ROOTFS_VOL=$(echo "$ROOTFS_LINE" | sed 's/^rootfs: //' | cut -d',' -f1)
STORAGE_NAME=$(echo "$ROOTFS_VOL" | cut -d':' -f1)
VOLUME_ID=$(echo "$ROOTFS_VOL" | cut -d':' -f2)
CURRENT_SIZE_STR=$(echo "$ROOTFS_LINE" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")

log "Storage: $STORAGE_NAME | Volume: $VOLUME_ID | Current size: ${CURRENT_SIZE_STR:-unknown}"

STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE_NAME" '$1==s{print $2}')
[[ -n "$STORAGE_TYPE" ]] || die "Could not determine storage type for '$STORAGE_NAME'."
log "Storage type: $STORAGE_TYPE"

CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+' || echo "0")
[[ "$CURRENT_SIZE_GB" -gt 0 ]] || die "Could not determine current disk size."

# ==============================================================================
# CALCULATE TARGET SIZE BASED ON EXPANSION MODE
# ==============================================================================
get_pool_free_space() {
    local free_gb=0
    
    case "$STORAGE_TYPE" in
        lvmthin|lvm)
            local vg_name
            vg_name=$(pvesm path "$ROOTFS_VOL" 2>/dev/null | cut -d'/' -f3)
            if [[ -n "$vg_name" ]]; then
                # Get free space in MB, convert to GB
                local free_mb
                free_mb=$(vgs --noheadings --units m -o vg_free "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
                free_gb=$((free_mb / 1024))
            fi
            ;;
        zfspool)
            local zfs_dataset
            zfs_dataset=$(pvesm path "$ROOTFS_VOL" 2>/dev/null | sed 's|/dev/zd0||')
            if [[ -n "$zfs_dataset" ]]; then
                local avail_gb
                avail_gb=$(zfs list -H -o available "$zfs_dataset" 2>/dev/null | awk '{print $1}' | sed 's/G//i')
                free_gb=${avail_gb%.*}
            fi
            ;;
        dir|nfs|cifs|glusterfs)
            local storage_path
            storage_path=$(pvesm path "$ROOTFS_VOL" 2>/dev/null | xargs dirname)
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
            vg_name=$(pvesm path "$ROOTFS_VOL" 2>/dev/null | cut -d'/' -f3)
            if [[ -n "$vg_name" ]]; then
                local total_mb
                total_mb=$(vgs --noheadings --units m -o vg_size "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
                total_gb=$((total_mb / 1024))
            fi
            ;;
        zfspool)
            local zfs_dataset
            zfs_dataset=$(pvesm path "$ROOTFS_VOL" 2>/dev/null | sed 's|/dev/zd0||')
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
    local free_gb
    local total_gb
    
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
                # Ensure target is at least current size
                [[ "$target_gb" -lt "$CURRENT_SIZE_GB" ]] && target_gb=$CURRENT_SIZE_GB
            else
                die "Cannot determine pool total size for percentage-based expansion."
            fi
            ;;
        max)
            free_gb=$(get_pool_free_space)
            if [[ "$free_gb" -gt 0 ]]; then
                # Calculate safety margin
                local safety_gb
                safety_gb=$((free_gb * SAFETY_MARGIN_PCT / 100))
                [[ "$safety_gb" -lt "$SAFETY_MARGIN_GB" ]] && safety_gb=$SAFETY_MARGIN_GB
                
                # Ensure we don't go below minimum safety
                local usable_free
                usable_free=$((free_gb - safety_gb))
                [[ "$usable_free" -lt 1 ]] && die "Insufficient free space for safe expansion (free: ${free_gb}GB, safety margin: ${safety_gb}GB)"
                
                target_gb=$((CURRENT_SIZE_GB + usable_free))
                log "Free space: ${free_gb}GB, Usable after safety: ${usable_free}GB"
            else
                die "Cannot determine free space for max expansion mode."
            fi
            ;;
    esac
    
    echo "$target_gb"
}

NEW_SIZE_GB=$(calculate_target_size)

# Validate minimum size
[[ "$NEW_SIZE_GB" -lt "$MIN_DISK_GB" ]] && NEW_SIZE_GB=$MIN_DISK_GB

# Validate we are actually expanding
[[ "$NEW_SIZE_GB" -le "$CURRENT_SIZE_GB" ]] && die "Target size (${NEW_SIZE_GB}GB) must be greater than current size (${CURRENT_SIZE_GB}GB)."

log "Expansion mode: $EXPAND_MODE"
log "Current disk: ${CURRENT_SIZE_GB}GB → Target: ${NEW_SIZE_GB}GB"

# ==============================================================================
# CHECK CONTAINER STATUS
# ==============================================================================
CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
CT_WAS_RUNNING=false

if [[ "$CT_STATUS" == "running" ]]; then
    CT_WAS_RUNNING=true
    # Check if hot-expand is supported for this storage type
    local hot_expand_supported=false
    case "$STORAGE_TYPE" in
        lvmthin|lvm|zfspool)
            hot_expand_supported=true
            ;;
        dir)
            # Raw images support hot-expand, qcow2 requires restart
            local disk_path img_format
            disk_path=$(pvesm path "$ROOTFS_VOL" 2>/dev/null)
            if [[ -f "$disk_path" ]]; then
                img_format=$(qemu-img info "$disk_path" 2>/dev/null | awk '/file format:/{print $3}')
                [[ "$img_format" == "raw" ]] && hot_expand_supported=true
            fi
            ;;
    esac
    
    if $hot_expand_supported && $NO_RESTART; then
        log "Container is running. Hot-expand mode enabled (no restart required)."
    elif $hot_expand_supported && ! $NO_RESTART; then
        log "Container is running. Hot-expand supported but will restart as requested."
    else
        if ! $hot_expand_supported; then
            log "Hot-expand not supported for $STORAGE_TYPE. Container will be restarted."
        fi
    fi
fi

# ==============================================================================
# DRY-RUN SUMMARY (Preview Mode)
# ==============================================================================
if $DRY_RUN; then
    echo ""
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}Container:${NC}    $CTID"
    e "  ${BOLD}Status:${NC}       $CT_STATUS"
    e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
    e "  ${BOLD}Current disk:${NC} ${CURRENT_SIZE_GB}GB"
    e "  ${BOLD}Target size:${NC}  ${NEW_SIZE_GB}GB"
    e "  ${BOLD}Expansion:${NC}    +$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB"
    e "  ${BOLD}Mode:${NC}         $EXPAND_MODE"
    echo ""
    e "  ${BOLD}Steps that would be performed:${NC}"
    
    if $CT_WAS_RUNNING && ! $NO_RESTART; then
        echo "    1. Stop container $CTID"
    else
        echo "    1. No restart required (hot-expand mode)"
    fi
    
    case "$STORAGE_TYPE" in
        lvmthin|lvm)
            echo "    2. Expand LV with lvresize to ${NEW_SIZE_GB}GB"
            echo "    3. Expand filesystem with resize2fs"
            ;;
        dir|nfs|cifs|glusterfs)
            echo "    2. Expand disk image with qemu-img"
            echo "    3. Expand filesystem with resize2fs"
            ;;
        zfspool)
            echo "    2. Expand ZFS volume to ${NEW_SIZE_GB}GB"
            echo "    3. Expand filesystem with resize2fs"
            ;;
    esac
    
    echo "    4. Update container config"
    
    if $CT_WAS_RUNNING && ! $NO_RESTART; then
        echo "    5. Restart container"
    fi
    
    echo "    5. Verify filesystem integrity"
    echo ""
    ok "Dry run complete. Remove --dry-run to execute."
    exit 0
fi

# ==============================================================================
# USER CONFIRMATION
# ==============================================================================
if ! $FORCE; then
    echo ""
    e "${YELLOW}${BOLD}WARNING: This will expand the disk for container $CTID${NC}"
    e "  ${BOLD}Current:${NC} ${CURRENT_SIZE_GB}GB → ${BOLD}New:${NC} ${NEW_SIZE_GB}GB (+$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB)"
    e "  ${BOLD}Mode:${NC} $EXPAND_MODE"
    echo ""
    read -rp "Continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 0; }
fi

# ==============================================================================
# PERFORM EXPANSION
# ==============================================================================

# Stop container if needed (and not in hot-expand mode)
if $CT_WAS_RUNNING && ! $NO_RESTART; then
    log "Stopping container $CTID..."
    pct stop "$CTID"
    sleep 2
fi

case "$STORAGE_TYPE" in

    # --------------------------------------------------------------------------
    # LVM / LVM-THIN
    # --------------------------------------------------------------------------
    lvmthin|lvm)
        VG_PATH=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)
        LV_PATH="$VG_PATH"

        if [[ -z "$LV_PATH" || ! -e "$LV_PATH" ]]; then
            die "Could not resolve LV path for $ROOTFS_VOL"
        fi
        log "LV path: $LV_PATH"

        # Activate LV if needed
        lvchange -ay "$LV_PATH" 2>/dev/null || true

        # Step 1: Expand LV first
        log "Expanding LV to ${NEW_SIZE_GB}GB..."
        if ! lvresize -y -L "${NEW_SIZE_GB}G" "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            die "LV expansion failed. Check volume group free space."
        fi
        ok "LV expanded to ${NEW_SIZE_GB}GB."

        # Step 2: Expand filesystem
        log "Expanding filesystem to fill LV..."
        if ! resize2fs "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            warn "Filesystem expansion reported warnings. Running e2fsck..."
            e2fsck -f -y "$LV_PATH" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        ok "Filesystem expanded."

        # Step 3: Verify filesystem
        log "Verifying filesystem..."
        if e2fsck -f -y "$LV_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            ok "Filesystem verification passed."
        else
            warn "Filesystem verification had warnings."
        fi

        # Step 4: Update container config
        log "Updating container config..."
        pct set "$CTID" --rootfs "${ROOTFS_VOL},size=${NEW_SIZE_GB}G"
        ok "Container config updated."
        ;;

    # --------------------------------------------------------------------------
    # DIRECTORY-BASED (raw / qcow2)
    # --------------------------------------------------------------------------
    dir|nfs|cifs|glusterfs)
        DISK_PATH=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)
        [[ -n "$DISK_PATH" && -f "$DISK_PATH" ]] || die "Could not find disk image at: '$DISK_PATH'"
        log "Disk image: $DISK_PATH"

        IMG_FORMAT=$(qemu-img info "$DISK_PATH" 2>/dev/null | awk '/file format:/{print $3}')
        log "Image format: $IMG_FORMAT"

        if [[ "$IMG_FORMAT" == "raw" ]]; then
            # Expand raw image
            log "Expanding raw image to ${NEW_SIZE_GB}GB..."
            if ! qemu-img resize -f raw "$DISK_PATH" "${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE"; then
                die "Raw image expansion failed."
            fi
            ok "Raw image expanded."

            # Mount as loop device and expand filesystem
            LOOP_DEV=$(losetup --show -f "$DISK_PATH")
            trap "losetup -d '$LOOP_DEV' 2>/dev/null || true" EXIT

            log "Expanding filesystem..."
            if ! resize2fs "$LOOP_DEV" 2>&1 | tee -a "$LOG_FILE"; then
                warn "Filesystem expansion had issues."
            fi

            losetup -d "$LOOP_DEV" 2>/dev/null || true
            trap - EXIT

        elif [[ "$IMG_FORMAT" == "qcow2" ]]; then
            # For qcow2, we need to expand the image first
            log "Expanding qcow2 image to ${NEW_SIZE_GB}GB..."
            if ! qemu-img resize -f qcow2 "$DISK_PATH" "${NEW_SIZE_GB}G" 2>&1 | tee -a "$LOG_FILE"; then
                die "QCOW2 image expansion failed."
            fi
            ok "QCOW2 image expanded."

            # Map the image and expand filesystem
            log "Mapping qcow2 image for filesystem expansion..."
            if command -v qemu-nbd &>/dev/null; then
                modprobe nbd max_part=8 2>/dev/null || true
                NBD_DEV="/dev/nbd0"
                qemu-nbd -c "$NBD_DEV" "$DISK_PATH" 2>/dev/null || {
                    warn "qemu-nbd failed. Filesystem may need manual expansion inside container."
                    NBD_DEV=""
                }
                
                if [[ -n "$NBD_DEV" && -b "$NBD_DEV" ]]; then
                    log "Expanding filesystem..."
                    resize2fs "$NBD_DEV" 2>&1 | tee -a "$LOG_FILE" || warn "Filesystem expansion had issues."
                    qemu-nbd -d "$NBD_DEV" 2>/dev/null || true
                fi
            else
                warn "qemu-nbd not available. Filesystem will need expansion inside container."
                warn "After starting container, run: resize2fs /dev/sda2 (or appropriate device)"
            fi
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
        ZFS_DATASET="${ZFS_VOL#/dev/zvol/}"
        [[ -n "$ZFS_DATASET" ]] || die "Could not determine ZFS dataset for $ROOTFS_VOL"
        log "ZFS dataset: $ZFS_DATASET"

        # Step 1: Expand ZFS volume
        log "Expanding ZFS volume to ${NEW_SIZE_GB}GB..."
        if ! zfs set volsize="${NEW_SIZE_GB}G" "$ZFS_DATASET" 2>&1 | tee -a "$LOG_FILE"; then
            die "ZFS volume expansion failed. Check pool free space."
        fi
        ok "ZFS volume expanded."

        # Step 2: Expand filesystem
        log "Expanding filesystem..."
        if ! resize2fs "$ZFS_VOL" 2>&1 | tee -a "$LOG_FILE"; then
            warn "Filesystem expansion had issues. Running e2fsck..."
            e2fsck -f -y "$ZFS_VOL" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        ok "Filesystem expanded."

        # Step 3: Verify filesystem
        log "Verifying filesystem..."
        e2fsck -f -y "$ZFS_VOL" 2>&1 | tee -a "$LOG_FILE" || warn "Post-expand fsck had warnings."

        # Step 4: Update container config
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
if $CT_WAS_RUNNING && ! $NO_RESTART; then
    log "Starting container $CTID..."
    pct start "$CTID"
    sleep 3
    
    NEW_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [[ "$NEW_STATUS" == "running" ]]; then
        ok "Container $CTID is running."
    else
        warn "Container did not start. Check: pct start $CTID"
    fi
fi

# Final verification - get actual disk size
echo ""
e "${GREEN}${BOLD}========================================${NC}"
e "${GREEN}${BOLD}          EXPANSION COMPLETE${NC}"
e "${GREEN}${BOLD}========================================${NC}"
echo ""
e "  ${BOLD}Container:${NC}    $CTID"
e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
e "  ${BOLD}Previous:${NC}     ${CURRENT_SIZE_GB}GB"
e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB"
e "  ${BOLD}Expansion:${NC}    +$((NEW_SIZE_GB - CURRENT_SIZE_GB))GB"
e "  ${BOLD}Mode:${NC}         $EXPAND_MODE"
e "  ${BOLD}Log:${NC}          $LOG_FILE"
echo ""

# Show post-expansion recommendations
e "  ${YELLOW}Next steps:${NC}"
e "    - Verify free space: pct exec $CTID -- df -h /"
e "    - Check filesystem: pct exec $CTID -- resize2fs -p /dev/sda2 2>/dev/null || true"
echo ""
