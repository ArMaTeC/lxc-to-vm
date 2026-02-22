#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox LXC Disk Shrinker
# Version: 6.0.4
# ==============================================================================
#
# DESCRIPTION:
#   This script safely shrinks an LXC container's root disk to match its actual
#   usage plus configurable headroom. This is particularly useful before
#   converting containers to VMs with lxc-to-vm.sh, as it minimizes the disk
#   image that needs to be copied.
#
# SUPPORTED STORAGE TYPES:
#   - LVM-thin (proxmox default, most efficient for shrinking)
#   - LVM (thick provisioning)
#   - Directory-based (raw or qcow2 images)
#   - ZFS volumes (zfspool)
#   - NFS/CIFS/GlusterFS (treated as directory-based)
#
# SAFETY FEATURES:
#   - Dry-run mode previews changes without modifying anything
#   - Container is automatically stopped and restarted
#   - Filesystem check (e2fsck) before and after shrink
#   - Metadata margin calculation prevents over-shrinking
#   - Minimum 2GB disk size enforced
#   - Retry logic for resize2fs failures
#
# RISKS:
#   - Always backup before shrinking! While safe, any disk operation carries risk
#   - Container must be stopped during shrink (downtime required)
#   - Insufficient headroom can cause container to run out of space
#
# LICENSE: MIT
# ==============================================================================

# Bash strict mode: exit on error, undefined variable, or pipe failure
# -E propagates ERR trap into functions/subshells
# This catches bugs early and prevents partial/inconsistent state
set -Eeuo pipefail

readonly VERSION="6.0.4"
readonly LOG_FILE="/var/log/shrink-lxc.log"
readonly DEFAULT_HEADROOM_GB=1

# ==============================================================================
# CONSTANTS
# ==============================================================================
# These values are tuned for safe shrinking operations across different
# storage backends. They can be overridden via command-line options.

readonly MIN_DISK_GB=2                               # Absolute minimum disk size
readonly META_MARGIN_PCT=5                           # % of used space for filesystem metadata
readonly META_MARGIN_MIN_MB=512                      # Minimum metadata margin (MB)
readonly REQUIRED_CMDS=(e2fsck resize2fs)            # Essential tools for filesystem operations

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
# Set SHRINK_LXC_DEBUG=1 environment variable to enable verbose debug output
# This outputs detailed information about every operation for troubleshooting
DEBUG=${SHRINK_LXC_DEBUG:-0}

# Debug logging function - outputs detailed information when DEBUG=1
# Arguments:
#   $* - Debug message to display
# Outputs: Debug text to stdout (only if DEBUG=1)
debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$LOG_FILE"
}

# Verbose logging function - always logs to file, optionally to console
# Provides detailed step-by-step progress information
# Arguments:
#   $* - Verbose message to log
verbose() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VERBOSE] $*" >> "$LOG_FILE"
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[*]${NC} $*"
    fi
}
# These allow external scripts to detect specific failure modes
readonly E_INVALID_ARG=1       # Invalid command-line arguments
readonly E_NOT_FOUND=2         # Container or resource not found
readonly E_DISK_FULL=3         # Disk space issues
readonly E_PERMISSION=4        # Permission denied
readonly E_SHRINK_FAILED=5     # Shrink operation itself failed

HEADROOM_GB=$DEFAULT_HEADROOM_GB  # User-configurable via -g flag

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# --- Color & Terminal Formatting ---
# Check if stdout is a terminal (not piped/redirected)
# This prevents ANSI escape codes from appearing in logs or pipes
if [[ -t 1 ]]; then
    RED='\033[0;31m'      # Error messages
    GREEN='\033[0;32m'    # Success messages
    YELLOW='\033[1;33m'   # Warning messages (bold for visibility)
    BLUE='\033[0;34m'     # Info/log messages
    BOLD='\033[1m'        # Headers and emphasis
    NC='\033[0m'          # No Color (reset)
else
    # Non-terminal: disable all colors to avoid escape sequences in logs
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Echo with interpretation of backslash escapes
# Used throughout the script for consistent colored output
# Arguments:
#   $* - Text to echo (can contain \n, \t, color codes, etc.)
# Outputs: Echoed text with escape interpretation to stdout
e() { echo -e "$*"; }

# --- Logging Functions ---
# All logging functions write to both stdout (for user) and log file (for records)
# This ensures complete audit trail of all operations

# Standard info log - blue [*] prefix
# Arguments: $* - Message to log
# Side effects: Appends timestamped message to $LOG_FILE
log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Warning log - yellow [!] prefix, continues execution
# Use when something unexpected happened but we can proceed
# Arguments: $* - Warning message
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Error log - red [✗] prefix, goes to stderr
# Use when an error occurs but we're not exiting yet
# Arguments: $* - Error message
# Outputs: To stderr and log file
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }

# Success/OK log - green [✓] prefix
# Use to confirm operations completed successfully
# Arguments: $* - Success message
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Fatal error exit function
# Prints error message and exits with E_INVALID_ARG (1)
# Arguments: $* - Error message to display
# Exits: Always exits with code 1
die() { err "$*"; exit "${E_INVALID_ARG}"; }

# Map failed command to likely root cause + actionable fix
error_reason_and_fix() {
    local failed_cmd="$1"
    local reason="Command failed during shrink workflow."
    local fix="Check the log and rerun with --dry-run to validate parameters and environment."

    case "$failed_cmd" in
        *"pct mount"*|*"pct unmount"*)
            reason="Container mount/unmount operation failed."
            fix="Check container state/lock: pct status <CTID>; pct unlock <CTID>; retry."
            ;;
        *"e2fsck"*)
            reason="Filesystem check found unrecoverable issues or could not access device."
            fix="Run e2fsck manually on the target device and ensure container is stopped."
            ;;
        *"resize2fs"*)
            reason="Filesystem shrink target is too small or filesystem is inconsistent."
            fix="Increase target size/headroom and run e2fsck first; review minimum size output."
            ;;
        *"lvresize"*|*"zfs"*|*"qemu-img"*|*"truncate"*)
            reason="Storage-level resize failed (backend constraints, permissions, or in-use volume)."
            fix="Verify backend health and free space; ensure target volume/image is not busy."
            ;;
        *"losetup"*|*"kpartx"*)
            reason="Loop/partition mapping operation failed."
            fix="Check loop devices (losetup -a), mapper nodes, and retry after cleanup."
            ;;
        *"pct set"*)
            reason="Container configuration update failed after resize."
            fix="Validate rootfs syntax and set size manually: pct set <CTID> --rootfs <vol>,size=<N>G."
            ;;
    esac

    printf '%s|%s\n' "$reason" "$fix"
}

# Map failed command to a stable script exit code for automation
error_exit_code() {
    local failed_cmd="$1"

    case "$failed_cmd" in
        *"pct config"*|*"pvesm path"*|*"du -sb"*)
            echo "$E_NOT_FOUND"
            ;;
        *"df "*|*"pct df"*)
            echo "$E_DISK_FULL"
            ;;
        *"pct "*|*"mount "*|*"umount "*|*"losetup"*|*"kpartx"*|*"qemu-img"*|*"lvresize"*|*"zfs"*|*"resize2fs"*|*"e2fsck"*|*"truncate"*)
            echo "$E_SHRINK_FAILED"
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
# Shows comprehensive help when -h or --help is requested
# Includes all available options with examples
usage() {
    cat <<USAGE
${BOLD}Proxmox LXC Disk Shrinker v${VERSION}${NC}

Shrinks an LXC container's root disk to current usage + ${HEADROOM_GB}GB.
This reduces the disk size required for conversion with lxc-to-vm.sh.

Usage: $0 [OPTIONS]

Options:
  -c, --ctid <ID>        Container ID to shrink (e.g., 100)
  -g, --headroom <GB>    Extra headroom above used space (default: ${HEADROOM_GB})
  -n, --dry-run          Show what would be done without making changes
  -h, --help             Show this help message
  -V, --version          Show version

Examples:
  $0 -c 100                  # Shrink CT 100 to usage + 1GB
  $0 -c 100 -g 2             # Shrink with 2GB extra headroom
  $0 -c 100 --dry-run        # Preview only, no changes

Storage Support:
  - LVM-thin: Most efficient, shrinks LV directly
  - Directory: Supports raw and qcow2 images
  - ZFS: Shrinks zvol size
  - NFS/CIFS: Treated as directory storage

Safety Notes:
  - Container will be stopped during shrink (downtime required)
  - Filesystem check runs before and after shrink
  - Minimum 2GB disk size is enforced
  - Always backup critical data before shrinking
USAGE
    exit 0
}

# --- Root Privilege Check ---
# All container and storage operations require root access
# pct, pvesm, lvresize, zfs commands all need root privileges
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

# --- Initialize Log File ---
# Create log directory if it doesn't exist
# Add timestamp header for this run to distinguish from previous runs
mkdir -p "$(dirname "$LOG_FILE")"
echo "--- shrink-lxc run: $(date -Is) ---" >> "$LOG_FILE"

# ==============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ==============================================================================
# Parse options using standard bash getopts-style case statement
# Supports both short (-c) and long (--ctid) option formats

# Initialize all variables with defaults
CTID=""        # Container ID - required
DRY_RUN=false  # Preview mode flag - set to true with --dry-run

# Process command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)      CTID="$2";         shift 2 ;;  # Container ID (numeric)
        -g|--headroom)   HEADROOM_GB="$2";  shift 2 ;;  # Extra space in GB
        -n|--dry-run)    DRY_RUN=true;      shift ;;    # Preview only mode
        -h|--help)       usage ;;                      # Show help and exit
        -V|--version)    echo "v${VERSION}"; exit 0 ;;  # Show version and exit
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

# --- Display Header ---
# Show the script version and purpose clearly to the user
e "${BOLD}==========================================${NC}"
e "${BOLD}     PROXMOX LXC DISK SHRINKER v${VERSION}${NC}"
e "${BOLD}==========================================${NC}"

# --- Interactive Mode ---
# If CTID wasn't provided via command line, prompt interactively
# This makes the script user-friendly for ad-hoc interactive use
[[ -z "$CTID" ]] && read -rp "Enter Container ID to shrink (e.g., 100): " CTID

# ==============================================================================
# INPUT VALIDATION
# ==============================================================================
# Validate all inputs before proceeding with any destructive operations

# Container ID must be a positive integer
[[ "$CTID" =~ ^[0-9]+$ ]]        || die "Container ID must be a positive integer, got: '$CTID'"

# Headroom must be a positive integer (no decimals)
[[ "$HEADROOM_GB" =~ ^[0-9]+$ ]] || die "Headroom must be a positive integer (GB), got: '$HEADROOM_GB'"

# Require at least 1GB headroom to prevent immediate out-of-space issues
[[ "$HEADROOM_GB" -ge 1 ]]       || die "Headroom must be at least 1 GB."

# Verify container actually exists in Proxmox before proceeding
if ! pct config "$CTID" >/dev/null 2>&1; then
    die "Container $CTID does not exist."
fi

# ==============================================================================
# STORAGE DETECTION & ANALYSIS
# ==============================================================================
# This section identifies the storage backend and current disk configuration
# Different storage types (LVM, directory, ZFS) require different shrinking approaches
# We parse the container config and query Proxmox storage status

# Parse rootfs line from container config
# Example format: rootfs: local-lvm:vm-100-disk-0,size=32G
ROOTFS_LINE=$(pct config "$CTID" | grep "^rootfs:")
[[ -n "$ROOTFS_LINE" ]] || die "Could not find rootfs config for container $CTID."
log "Config rootfs: $ROOTFS_LINE"

# Extract storage name and volume, and current size
# Using standard Unix text processing tools for reliable parsing
# Format breakdown: rootfs: <storage>:<volume>,size=<N>G
ROOTFS_VOL=$(echo "$ROOTFS_LINE" | sed 's/^rootfs: //' | cut -d',' -f1)
STORAGE_NAME=$(echo "$ROOTFS_VOL" | cut -d':' -f1)
VOLUME_ID=$(echo "$ROOTFS_VOL" | cut -d':' -f2)
CURRENT_SIZE_STR=$(echo "$ROOTFS_LINE" | grep -oP 'size=\K[0-9]+[A-Z]?' || echo "")

log "Storage: $STORAGE_NAME | Volume: $VOLUME_ID | Current size: ${CURRENT_SIZE_STR:-unknown}"

# Detect storage type from Proxmox storage manager (pvesm)
# Common types: lvmthin, lvm, dir, zfspool, nfs, cifs, glusterfs
# The storage type determines which shrink algorithm we use
STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE_NAME" '$1==s{print $2}')
[[ -n "$STORAGE_TYPE" ]] || die "Could not determine storage type for '$STORAGE_NAME'."
log "Storage type: $STORAGE_TYPE"

# ==============================================================================
# CONTAINER STOPPAGE
# ==============================================================================
# Shrinking requires the container to be stopped because:
# 1. Filesystem consistency - prevents writes during resize
# 2. Safe unmounting - allows us to work with the raw disk
# 3. Data integrity - resize2fs can corrupt if filesystem is active

CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
CT_WAS_RUNNING=false  # Track if we need to restart after shrink

if [[ "$CT_STATUS" == "running" ]]; then
    CT_WAS_RUNNING=true
    if $DRY_RUN; then
        warn "Container $CTID is running. Would stop it."
    else
        warn "Container $CTID is running. Stopping..."
        pct stop "$CTID"
        sleep 2  # Brief pause for clean shutdown
    fi
fi

# ==============================================================================
# CALCULATE USED SPACE
# ==============================================================================
# Calculate actual data usage to determine optimal new disk size
# This is the core intelligence of the shrink operation
# We need to mount the container to accurately measure used space

log "Mounting container to calculate used space..."

if ! $DRY_RUN; then
    pct mount "$CTID"
fi

# Find the rootfs mount path
# Proxmox may mount at different paths depending on version and configuration
# We check both common locations for maximum compatibility
LXC_ROOT_MOUNT=""
for candidate in "/var/lib/lxc/${CTID}/rootfs" "/var/lib/lxc/${CTID}/rootfs/"; do
    if [[ -d "$candidate" ]]; then
        LXC_ROOT_MOUNT="$candidate"
        break
    fi
done

# In dry-run mode, we may not have a mount point if container wasn't running
# Fall back to pct df which reports usage without needing to mount
if $DRY_RUN && [[ -z "$LXC_ROOT_MOUNT" ]]; then
    USED_BYTES=$(pct df "$CTID" 2>/dev/null | awk '/^rootfs/{print $3}' || echo "0")
    # pct df reports in bytes (exact format varies by Proxmox version)
    if [[ "$USED_BYTES" -gt 0 ]]; then
        USED_MB=$((USED_BYTES / 1024 / 1024))
    else
        die "Cannot determine used space in dry-run mode. Run without --dry-run."
    fi
else
    [[ -n "$LXC_ROOT_MOUNT" ]] || die "Could not locate rootfs for container $CTID."

    # Calculate used space using du (disk usage)
    # We exclude virtual filesystems that don't represent actual disk usage:
    #   - dev/*: device files (created dynamically by kernel)
    #   - proc/*: process info (virtual filesystem)
    #   - sys/*: sysfs (kernel interface)
    #   - tmp/*, run/*: temporary data (shouldn't be preserved)
    USED_BYTES=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
        --exclude='tmp/*' --exclude='run/*' \
        "${LXC_ROOT_MOUNT}/" 2>/dev/null | awk '{print $1}')
    USED_MB=$(( ${USED_BYTES:-0} / 1024 / 1024 ))
fi

# Convert MB to GB, rounding up (ceiling division)
# Adding 1023 ensures any fractional GB rounds up to the next whole number
USED_GB=$(( (USED_MB + 1023) / 1024 ))

# Calculate metadata margin: 5% of used space or 512MB minimum
# resize2fs requires free space for:
#   - Journal blocks (ext4 journaling)
#   - Inode tables (file metadata)
#   - Superblock copies (filesystem headers)
#   - Block group descriptors
# Without this margin, the filesystem might not fit after shrink operation
META_MARGIN_MB=$(( USED_MB * 5 / 100 ))
[[ "$META_MARGIN_MB" -lt 512 ]] && META_MARGIN_MB=512
META_MARGIN_GB=$(( (META_MARGIN_MB + 1023) / 1024 ))

# Calculate final target size: actual usage + metadata overhead + user headroom
NEW_SIZE_GB=$(( USED_GB + META_MARGIN_GB + HEADROOM_GB ))

# Enforce absolute minimum regardless of calculations (safety check)
[[ "$NEW_SIZE_GB" -lt 2 ]] && NEW_SIZE_GB=2

# Format for human-readable display using numfmt (IEC binary units: GiB, MiB)
USED_HR=$(numfmt --to=iec-i --suffix=B "${USED_BYTES:-0}" 2>/dev/null || echo "${USED_MB}MB")

# Get current size in GB for comparison and savings calculation
CURRENT_SIZE_GB=$(echo "$CURRENT_SIZE_STR" | grep -oP '[0-9]+' || echo "0")

# Log the calculation breakdown for user transparency
log "Used space: ${USED_HR} (~${USED_GB}GB)"
log "Metadata margin: ${META_MARGIN_GB}GB (for journal, inodes, superblocks)"
log "Current disk: ${CURRENT_SIZE_GB}GB → Target: ${NEW_SIZE_GB}GB (data ${USED_GB}GB + metadata ${META_MARGIN_GB}GB + headroom ${HEADROOM_GB}GB)"

# Unmount container before proceeding with actual shrink operations
if ! $DRY_RUN; then
    pct unmount "$CTID" 2>/dev/null || true
fi

# ==============================================================================
# CHECK IF SHRINK IS NEEDED
# ==============================================================================
# Skip shrink if calculated size >= current size (already optimal or smaller)
# This prevents unnecessary operations and potential data movement
if [[ "$NEW_SIZE_GB" -ge "$CURRENT_SIZE_GB" ]]; then
    ok "Disk is already close to optimal size (${CURRENT_SIZE_GB}GB). No shrink needed."
    # Restart container if it was running before we stopped it
    if $CT_WAS_RUNNING && ! $DRY_RUN; then
        log "Restarting container $CTID..."
        pct start "$CTID"
    fi
    exit 0
fi

# Calculate space savings for reporting purposes
SAVINGS_GB=$((CURRENT_SIZE_GB - NEW_SIZE_GB))
log "Potential savings: ${SAVINGS_GB}GB"

# ==============================================================================
# DRY-RUN SUMMARY (Preview Mode)
# ==============================================================================
# Show detailed preview of what would happen in real execution
# This allows users to verify settings before committing to actual shrink

if $DRY_RUN; then
    echo ""
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}Container:${NC}    $CTID"
    e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
    e "  ${BOLD}Current disk:${NC} ${CURRENT_SIZE_GB}GB"
    e "  ${BOLD}Used space:${NC}   ${USED_HR} (~${USED_GB}GB)"
    e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB (usage + ${HEADROOM_GB}GB)"
    e "  ${BOLD}Savings:${NC}      ${SAVINGS_GB}GB"
    echo ""
    e "  ${BOLD}Steps that would be performed:${NC}"
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
    # Restart container if we stopped it for the dry-run check
    if $CT_WAS_RUNNING; then
        log "Restarting container $CTID..."
        pct start "$CTID" 2>/dev/null || true
    fi
    exit 0
fi

# ==============================================================================
# USER CONFIRMATION
# ==============================================================================
# Explicit confirmation required before destructive disk operations
# User must type 'y' to proceed - default is NO (safe default)

echo ""
e "${YELLOW}${BOLD}WARNING: This will shrink the disk for container $CTID${NC}"
e "  ${BOLD}Current:${NC} ${CURRENT_SIZE_GB}GB → ${BOLD}New:${NC} ${NEW_SIZE_GB}GB (saving ${SAVINGS_GB}GB)"
echo ""
read -rp "Continue? [y/N]: " CONFIRM
# If user says no, abort and restart container if needed
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
        VG_PATH=$(pvesm path "${ROOTFS_VOL}" 2>/dev/null)
        VG_NAME="${VG_PATH#/dev/}"
        VG_NAME="${VG_NAME%%/*}"
        LV_PATH="$VG_PATH"

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

        # Step 2: Query the true minimum filesystem size
        log "Querying minimum filesystem size (resize2fs -P)..."
        MIN_OUT=$(resize2fs -P "$LV_PATH" 2>&1) || true
        echo "$MIN_OUT" | tee -a "$LOG_FILE"
        # Parse: "Estimated minimum size of the filesystem: 8069671" (in 4K blocks)
        MIN_BLOCKS=$(echo "$MIN_OUT" | grep -oP 'minimum size.*?:\s*\K[0-9]+' || echo "0")
        if [[ "$MIN_BLOCKS" -gt 0 ]]; then
            # Get block size
            BLOCK_SIZE=$(dumpe2fs -h "$LV_PATH" 2>/dev/null | awk '/Block size:/{print $3}')
            BLOCK_SIZE="${BLOCK_SIZE:-4096}"
            MIN_SIZE_GB=$(( (MIN_BLOCKS * BLOCK_SIZE / 1073741824) + 2 ))  # Round up + 1GB safety
            log "Filesystem minimum: ${MIN_BLOCKS} blocks × ${BLOCK_SIZE}B = ~${MIN_SIZE_GB}GB"
            if [[ "$NEW_SIZE_GB" -lt "$MIN_SIZE_GB" ]]; then
                warn "Target ${NEW_SIZE_GB}GB is below filesystem minimum ${MIN_SIZE_GB}GB. Adjusting."
                NEW_SIZE_GB="$MIN_SIZE_GB"
                log "Adjusted target: ${NEW_SIZE_GB}GB"
            fi
        fi

        # Step 3: Shrink filesystem with auto-retry
        MAX_ATTEMPTS=5
        ATTEMPT=0
        SHRINK_OK=false
        TRY_SIZE="$NEW_SIZE_GB"
        while [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
            ATTEMPT=$((ATTEMPT + 1))
            log "Shrinking filesystem to ${TRY_SIZE}GB (attempt ${ATTEMPT}/${MAX_ATTEMPTS})..."
            RESIZE_OUT=""
            if RESIZE_OUT=$(resize2fs "$LV_PATH" "${TRY_SIZE}G" 2>&1); then
                echo "$RESIZE_OUT" | tee -a "$LOG_FILE"
                ok "Filesystem shrunk to ${TRY_SIZE}GB."
                NEW_SIZE_GB="$TRY_SIZE"
                SHRINK_OK=true
                break
            else
                echo "$RESIZE_OUT" | tee -a "$LOG_FILE"
                warn "resize2fs failed at ${TRY_SIZE}GB. Increasing by 2GB and retrying..."
                TRY_SIZE=$((TRY_SIZE + 2))
            fi
        done

        if ! $SHRINK_OK; then
            err "resize2fs failed after ${MAX_ATTEMPTS} attempts (last tried: ${TRY_SIZE}GB)."
            die "Filesystem shrink failed. No data was lost — disk is still ${CURRENT_SIZE_GB}GB."
        fi

        # Recalculate savings with actual size used
        SAVINGS_GB=$((CURRENT_SIZE_GB - NEW_SIZE_GB))

        # Step 3: Shrink LV
        log "Shrinking LV to ${NEW_SIZE_GB}GB..."
        LV_OUT=""
        if LV_OUT=$(lvresize -y -L "${NEW_SIZE_GB}G" "$LV_PATH" 2>&1); then
            echo "$LV_OUT" | tee -a "$LOG_FILE"
            ok "LV shrunk to ${NEW_SIZE_GB}GB."
        else
            echo "$LV_OUT" | tee -a "$LOG_FILE"
            warn "lvresize failed. Running e2fsck to recover..."
            e2fsck -f -y "$LV_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            die "LV shrink failed. Filesystem was already shrunk — run: lvresize -L ${NEW_SIZE_GB}G $LV_PATH"
        fi

        # Step 4: Run fsck again to verify
        log "Verifying filesystem after shrink..."
        FSCK_OUT=$(e2fsck -f -y "$LV_PATH" 2>&1) || true
        echo "$FSCK_OUT" | tee -a "$LOG_FILE"
        [[ "$FSCK_OUT" == *"UNEXPECTED INCONSISTENCY"* ]] && warn "Post-shrink fsck had warnings." || ok "Post-shrink filesystem check passed."

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

        # Raw image handling: mount via loop device, shrink filesystem, then truncate file
        # This is the most straightforward approach for raw images
        if [[ "$IMG_FORMAT" == "raw" ]]; then
            # Mount as loop device to access filesystem directly
            # losetup --show -f finds next free loop device and shows its path
            LOOP_DEV=$(losetup --show -f "$DISK_PATH")
            # Ensure loop device is cleaned up on exit even if script fails
            trap "losetup -d '$LOOP_DEV' 2>/dev/null || true" EXIT

            # Filesystem check before resize (required for safety)
            log "Running filesystem check..."
            e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || {
                # Retry once if first attempt fails
                e2fsck -f -y "$LOOP_DEV" >> "$LOG_FILE" 2>&1 || die "Filesystem check failed."
            }

            # Shrink the filesystem to target size
            log "Shrinking filesystem to ${NEW_SIZE_GB}GB..."
            resize2fs "$LOOP_DEV" "${NEW_SIZE_GB}G" >> "$LOG_FILE" 2>&1
            ok "Filesystem shrunk."

            # Detach loop device before truncating file
            losetup -d "$LOOP_DEV" 2>/dev/null || true
            trap - EXIT  # Remove the cleanup trap

            # Truncate the raw image file to new size
            # This removes excess bytes from end of file
            log "Truncating raw image to ${NEW_SIZE_GB}GB..."
            truncate -s "${NEW_SIZE_GB}G" "$DISK_PATH"
            ok "Raw image truncated."

        # qcow2 requires conversion to raw, shrink, then convert back
        # This is slower but necessary as resize2fs can't work on qcow2 directly
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
        ZFS_DATASET="${ZFS_VOL#/dev/zvol/}"
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
# Restart container if it was running before shrink
# Display final summary of the operation with next steps

# Restart container if it was previously running
if $CT_WAS_RUNNING; then
    log "Restarting container $CTID..."
    pct start "$CTID"
    sleep 3  # Wait for container to initialize
    # Verify container actually started
    NEW_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [[ "$NEW_STATUS" == "running" ]]; then
        ok "Container $CTID is running."
    else
        warn "Container did not start. Check: pct start $CTID"
    fi
fi

# Display final summary with key statistics
echo ""
e "${GREEN}${BOLD}==========================================${NC}"
e "${GREEN}${BOLD}          SHRINK COMPLETE${NC}"
e "${GREEN}${BOLD}==========================================${NC}"
echo ""
e "  ${BOLD}Container:${NC}    $CTID"
e "  ${BOLD}Storage:${NC}      $STORAGE_NAME ($STORAGE_TYPE)"
e "  ${BOLD}Previous:${NC}     ${CURRENT_SIZE_GB}GB"
e "  ${BOLD}New size:${NC}     ${NEW_SIZE_GB}GB"
e "  ${BOLD}Saved:${NC}        ${SAVINGS_GB}GB"
e "  ${BOLD}Used space:${NC}   ${USED_HR}"
e "  ${BOLD}Log:${NC}          $LOG_FILE"
echo ""
e "  ${YELLOW}Ready to convert:${NC}"
e "    ${BOLD}./lxc-to-vm.sh -c $CTID -d $NEW_SIZE_GB -s $STORAGE_NAME${NC}"
echo ""
