#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox LXC to VM Converter
# Version: 6.0.1
# ==============================================================================
#
# DESCRIPTION:
#   Converts Proxmox LXC containers to KVM virtual machines with full
#   bootloader injection and kernel installation. Supports multiple Linux
#   distributions and provides advanced features like batch processing,
#   predictive disk sizing, and Proxmox API integration.
#
# TARGET DISTRIBUTIONS:
#   - Debian/Ubuntu (GRUB2, systemd)
#   - Alpine Linux (GRUB, OpenRC)
#   - RHEL/CentOS/Rocky/Alma (GRUB2, systemd)
#   - Arch Linux (GRUB, systemd)
#
# KEY FEATURES:
#   - Automatic bootloader installation via chroot
#   - Multi-distro kernel detection and installation
#   - Network configuration migration (eth0 → ens18)
#   - Disk shrinking integration (shrink-lxc.sh)
#   - Snapshot/rollback safety
#   - Batch and range conversion modes
#   - Proxmox API cluster support
#   - Plugin/hook system for extensibility
#   - Predictive disk size advisor
#
# SUPPORTED STORAGE:
#   - LVM-thin (recommended)
#   - Directory, NFS, CIFS
#   - ZFS
#
# LICENSE: MIT
# ==============================================================================

# Bash strict mode: exit on error, undefined variable, or pipe failure
# -e: Exit immediately if a command exits with non-zero status
# -E: Propagate ERR trap into functions/subshells
# -u: Treat unset variables as an error
# -o pipefail: Return value of pipeline is value of last command to fail
set -Eeuo pipefail

readonly VERSION="6.0.1"
readonly LOG_FILE="/var/log/lxc-to-vm.log"

# ==============================================================================
# CONSTANTS
# ==============================================================================
# These defaults can be overridden via command-line options or profiles

readonly MIN_DISK_GB=2                               # Absolute minimum VM disk size
readonly DEFAULT_BRIDGE="vmbr0"                      # Default network bridge
readonly DEFAULT_DISK_FORMAT="qcow2"                 # Default disk format (qcow2 supports snapshots)
readonly DEFAULT_BIOS="seabios"                      # Default firmware (seabios=BIOS, ovmf=UEFI)
readonly REQUIRED_CMDS=(parted kpartx rsync qemu-img) # Essential external tools

# Error codes for programmatic error handling
# Allows external scripts and monitoring to detect specific failure types
readonly E_INVALID_ARG=1       # Invalid command-line arguments
readonly E_NOT_FOUND=2       # Container or VM not found
readonly E_DISK_FULL=3         # Insufficient disk space for temporary files
readonly E_PERMISSION=4        # Permission denied
readonly E_MIGRATION=5         # Proxmox cluster migration failed
readonly E_CONVERSION=6        # Core conversion process failed

# -----------------------------------------------------------------------------
# 0. HELPER FUNCTIONS
# -----------------------------------------------------------------------------
# These utility functions provide logging, formatting, and system checks
# used throughout the conversion process.

# --- Color & Terminal Formatting ---
# Enable colored output only when stdout is a terminal
# This prevents escape sequences in log files or piped output
if [[ -t 1 ]]; then
    RED='\033[0;31m'      # Error messages
    GREEN='\033[0;32m'    # Success/confirmation
    YELLOW='\033[1;33m'   # Warnings (bold for visibility)
    BLUE='\033[0;34m'     # Info/progress messages
    BOLD='\033[1m'        # Headers and emphasis
    NC='\033[0m'          # Reset all attributes
else
    # Disable colors for non-terminal output (logs, pipes)
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Echo with interpretation of backslash escapes
# Primary output function for consistent formatting
# Arguments:
#   $* - Text to display (supports \n, \t, color codes)
# Outputs: Formatted text to stdout
e() { echo -e "$*"; }

# --- Logging Functions ---
# All logging functions write to both stdout (for user) and log file (for audit)
# This ensures complete traceability of all operations.

# Log informational message with blue [*] prefix
# Arguments: $* - Message text
# Side effects: Appends to $LOG_FILE with timestamp
log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Log warning with yellow [!] prefix - continues execution
# Use for non-fatal issues that should be brought to user's attention
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Log error with red [✗] prefix to stderr
# Use when operation failed but script continues
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }

# Log success with green [✓] prefix
# Use to confirm operations completed successfully
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }

# Fatal error handler - prints error and exits
# Arguments: $* - Error message
# Exits: With E_INVALID_ARG (1)
die() { err "$*"; exit "${E_INVALID_ARG}"; }

# Map failed command to likely root cause + actionable fix
error_reason_and_fix() {
    local failed_cmd="$1"
    local reason="Command failed during conversion workflow."
    local fix="Check the full log and rerun with --dry-run to verify inputs and environment."

    case "$failed_cmd" in
        *"pct mount"*)
            reason="Container mount failed (container state, storage backend issue, or lock)."
            fix="Run: pct status <CTID>; pct unlock <CTID>; verify storage health, then retry."
            ;;
        *"rsync"*)
            reason="File copy failed due to permissions, I/O errors, or insufficient temp space."
            fix="Check free space in temp dir, source filesystem health, and retry (or use --resume)."
            ;;
        *"losetup"*|*"kpartx"*|*"parted"*|*"mkfs."*)
            reason="Disk image preparation failed (loop/mapper mapping or partition/filesystem creation)."
            fix="Check loop devices (losetup -a), /dev/mapper entries, and required disk tooling."
            ;;
        *"chroot"*"/tmp/chroot-setup.sh"*)
            reason="Kernel/bootloader injection failed inside chroot."
            fix="Review package-manager errors in log; verify DNS/repositories and distro package names."
            ;;
        *"apt-get"*|*"yum"*|*"dnf"*|*"apk"*|*"pacman"*)
            reason="Package installation failed in chroot (repo/network/package availability)."
            fix="Test internet + DNS from host/chroot, refresh repositories, and verify package names."
            ;;
        *"qm importdisk"*)
            reason="Disk import failed (storage target issue or inaccessible temp image)."
            fix="Run pvesm status; verify target storage has free space and image file exists."
            ;;
        *"qm create"*|*"qm set"*|*"qm resize"*)
            reason="VM creation/configuration failed (VMID conflict, bad storage/bridge, or permissions)."
            fix="Check qm config <VMID>, validate bridge/storage names, and ensure VMID is unused."
            ;;
    esac

    printf '%s|%s\n' "$reason" "$fix"
}

# Map failed command to a stable script exit code for automation
error_exit_code() {
    local failed_cmd="$1"

    case "$failed_cmd" in
        *"pct config"*|*"qm config"*|*"pvesm path"*)
            echo "$E_NOT_FOUND"
            ;;
        *"df "*|*"rsync"*|*"qm importdisk"*)
            echo "$E_DISK_FULL"
            ;;
        *"pct migrate"*)
            echo "$E_MIGRATION"
            ;;
        *"pct "*|*"qm "*|*"mount "*|*"umount "*|*"losetup"*|*"kpartx"*|*"parted"*|*"mkfs."*|*"grub"*|*"chroot"*)
            echo "$E_CONVERSION"
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
${BOLD}Proxmox LXC to VM Converter v${VERSION}${NC}

Usage: $0 [OPTIONS]

Options:
  -c, --ctid <ID>        Source LXC container ID
  -v, --vmid <ID>        Target VM ID
  -s, --storage <NAME>   Proxmox storage target (e.g. local-lvm)
  -d, --disk-size <GB>   Disk size in GB (omit for predictive advisor)
  -f, --format <FMT>     Disk format: qcow2 (default) | raw | vmdk
  -b, --bridge <NAME>    Network bridge (default: vmbr0)
  -t, --temp-dir <PATH>  Working directory for temp image (default: /var/lib/vz/dump)
  -B, --bios <TYPE>      Firmware type: seabios (default) | ovmf (UEFI)
  -n, --dry-run          Show what would be done without making changes
  -k, --keep-network     Preserve original network config (only add ens18 adapter)
  -S, --start            Auto-start VM and run health checks after conversion
  --shrink               Shrink LXC disk to usage + headroom before converting
  --snapshot             Create LXC snapshot before conversion (for rollback)
  --rollback-on-failure  Auto-rollback to snapshot if conversion fails
  --destroy-source         Destroy original LXC after successful conversion
  --resume               Resume interrupted conversion from partial state
  --batch <FILE>         Batch file with CTID/VMID pairs for mass conversion
  --range <START>-<END>  Convert LXC range to VM range (e.g., 100-110:200-210)
  --save-profile <NAME>  Save current options as a named profile
  --profile <NAME>       Load options from a saved profile
  --wizard               Start interactive TUI wizard with progress bars
  --parallel <N>         Run N conversions in parallel (batch mode)
  --validate-only        Run pre-flight checks without converting
  --export-to <DEST>     Export VM disk after conversion (s3://bucket, nfs://host/path, ssh://host/path)
  --as-template          Convert to VM template instead of regular VM
  --sysprep              Clean template for cloning (remove SSH keys, machine-id, etc.)
  --api-host <HOST>      Proxmox API host for cluster operations
  --api-token <TOKEN>    API token for cluster authentication
  --api-user <USER>      API user (default: root@pam)
  --migrate-to-local     Auto-migrate container to local node if on remote
  --predict-size         Use predictive advisor for disk size (analyze growth patterns)
  --no-auto-fix          Disable automatic remediation when health checks detect known issues
  -h, --help             Show this help message
  -V, --version          Show version

Hooks:
  Place executable scripts in /var/lib/lxc-to-vm/hooks/ to run at stages:
    pre-shrink, post-shrink, pre-convert, post-convert, health-check-failed, pre-destroy
  Hooks receive CTID and VMID as arguments, with HOOK_CTID, HOOK_VMID, HOOK_STAGE env vars.

Examples:
  $0                                       # Interactive mode
  $0 -c 100 -v 200 -s local-lvm -d 32     # Non-interactive
  $0 -c 100 -v 200 -s local-lvm -d 200 -t /mnt/scratch  # Use alt temp dir
  $0 -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start   # UEFI + auto-start
  $0 -c 100 -v 200 -s local-lvm -d 32 --snapshot --rollback-on-failure  # Safe conversion
  $0 --batch conversions.txt                                         # Batch mode
  $0 --range 100-110:200-210 -s local-lvm --shrink                   # Range mode
  $0 -c 100 -v 200 -s local-lvm --save-profile webserver             # Save profile
  $0 -c 100 -v 200 --profile webserver --destroy-source              # Use profile + cleanup
  $0 -c 100 -v 200 -s local-lvm --wizard                               # TUI wizard mode
  $0 --batch conversions.txt --parallel 4                            # Parallel batch
  $0 -c 100 --validate-only                                            # Pre-flight check
  $0 -c 100 -v 200 -s local-lvm --export-to s3://backup-bucket/vms   # Export to S3
  $0 -c 100 -v 200 -s local-lvm --as-template --sysprep              # Create template
  $0 -c 100 -v 200 -s local-lvm --shrink                # Auto-shrink + convert
USAGE
    exit 0
}

# --- Root check ---
# All Proxmox operations (pct, qm, pvesm) require root access
# Container mounting, loop device creation, and VM creation all need root
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

# --- Initialise log ---
# Create log directory if missing
# Add timestamp header to distinguish between runs
mkdir -p "$(dirname "$LOG_FILE")"
echo "--- lxc-to-vm run: $(date -Is) ---" >> "$LOG_FILE"

# --- Dependency installer ---
# Automatically installs missing packages via apt
# Arguments:
#   $1 - Command name to check for
#   $2 - Package name (optional, defaults to command name)
# Side effects: May run apt-get update and install
ensure_dependency() {
    local cmd="$1"
    local pkg="${2:-$1}"  # Package name can differ from command name (e.g., cmd=parted, pkg=parted)
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
# Critical safety function registered with trap
# Ensures all resources are released even on unexpected failure
# Called automatically on: EXIT (normal exit), INT (Ctrl+C), TERM (kill)
cleanup() {
    echo ""
    log "Cleaning up resources..."

    # Unmount EFI partition first (if present - only for UEFI VMs)
    # -l: lazy unmount (detach now, cleanup later)
    # -f: force unmount even if busy
    umount -lf "${MOUNT_POINT:-/nonexistent}/boot/efi" 2>/dev/null || true

    # Unmount chroot bind mounts in reverse order of mounting
    # These are needed for chroot to function (access to /dev, /proc, etc.)
    for mp in dev/pts dev proc sys; do
        umount -lf "${MOUNT_POINT:-/nonexistent}/$mp" 2>/dev/null || true
    done

    # Unmount main filesystem
    umount -lf "${MOUNT_POINT:-/nonexistent}" 2>/dev/null || true

    # Unmount LXC container if still mounted (safety check)
    if [[ -n "${CTID:-}" ]]; then
        pct unmount "$CTID" 2>/dev/null || true
    fi

    # Detach loop device and partition mappings
    # kpartx -d: delete partition mappings
    # losetup -d: detach loop device
    if [[ -n "${LOOP_DEV:-}" ]]; then
        kpartx -d "$LOOP_DEV" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    # Remove temporary working directory
    # This contains the raw disk image and other transient files
    if [[ -d "${TEMP_DIR:-}" ]]; then
        log "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Register cleanup to run automatically on script exit or interruption
# This ensures no resources are leaked even if script fails
trap cleanup EXIT INT TERM

# ==============================================================================
# PROXMOX API / CLUSTER INTEGRATION
# ==============================================================================
# These functions enable remote cluster operations via Proxmox API
# Allows running conversions from any cluster node, with auto-migration

# Check if we're in a cluster and get node info
# Arguments:
#   $1 - Container ID to locate
# Returns: Node name via stdout, or 1 if not found
# Uses: pvesh to query cluster status
get_cluster_info() {
    local ctid="$1"
    local config_output
    config_output=$(pct config "$ctid" 2>/dev/null) || return 1
    
    # Extract node from config if available (format: rootfs: storage:vol,node=X)
    local node
    node=$(echo "$config_output" | grep -oP 'node=\K[^,]+' || echo "")
    
    if [[ -n "$node" ]]; then
        echo "$node"
        return 0
    fi
    
    # Check if container is on local node
    local hostname
    hostname=$(hostname)
    if pvesh get /nodes/$hostname/lxc/$ctid/status/current >/dev/null 2>&1; then
        echo "$hostname"
        return 0
    fi
    
    # Search all cluster nodes for the container
    local nodes
    nodes=$(pvesh get /nodes --output-format json 2>/dev/null | grep -oP '"node":"\K[^"]+' || echo "")
    for n in $nodes; do
        if pvesh get /nodes/$n/lxc/$ctid/status/current >/dev/null 2>&1; then
            echo "$n"
            return 0
        fi
    done
    
    return 1
}

# API call wrapper for Proxmox cluster operations
pve_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    if [[ -z "$API_HOST" || -z "$API_TOKEN" ]]; then
        die "API credentials not configured. Use --api-host and --api-token"
    fi
    
    local url="https://${API_HOST}:8006/api2/json${endpoint}"
    local auth_header="Authorization: PVEAPIToken=${API_USER}!${API_TOKEN}"
    
    # -s: silent mode, -k: ignore SSL cert (self-signed common in Proxmox)
    if [[ "$method" == "GET" ]]; then
        curl -s -k -H "$auth_header" "$url" 2>/dev/null
    else
        curl -s -k -H "$auth_header" -X "$method" -d "$data" "$url" 2>/dev/null
    fi
}

# Migrate container to local node from remote cluster node
# This enables running conversions from any cluster node
# Arguments:
#   $1 - Container ID to migrate
# Side effects: May stop and migrate container, modifying cluster state
migrate_container_to_local() {
    local ctid="$1"
    local target_node
    target_node=$(get_cluster_info "$ctid") || die "Cannot determine node for container $ctid"
    
    local local_node
    local_node=$(hostname)
    
    if [[ "$target_node" == "$local_node" ]]; then
        log "Container $ctid is already on local node ($local_node)"
        return 0
    fi
    
    log "Container $ctid is on remote node: $target_node"
    
    if $MIGRATE_TO_LOCAL; then
        log "Migrating container $ctid from $target_node to $local_node..."
        
        if $DRY_RUN; then
            log "[DRY-RUN] Would migrate: pct migrate $ctid $local_node --online"
            return 0
        fi
        
        # Stop container first for migration (safer than online migration)
        local status
        status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            log "Stopping container $ctid before migration..."
            pct stop "$ctid"
            sleep 2
        fi
        
        # Perform migration with restart
        if pct migrate "$ctid" "$local_node" --restart; then
            ok "Container $ctid migrated to $local_node"
            sleep 3
            return 0
        else
            die "Migration failed. Container $ctid is still on $target_node"
        fi
    else
        warn "Container $ctid is on remote node $target_node"
        warn "Use --migrate-to-local to automatically migrate, or run from $target_node"
        return 1
    fi
}

# ==============================================================================
# PLUGIN / HOOK SYSTEM
# ==============================================================================
# Extensible hook system allowing custom scripts at key conversion stages
# Hooks are stored in /var/lib/lxc-to-vm/hooks/ and named by stage

# Directory where hook scripts are stored
HOOKS_DIR="/var/lib/lxc-to-vm/hooks"

# Execute a hook script if it exists and is executable
# Arguments:
#   $1 - Hook name (e.g., pre-convert, post-convert)
#   $2 - Container ID (optional, defaults to $CTID)
#   $3 - VM ID (optional, defaults to $VMID)
# Environment variables exported to hook:
#   HOOK_CTID, HOOK_VMID, HOOK_LOG_FILE, HOOK_STAGE
# Returns: 0 on success or if hook doesn't exist, 1 if hook failed
run_hook() {
    local hook_name="$1"
    local ctid="${2:-$CTID}"
    local vmid="${3:-$VMID}"
    
    local hook_script="${HOOKS_DIR}/${hook_name}"
    
    if [[ -x "$hook_script" ]]; then
        log "Running hook: $hook_name"
        export HOOK_CTID="$ctid"
        export HOOK_VMID="$vmid"
        export HOOK_LOG_FILE="$LOG_FILE"
        export HOOK_STAGE="$hook_name"
        
        if ! "$hook_script" "$ctid" "$vmid" >> "$LOG_FILE" 2>&1; then
            warn "Hook $hook_name exited with error (non-fatal)"
            return 1
        fi
        return 0
    fi
    return 0
}

# Hook execution points during conversion:
#   pre-shrink    - Before shrinking container (if --shrink used)
#   post-shrink   - After successful shrink
#   pre-convert   - Before starting conversion process
#   post-convert  - After VM creation and validation
#   health-check-failed - When post-conversion health checks fail
#   pre-destroy   - Before destroying source container

# ==============================================================================
# PREDICTIVE DISK SIZE ADVISOR
# ==============================================================================
# Analyzes historical usage patterns from log files to recommend optimal
# disk sizes with confidence intervals. Helps prevent both over-allocation
# and under-allocation of VM disk space.

# Analyze historical growth patterns from log data
# Arguments:
#   $1 - Container ID to analyze
#   $2 - Days of history to analyze (default: 30)
# Returns: Colon-separated fields: recommended:confidence:trend:min:max:avg
#   or exits with 1 if insufficient data available
analyze_growth_pattern() {
    local ctid="$1"
    local days_history="${2:-30}"
    
    # Search historical log files for usage data
    local log_entries
    log_entries=$(grep -h "CT $ctid" /var/log/lxc-to-vm*.log /var/log/shrink-lxc*.log 2>/dev/null | tail -50 || echo "")
    
    if [[ -z "$log_entries" ]]; then
        return 1
    fi
    
    # Extract historical disk usage values from log entries
    local usages
    usages=$(echo "$log_entries" | grep -oP 'Used space:.*~\K[0-9]+' | sort -n)
    
    if [[ -z "$usages" ]]; then
        return 1
    fi
    
    local count
    count=$(echo "$usages" | wc -l)
    
    # Require at least 3 data points for trend analysis
    if [[ "$count" -lt 3 ]]; then
        return 1
    fi
    
    # Calculate statistics for trend analysis
    local min max avg trend
    min=$(echo "$usages" | head -1)
    max=$(echo "$usages" | tail -1)
    
    # Calculate average usage
    local sum=0
    while read -r val; do
        sum=$((sum + val))
    done <<< "$usages"
    avg=$((sum / count))
    
    # Calculate growth trend (GB per conversion)
    trend=$(( (max - min) / count ))
    
    # Determine confidence level based on data volume
    local confidence="medium"
    [[ "$count" -gt 10 ]] && confidence="high"
    [[ "$count" -lt 5 ]] && confidence="low"
    
    # Calculate recommendation: current + (trend * 6 months) + 3GB overhead
    local current_usage
    current_usage=$(pct df "$ctid" 2>/dev/null | awk '/^rootfs/{print $3}' || echo "0")
    current_usage=$((current_usage / 1024 / 1024 / 1024))  # Convert bytes to GB
    
    local recommended=$((current_usage + (trend * 6) + 3))
    [[ "$recommended" -lt 10 ]] && recommended=10
    
    echo "${recommended}:${confidence}:${trend}:${min}:${max}:${avg}"
    return 0
}

# Get disk size recommendation with user-friendly output
# Falls back to simple heuristic if historical data unavailable
# Arguments:
#   $1 - Container ID to analyze
# Outputs: Displays analysis summary and returns recommended size via stdout
get_size_recommendation() {
    local ctid="$1"
    
    log "Analyzing growth patterns for CT $ctid..."
    
    local analysis
    analysis=$(analyze_growth_pattern "$ctid")
    
    # Fallback if no historical data available
    if [[ -z "$analysis" ]]; then
        local current_usage
        current_usage=$(pct df "$ctid" 2>/dev/null | awk '/^rootfs/{print $3}' || echo "0")
        current_usage=$((current_usage / 1024 / 1024 / 1024))
        
        local recommended=$((current_usage + 5))
        [[ "$recommended" -lt 10 ]] && recommended=10
        
        e "  ${YELLOW}No historical data available${NC}"
        e "  ${BOLD}Recommendation:${NC} ${recommended}GB (current ${current_usage}GB + 5GB headroom)"
        echo "$recommended"
        return 0
    fi
    
    # Parse analysis results
    local recommended confidence trend min max avg
    recommended="${analysis%%:*}"
    confidence="${analysis#*:}"
    confidence="${confidence%%:*}"
    trend="${analysis#*:*:*}"
    trend="${trend%%:*}"
    
    # Visual indicators for confidence levels
    local confidence_emoji="🟡"
    [[ "$confidence" == "high" ]] && confidence_emoji="🟢"
    [[ "$confidence" == "low" ]] && confidence_emoji="🔴"
    
    e "  ${confidence_emoji} ${BOLD}Confidence:${NC} ${confidence^^}"
    e "  ${BOLD}Historical range:${NC} ${min}GB - ${max}GB (avg: ${avg}GB)"
    e "  ${BOLD}Growth trend:${NC} ~${trend}GB per conversion"
    e "  ${GREEN}${BOLD}Recommendation:${NC} ${recommended}GB"
    
    echo "$recommended"
}

# ==============================================================================
# PROFILE MANAGEMENT
# ==============================================================================
# Save and load named profiles for common conversion configurations
# Profiles store settings like storage, disk format, bridge, etc.
# This allows quick reuse of common configurations without retyping

# Directory where profile files are stored
PROFILE_DIR="/var/lib/lxc-to-vm/profiles"

# Ensure profile directory exists
ensure_profile_dir() {
    mkdir -p "$PROFILE_DIR" 2>/dev/null || die "Cannot create profile directory: $PROFILE_DIR"
}

# List all saved profiles with creation dates
list_profiles() {
    ensure_profile_dir
    e "${BOLD}Available profiles:${NC}"
    local found=false
    for profile in "$PROFILE_DIR"/*.conf; do
        [[ -f "$profile" ]] || continue
        found=true
        local name=$(basename "$profile" .conf)
        local created=$(stat -c %y "$profile" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        e "  ${GREEN}•${NC} ${BOLD}$name${NC} (created: $created)"
    done
    $found || echo "  (none)"
    exit 0
}

# Save current settings as a named profile
# Arguments:
#   $1 - Profile name
# Creates: $PROFILE_DIR/$name.conf with saved settings
save_profile() {
    local name="$1"
    ensure_profile_dir
    local profile_file="$PROFILE_DIR/${name}.conf"

    # Write profile file with all current settings
    cat > "$profile_file" <<PROFILE_EOF
# Profile: $name
# Saved: $(date -Is)
STORAGE="${STORAGE:-}"
DISK_SIZE="${DISK_SIZE:-}"
DISK_FORMAT="${DISK_FORMAT:-qcow2}"
BRIDGE="${BRIDGE:-vmbr0}"
WORK_DIR="${WORK_DIR:-}"
BIOS_TYPE="${BIOS_TYPE:-seabios}"
KEEP_NETWORK="${KEEP_NETWORK:-false}"
SHRINK_FIRST="${SHRINK_FIRST:-false}"
AUTO_START="${AUTO_START:-false}"
PROFILE_EOF

    ok "Profile '${name}' saved to $profile_file"
}

# Load settings from a named profile
# Arguments:
#   $1 - Profile name
# Side effects: Sources the profile file, setting global variables
# Note: Only sets values that aren't already defined (CLI takes precedence)
load_profile() {
    local name="$1"
    local profile_file="$PROFILE_DIR/${name}.conf"

    [[ -f "$profile_file" ]] || die "Profile '$name' not found. Use --list-profiles to see available profiles."

    log "Loading profile: $name"
    # shellcheck disable=SC1090
    source "$profile_file"

    # Apply loaded values only if not already set via CLI
    [[ -z "$STORAGE" && -n "${STORAGE:-}" ]] && STORAGE="$STORAGE"
    [[ -z "$DISK_SIZE" && -n "${DISK_SIZE:-}" ]] && DISK_SIZE="$DISK_SIZE"
    [[ "$DISK_FORMAT" == "qcow2" && -n "${DISK_FORMAT:-}" ]] && DISK_FORMAT="$DISK_FORMAT"
    [[ "$BRIDGE" == "vmbr0" && -n "${BRIDGE:-}" ]] && BRIDGE="$BRIDGE"
    [[ -z "$WORK_DIR" && -n "${WORK_DIR:-}" ]] && WORK_DIR="$WORK_DIR"
    [[ "$BIOS_TYPE" == "seabios" && -n "${BIOS_TYPE:-}" ]] && BIOS_TYPE="$BIOS_TYPE"
}

# ==============================================================================
# SNAPSHOT MANAGEMENT
# ==============================================================================
# Create and manage LXC snapshots for rollback safety
# Snapshots allow restoring container if conversion fails

# Generate unique snapshot name with timestamp
SNAPSHOT_NAME="pre-conversion-$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_CREATED=false  # Track if we created a snapshot (for rollback eligibility)

# Create a snapshot of the container before conversion
# Arguments:
#   $1 - Container ID
# Side effects: Sets SNAPSHOT_CREATED to true on success
# Note: Snapshot includes container config and rootfs at point-in-time
create_snapshot() {
    local ctid="$1"
    log "Creating snapshot '${SNAPSHOT_NAME}' for container $ctid..."
    if pct snapshot "$ctid" "$SNAPSHOT_NAME" --description "Auto-created by lxc-to-vm before conversion" >> "$LOG_FILE" 2>&1; then
        SNAPSHOT_CREATED=true
        ok "Snapshot created successfully."
    else
        warn "Failed to create snapshot. Rollback will not be available."
        SNAPSHOT_CREATED=false
    fi
}

# Rollback container to snapshot (called on conversion failure)
# Arguments:
#   $1 - Container ID
# Side effects: Restores container to snapshot state and removes snapshot
rollback_snapshot() {
    local ctid="$1"
    if $SNAPSHOT_CREATED; then
        log "Rolling back container $ctid to snapshot '${SNAPSHOT_NAME}'..."
        
        if pct rollback "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
            ok "Rollback successful. Container restored."
            # Optionally remove the snapshot after rollback
            pct delsnapshot "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1 || true
        else
            err "Rollback failed! Container may be in an inconsistent state."
            err "Manual recovery: pct rollback $ctid $SNAPSHOT_NAME"
        fi
    fi
}

# Remove snapshot after successful conversion
# Arguments:
#   $1 - Container ID
remove_snapshot() {
    local ctid="$1"
    if $SNAPSHOT_CREATED; then
        log "Removing snapshot '${SNAPSHOT_NAME}' from container $ctid..."
        pct delsnapshot "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1 || warn "Failed to remove snapshot (non-critical)"
    fi
}

# ==============================================================================
# RESUME / PROGRESS PERSISTENCE
# ==============================================================================
# Save and restore conversion state for resume capability
# If conversion is interrupted (power loss, network issue, etc.),
# it can be resumed from where it left off instead of starting over

# Directory for storing resume state files
RESUME_DIR="/var/lib/lxc-to-vm/resume"
RESUME_STATE_FILE=""  # Path to current conversion's state file
RSYNC_PARTIAL_DIR=""  # Path to rsync partial data directory

# Create resume directory if it doesn't exist
ensure_resume_dir() {
    mkdir -p "$RESUME_DIR" 2>/dev/null || die "Cannot create resume directory: $RESUME_DIR"
}

# Get path to resume state file for a specific CT→VM conversion
# Arguments:
#   $1 - Container ID
#   $2 - VM ID
# Returns: Path to state file via stdout
get_resume_file() {
    local ctid="$1"
    local vmid="$2"
    echo "$RESUME_DIR/ct${ctid}-vm${vmid}.state"
}

# Save current conversion state to file
# Arguments:
#   $1 - Container ID
#   $2 - VM ID  
#   $3 - Current stage name (e.g., "rsync-failed", "disk-created")
#   $4 - Additional data (optional)
# Creates: State file with all conversion parameters
save_resume_state() {
    local ctid="$1"
    local vmid="$2"
    local stage="$3"
    local data="${4:-}"

    ensure_resume_dir
    local state_file=$(get_resume_file "$ctid" "$vmid")

    cat > "$state_file" <<RESUME_EOF
CTID="$ctid"
VMID="$vmid"
STAGE="$stage"
TIMESTAMP="$(date -Is)"
IMAGE_FILE="${IMAGE_FILE:-}"
TEMP_DIR="${TEMP_DIR:-}"
DATA="$data"
RESUME_EOF
}

# Clear resume state after successful conversion
# Arguments:
#   $1 - Container ID
#   $2 - VM ID
# Side effects: Removes state file and partial rsync data
clear_resume_state() {
    local ctid="$1"
    local vmid="$2"
    local state_file=$(get_resume_file "$ctid" "$vmid")
    [[ -f "$state_file" ]] && rm -f "$state_file"
    # Also clean up partial rsync data
    [[ -n "$RSYNC_PARTIAL_DIR" && -d "$RSYNC_PARTIAL_DIR" ]] && rm -rf "$RSYNC_PARTIAL_DIR" 2>/dev/null || true
}

# Check for existing resume state
# Arguments:
#   $1 - Container ID
#   $2 - VM ID
# Returns: 0 if state exists (loads variables), 1 if no state
check_resume_state() {
    local ctid="$1"
    local vmid="$2"
    local state_file=$(get_resume_file "$ctid" "$vmid")

    if [[ -f "$state_file" ]]; then
        # shellcheck disable=SC1090
        source "$state_file"
        log "Found partial conversion state (stage: ${STAGE:-unknown}, from: ${TIMESTAMP:-unknown})"
        return 0
    fi
    return 1
}

# ==============================================================================
# BATCH PROCESSING
# ==============================================================================

process_batch_file() {
    local batch_file="$1"
    [[ -f "$batch_file" ]] || die "Batch file not found: $batch_file"

    log "Processing batch file: $batch_file"
    local line_num=0
    local success_count=0
    local fail_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Parse CTID VMID pairs
        local batch_ctid=$(echo "$line" | awk '{print $1}')
        local batch_vmid=$(echo "$line" | awk '{print $2}')

        if [[ -z "$batch_ctid" || -z "$batch_vmid" ]]; then
            warn "Skipping invalid line $line_num: $line"
            continue
        fi

        echo ""
        log "========================================"
        log "Batch item $line_num: CT $batch_ctid → VM $batch_vmid"
        log "========================================"

        # Run conversion for this pair
        if run_single_conversion "$batch_ctid" "$batch_vmid"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            $ROLLBACK_ON_FAILURE || true  # Rollback handled in error trap
        fi
    done < "$batch_file"

    echo ""
    e "${GREEN}${BOLD}==========================================${NC}"
    e "${GREEN}${BOLD}         BATCH CONVERSION COMPLETE${NC}"
    e "${GREEN}${BOLD}==========================================${NC}"
    e "  ${BOLD}Successful:${NC} $success_count"
    e "  ${BOLD}Failed:${NC}     $fail_count"
    e "  ${BOLD}Total:${NC}      $((success_count + fail_count))"
    exit 0
}

process_range() {
    local range_spec="$1"
    # Format: 100-110:200-210 (CT range : VM range)
    local ct_range="${range_spec%%:*}"
    local vm_range="${range_spec#*:}"

    local ct_start="${ct_range%%-*}"
    local ct_end="${ct_range#*-}"
    local vm_start="${vm_range%%-*}"
    local vm_end="${vm_range#*-}"

    if [[ -z "$ct_start" || -z "$ct_end" || -z "$vm_start" || -z "$vm_end" ]]; then
        die "Invalid range format. Use: --range START-END:START-END (e.g., 100-110:200-210)"
    fi

    local count=$((ct_end - ct_start + 1))
    local vm_count=$((vm_end - vm_start + 1))

    [[ "$count" -eq "$vm_count" ]] || die "Range sizes must match: CT range has $count, VM range has $vm_count"

    log "Processing range: CT $ct_start-$ct_end → VM $vm_start-$vm_end ($count containers)"

    local success_count=0
    local fail_count=0

    for i in $(seq 0 $((count - 1))); do
        local current_ctid=$((ct_start + i))
        local current_vmid=$((vm_start + i))

        echo ""
        log "========================================"
        log "Range item $((i+1))/$count: CT $current_ctid → VM $current_vmid"
        log "========================================"

        if run_single_conversion "$current_ctid" "$current_vmid"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    echo ""
    e "${GREEN}${BOLD}==========================================${NC}"
    e "${GREEN}${BOLD}         RANGE CONVERSION COMPLETE${NC}"
    e "${GREEN}${BOLD}==========================================${NC}"
    e "  ${BOLD}Successful:${NC} $success_count"
    e "  ${BOLD}Failed:${NC}     $fail_count"
    e "  ${BOLD}Total:${NC}      $((success_count + fail_count))"
    exit 0
}

# ==============================================================================
# SINGLE CONVERSION WRAPPER
# ==============================================================================

run_single_conversion() {
    local single_ctid="$1"
    local single_vmid="$2"

    # Set global IDs for this conversion
    CTID="$single_ctid"
    VMID="$single_vmid"

    # Validate
    if ! pct config "$CTID" >/dev/null 2>&1; then
        err "Container $CTID does not exist. Skipping."
        return 1
    fi

    if qm config "$VMID" >/dev/null 2>&1; then
        err "VM ID $VMID already exists. Skipping."
        return 1
    fi

    # Create snapshot if requested
    if $CREATE_SNAPSHOT; then
        create_snapshot "$CTID"
    fi

    # Run the main conversion (trap will handle cleanup)
    if do_conversion; then
        # Success - remove snapshot and optionally destroy source
        remove_snapshot "$CTID"

        if $DESTROY_SOURCE; then
            log "Destroying original container $CTID..."
            pct destroy "$CTID" >> "$LOG_FILE" 2>&1 && ok "Source container $CTID destroyed." || warn "Failed to destroy container $CTID"
        fi

        return 0
    else
        # Failure - rollback if requested
        if $ROLLBACK_ON_FAILURE && $SNAPSHOT_CREATED; then
            rollback_snapshot "$CTID"
        fi
        return 1
    fi
}

# ==============================================================================
# 1. ARGUMENT PARSING
# ==============================================================================

CTID="" VMID="" STORAGE="" DISK_SIZE="" DISK_FORMAT="qcow2" BRIDGE="vmbr0" WORK_DIR=""
BIOS_TYPE="seabios" DRY_RUN=false KEEP_NETWORK=false AUTO_START=false SHRINK_FIRST=false
CREATE_SNAPSHOT=false ROLLBACK_ON_FAILURE=false DESTROY_SOURCE=false RESUME_MODE=false
BATCH_FILE="" RANGE_SPEC="" PROFILE_NAME="" SAVE_PROFILE_NAME=""
WIZARD_MODE=false PARALLEL_JOBS=1 VALIDATE_ONLY=false
EXPORT_DEST="" AS_TEMPLATE=false SYSPREP=false
API_HOST="" API_TOKEN="" API_USER="root@pam" MIGRATE_TO_LOCAL=false PREDICT_SIZE=false
AUTO_FIX=true

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
        --no-auto-fix)   AUTO_FIX=false;    shift ;;
        --shrink)        SHRINK_FIRST=true; shift ;;
        --snapshot)      CREATE_SNAPSHOT=true; shift ;;
        --rollback-on-failure) ROLLBACK_ON_FAILURE=true; shift ;;
        --destroy-source) DESTROY_SOURCE=true; shift ;;
        --resume)        RESUME_MODE=true;  shift ;;
        --batch)         BATCH_FILE="$2";  shift 2 ;;
        --range)         RANGE_SPEC="$2";  shift 2 ;;
        --save-profile)  SAVE_PROFILE_NAME="$2"; shift 2 ;;
        --profile)       PROFILE_NAME="$2"; shift 2 ;;
        --wizard)        WIZARD_MODE=true;  shift ;;
        --parallel)      PARALLEL_JOBS="$2"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=true; shift ;;
        --export-to)     EXPORT_DEST="$2"; shift 2 ;;
        --as-template)   AS_TEMPLATE=true;  shift ;;
        --sysprep)       SYSPREP=true;      shift ;;
        --api-host)      API_HOST="$2";     shift 2 ;;
        --api-token)     API_TOKEN="$2";    shift 2 ;;
        --api-user)      API_USER="$2";     shift 2 ;;
        --migrate-to-local) MIGRATE_TO_LOCAL=true; shift ;;
        --predict-size)  PREDICT_SIZE=true; shift ;;
        --list-profiles) list_profiles ;;
        -h|--help)       usage ;;
        -V|--version)    echo "v${VERSION}"; exit 0 ;;
        *)               die "Unknown option: $1 (use --help)" ;;
    esac
done

# ==============================================================================
# 1.5. PROFILE & BATCH MODE HANDLING
# ==============================================================================

# Handle profile loading first (before single conversion logic)
if [[ -n "$PROFILE_NAME" ]]; then
    load_profile "$PROFILE_NAME"
fi

# Handle validate-only mode first
if $VALIDATE_ONLY; then
    if [[ -n "$CTID" ]]; then
        run_preflight_validation "$CTID"
        exit $?
    else
        die "Container ID required for validation. Use -c <ID> or --validate-only with a CTID."
    fi
fi

# Handle wizard mode
if $WIZARD_MODE; then
    run_wizard
fi

# Handle parallel batch processing
if [[ -n "$BATCH_FILE" ]] && [[ "$PARALLEL_JOBS" -gt 1 ]]; then
    process_batch_parallel "$BATCH_FILE" "$PARALLEL_JOBS"
    exit 0
fi

# Handle range mode
if [[ -n "$RANGE_SPEC" ]]; then
    process_range "$RANGE_SPEC"
fi

# Handle profile saving (after CLI args are parsed)
if [[ -n "$SAVE_PROFILE_NAME" ]]; then
    # Save current settings as profile
    save_profile "$SAVE_PROFILE_NAME"
    # If no CTID/VMID specified, exit after saving
    if [[ -z "$CTID" || -z "$VMID" ]]; then
        exit 0
    fi
fi

# Handle resume mode check
if $RESUME_MODE; then
    if [[ -z "$CTID" || -z "$VMID" ]]; then
        die "Resume mode requires --ctid and --vmid to identify the partial conversion."
    fi
    if ! check_resume_state "$CTID" "$VMID"; then
        die "No resume state found for CT $CTID → VM $VMID. Cannot resume."
    fi
fi

# ==============================================================================
# TUI / WIZARD MODE FUNCTIONS
# ==============================================================================

WIZARD_LOG="/var/log/lxc-to-vm-wizard.log"

# Progress bar function
show_progress() {
    local current="$1"
    local total="$2"
    local label="${3:-Progress}"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r${BLUE}[*]${NC} %s [" "$label"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percentage"

    [[ "$current" -eq "$total" ]] && printf "\n"
}

# Spinner for indeterminate operations
spinner() {
    local pid="$1"
    local label="$2"
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r${BLUE}[*]${NC} %s %c" "$label" "${spinstr:$i:1}"
            sleep 0.1
        done
    done
    printf "\r${GREEN}[✓]${NC} %s\n" "$label"
}

# Run wizard mode
run_wizard() {
    echo ""
    e "${BOLD}==========================================${NC}"
    e "${BOLD}   LXC TO VM CONVERTER - WIZARD MODE${NC}"
    e "${BOLD}==========================================${NC}"
    echo ""

    # Source CTID
    [[ -z "$CTID" ]] && read -rp "Enter Source Container ID (e.g., 100): " CTID

    # Target VMID
    if [[ -z "$VMID" ]]; then
        local suggested_vmid=$((CTID + 100))
        read -rp "Enter Target VM ID [${suggested_vmid}]: " VMID
        [[ -z "$VMID" ]] && VMID="$suggested_vmid"
    fi

    # Storage
    if [[ -z "$STORAGE" ]]; then
        echo ""
        e "${BOLD}Available storage:${NC}"
        pvesm status | awk 'NR>1{print "  - " $1 " (" $2 ")"}'
        echo ""
        read -rp "Enter Target Storage Name (e.g., local-lvm): " STORAGE
    fi

    # Shrink option
    if ! $SHRINK_FIRST; then
        echo ""
        read -rp "Shrink container disk before conversion? [Y/n]: " shrink_choice
        [[ -z "$shrink_choice" || "$shrink_choice" =~ ^[Yy] ]] && SHRINK_FIRST=true
    fi

    # Disk size (only if not shrinking)
    if ! $SHRINK_FIRST && [[ -z "$DISK_SIZE" ]]; then
        read -rp "Enter VM Disk Size in GB (e.g., 32): " DISK_SIZE
    fi

    # Additional options
    echo ""
    e "${BOLD}Additional Options:${NC}"
    read -rp "Use UEFI boot? [y/N]: " uefi_choice
    [[ "$uefi_choice" =~ ^[Yy] ]] && BIOS_TYPE="ovmf"

    read -rp "Keep original network configuration? [y/N]: " net_choice
    [[ "$net_choice" =~ ^[Yy] ]] && KEEP_NETWORK=true

    read -rp "Create snapshot for rollback safety? [Y/n]: " snap_choice
    [[ -z "$snap_choice" || "$snap_choice" =~ ^[Yy] ]] && CREATE_SNAPSHOT=true

    if $CREATE_SNAPSHOT; then
        read -rp "Auto-rollback on failure? [Y/n]: " rollback_choice
        [[ -z "$rollback_choice" || "$rollback_choice" =~ ^[Yy] ]] && ROLLBACK_ON_FAILURE=true
    fi

    read -rp "Auto-start VM after conversion? [Y/n]: " start_choice
    [[ -z "$start_choice" || "$start_choice" =~ ^[Yy] ]] && AUTO_START=true

    if $AUTO_START; then
        read -rp "Destroy source container after successful verification? [y/N]: " destroy_choice
        [[ "$destroy_choice" =~ ^[Yy] ]] && DESTROY_SOURCE=true
    fi

    # Summary
    echo ""
    e "${BOLD}========================================${NC}"
    e "${BOLD}Conversion Summary:${NC}"
    e "  Source CT:    ${GREEN}$CTID${NC}"
    e "  Target VM:    ${GREEN}$VMID${NC}"
    e "  Storage:      ${GREEN}$STORAGE${NC}"
    e "  Shrink:       ${GREEN}$SHRINK_FIRST${NC}"
    [[ -n "$DISK_SIZE" ]] && e "  Disk Size:    ${GREEN}${DISK_SIZE}GB${NC}"
    e "  UEFI:         ${GREEN}$([[ "$BIOS_TYPE" == "ovmf" ]] && echo 'Yes' || echo 'No')${NC}"
    e "  Keep Network: ${GREEN}$KEEP_NETWORK${NC}"
    e "  Snapshot:     ${GREEN}$CREATE_SNAPSHOT${NC}"
    e "  Auto-start:   ${GREEN}$AUTO_START${NC}"
    e "  Destroy Src:  ${GREEN}$DESTROY_SOURCE${NC}"
    e "${BOLD}========================================${NC}"
    echo ""
    read -rp "Proceed with conversion? [Y/n]: " confirm
    [[ -n "$confirm" && ! "$confirm" =~ ^[Yy] ]] && die "Conversion cancelled by user"
}

# ==============================================================================
# PRE-FLIGHT VALIDATION
# ==============================================================================

run_preflight_validation() {
    local check_ctid="${1:-$CTID}"
    [[ -z "$check_ctid" ]] && die "Container ID required for validation"

    e "${BOLD}==========================================${NC}"
    e "${BOLD}   PRE-FLIGHT VALIDATION${NC}"
    e "${BOLD}==========================================${NC}"
    echo ""

    local checks_passed=0
    local checks_total=0

    check_pass() {
        e "  ${GREEN}[✓]${NC} $1"
        ((checks_passed++))
        ((checks_total++))
    }

    check_fail() {
        e "  ${RED}[✗]${NC} $1"
        ((checks_total++))
    }

    check_warn() {
        e "  ${YELLOW}[!]${NC} $1"
        ((checks_total++))
    }

    # Check 1: Container exists
    if pct config "$check_ctid" >/dev/null 2>&1; then
        check_pass "Container $check_ctid exists"
    else
        check_fail "Container $check_ctid does not exist"
        echo ""
        e "${RED}Validation failed. Cannot proceed.${NC}"
        return 1
    fi

    # Check 2: Container is stopped
    local status=$(pct status "$check_ctid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" == "stopped" ]]; then
        check_pass "Container is stopped (optimal for consistent copy)"
    else
        check_warn "Container is running (will be stopped during conversion)"
    fi

    # Check 3: Detect distro
    pct mount "$check_ctid" >/dev/null 2>&1
    local rootfs_path="/var/lib/lxc/${check_ctid}/rootfs"
    local detected_distro="unknown"
    if [[ -f "$rootfs_path/etc/os-release" ]]; then
        detected_distro=$(. "$rootfs_path/etc/os-release" && echo "${ID:-unknown}")
    fi
    pct unmount "$check_ctid" 2>/dev/null || true

    case "$detected_distro" in
        debian|ubuntu|linuxmint|pop|kali|proxmox|alpine|centos|rhel|rocky|alma|fedora|ol|arch|manjaro|endeavouros)
            check_pass "Supported distro detected: $detected_distro"
            ;;
        unknown)
            check_fail "Could not detect distro (no /etc/os-release)"
            ;;
        *)
            check_warn "Distro '$detected_distro' not in tested list (may still work)"
            ;;
    esac

    # Check 4: Root filesystem type
    local rootfs_line=$(pct config "$check_ctid" | grep "^rootfs:")
    if echo "$rootfs_line" | grep -q "size="; then
        check_pass "Root filesystem configured with size"
    else
        check_warn "Root filesystem may be subvolume-based"
    fi

    # Check 5: Network configuration
    if pct config "$check_ctid" | grep -q "net0:"; then
        check_pass "Network interface configured"
    else
        check_warn "No network interface detected"
    fi

    # Check 6: Storage availability
    local storage_list=$(pvesm status 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ', ')
    if [[ -n "$storage_list" ]]; then
        check_pass "Storage available: ${storage_list%, }"
    else
        check_fail "No storage detected"
    fi

    # Check 7: Disk space estimation
    if [[ -d "$rootfs_path" ]]; then
        local used_bytes=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
            --exclude='tmp/*' --exclude='run/*' \
            --exclude='mnt/*' --exclude='media/*' --exclude='lost+found' \
            "${rootfs_path}/" 2>/dev/null | awk '{print $1}')
        local used_gb=$((used_bytes / 1024 / 1024 / 1024))
        check_pass "Container uses approximately ${used_gb}GB"
    fi

    # Check 8: Dependencies
    local missing_deps=""
    for cmd in parted kpartx rsync qemu-img; do
        command -v "$cmd" >/dev/null 2>&1 || missing_deps+="$cmd "
    done
    if [[ -z "$missing_deps" ]]; then
        check_pass "All required dependencies available"
    else
        check_warn "Missing dependencies (will auto-install): $missing_deps"
    fi

    echo ""
    e "${BOLD}========================================${NC}"
    e "Validation: ${checks_passed}/${checks_total} checks passed"
    e "${BOLD}========================================${NC}"
    echo ""

    if [[ "$checks_passed" -eq "$checks_total" ]]; then
        e "${GREEN}Container $check_ctid is ready for conversion!${NC}"
        return 0
    else
        e "${YELLOW}Container $check_ctid has some issues. Review warnings above.${NC}"
        return 1
    fi
}

# ==============================================================================
# PARALLEL BATCH PROCESSING
# ==============================================================================

process_batch_parallel() {
    local batch_file="$1"
    local max_jobs="${2:-1}"
    [[ -f "$batch_file" ]] || die "Batch file not found: $batch_file"

    log "Processing batch file in parallel (max $max_jobs jobs): $batch_file"

    # Read all lines into array
    local -a jobs=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        jobs+=("$line")
    done < "$batch_file"

    local total=${#jobs[@]}
    local running=0
    local completed=0
    local success_count=0
    local fail_count=0

    log "Total conversions to process: $total"

    for job in "${jobs[@]}"; do
        local batch_ctid=$(echo "$job" | awk '{print $1}')
        local batch_vmid=$(echo "$job" | awk '{print $2}')

        # Wait if max jobs running
        while [[ $running -ge $max_jobs ]]; do
            sleep 1
            running=$(jobs -r | wc -l)
        done

        # Run conversion in background
        (
            log "Starting background conversion: CT $batch_ctid → VM $batch_vmid"
            if run_single_conversion "$batch_ctid" "$batch_vmid" >> "$LOG_FILE" 2>&1; then
                echo "SUCCESS:$batch_ctid:$batch_vmid"
            else
                echo "FAILED:$batch_ctid:$batch_vmid"
            fi
        ) &

        ((running++))
        ((completed++))
        log "Progress: $completed/$total started ($running running)"
    done

    # Wait for all jobs
    wait

    echo ""
    e "${GREEN}${BOLD}==========================================${NC}"
    e "${GREEN}${BOLD}         BATCH CONVERSION COMPLETE${NC}"
    e "${GREEN}${BOLD}==========================================${NC}"
    e "  ${BOLD}Total:${NC}      $total"
    echo ""
}

# ==============================================================================
# CLOUD/STORAGE EXPORT
# ==============================================================================

export_vm_disk() {
    local vmid="$1"
    local dest="$2"
    [[ -z "$dest" ]] && return 0

    log "Exporting VM $vmid disk to: $dest"

    # Get disk path from VM config
    local disk_ref=$(qm config "$vmid" | awk -F': ' '/^scsi0:/{print $2}')
    [[ -z "$disk_ref" ]] && { warn "Could not find disk for VM $vmid"; return 1; }

    # Resolve full path
    local disk_path=$(pvesm path "$disk_ref" 2>/dev/null)
    [[ -z "$disk_path" || ! -f "$disk_path" ]] && { warn "Disk not found: $disk_ref"; return 1; }

    case "$dest" in
        s3://*)
            ensure_dependency aws
            local bucket=$(echo "$dest" | sed 's|s3://||')
            log "Uploading to S3 bucket: $bucket"
            aws s3 cp "$disk_path" "$dest/" --no-progress >> "$LOG_FILE" 2>&1 && ok "S3 upload complete" || warn "S3 upload failed"
            ;;
        nfs://*)
            local nfs_path=$(echo "$dest" | sed 's|nfs://||')
            local nfs_host=$(echo "$nfs_path" | cut -d'/' -f1)
            local nfs_export=$(echo "$nfs_path" | cut -d'/' -f2-)
            log "Copying to NFS: $nfs_host:/$nfs_export"
            cp "$disk_path" "/mnt/nfs-$nfs_host/$nfs_export/" 2>/dev/null && ok "NFS copy complete" || warn "NFS copy failed"
            ;;
        ssh://*)
            local ssh_dest=$(echo "$dest" | sed 's|ssh://||')
            log "Copying via SSH to: $ssh_dest"
            scp "$disk_path" "$ssh_dest/" >> "$LOG_FILE" 2>&1 && ok "SSH copy complete" || warn "SSH copy failed"
            ;;
        *)
            warn "Unknown export destination format: $dest"
            return 1
            ;;
    esac
}

# ==============================================================================
# VM TEMPLATE CREATION
# ==============================================================================

convert_to_template() {
    local vmid="$1"
    log "Converting VM $vmid to template..."

    # Stop VM first if running
    qm stop "$vmid" 2>/dev/null || true
    sleep 2

    # Run sysprep if requested
    if $SYSPREP; then
        log "Running sysprep cleanup..."
        run_sysprep "$vmid"
    fi

    # Convert to template
    qm template "$vmid" >> "$LOG_FILE" 2>&1 && ok "VM $vmid converted to template" || warn "Template conversion failed"
}

run_sysprep() {
    local vmid="$1"
    log "Cleaning VM $vmid for cloning (sysprep)..."

    # Get disk and mount it
    local disk_ref=$(qm config "$vmid" | awk -F': ' '/^scsi0:/{print $2}')
    local disk_path=$(pvesm path "$disk_ref" 2>/dev/null)
    [[ -z "$disk_path" ]] && { warn "Could not find disk for sysprep"; return 1; }

    local sysprep_dir="/tmp/sysprep-${vmid}"
    mkdir -p "$sysprep_dir"

    # Mount via loopback
    local loop_dev=$(losetup --show -f "$disk_path")
    kpartx -a "$loop_dev" 2>/dev/null || true
    local part_dev="/dev/mapper/$(basename "$loop_dev")p1"
    [[ ! -b "$part_dev" ]] && part_dev="/dev/mapper/$(basename "$loop_dev")p2"

    if [[ -b "$part_dev" ]]; then
        mount "$part_dev" "$sysprep_dir"

        # Clean SSH host keys
        log "Removing SSH host keys..."
        rm -f "$sysprep_dir/etc/ssh/ssh_host_*"

        # Clean machine ID
        log "Cleaning machine-id..."
        echo "" > "$sysprep_dir/etc/machine-id" 2>/dev/null || true

        # Clean network config (keep interface name)
        log "Cleaning persistent network rules..."
        rm -f "$sysprep_dir/etc/udev/rules.d/70-persistent-net.rules"

        # Clean logs
        log "Cleaning logs..."
        find "$sysprep_dir/var/log" -type f -exec truncate -s 0 {} \; 2>/dev/null || true

        # Clean temp files
        rm -rf "$sysprep_dir/tmp/*" "$sysprep_dir/var/tmp/*" 2>/dev/null || true

        umount "$sysprep_dir"
        ok "Sysprep complete for VM $vmid"
    else
        warn "Could not mount disk for sysprep"
    fi

    # Cleanup
    kpartx -d "$loop_dev" 2>/dev/null || true
    losetup -d "$loop_dev" 2>/dev/null || true
    rm -rf "$sysprep_dir"
}

# ==============================================================================
# 2. SETUP & CHECKS
# ==============================================================================

e "${BOLD}==========================================${NC}"
e "${BOLD}   PROXMOX LXC TO VM CONVERTER v${VERSION}${NC}"
e "${BOLD}==========================================${NC}"

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
            --exclude='tmp/*' --exclude='run/*' --exclude='mnt/*' \
            --exclude='media/*' --exclude='lost+found' \
            "${SHRINK_ROOT}/" 2>/dev/null | awk '{print $1}')
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
    e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"
    echo ""
    e "  ${BOLD}Source CT:${NC}    $CTID (status: ${CT_STATUS:-unknown})"
    e "  ${BOLD}Target VM:${NC}   $VMID"
    e "  ${BOLD}Storage:${NC}     $STORAGE"
    e "  ${BOLD}Disk:${NC}        ${DISK_SIZE}GB ($DISK_FORMAT)"
    e "  ${BOLD}Firmware:${NC}    $BIOS_TYPE"
    e "  ${BOLD}Bridge:${NC}      $BRIDGE"
    e "  ${BOLD}Keep net:${NC}    $KEEP_NETWORK"
    e "  ${BOLD}Auto-start:${NC}  $AUTO_START"
    e "  ${BOLD}Snapshot:${NC}    $CREATE_SNAPSHOT"
    e "  ${BOLD}Rollback:${NC}    $ROLLBACK_ON_FAILURE"
    e "  ${BOLD}Destroy source:${NC} $DESTROY_SOURCE"
    e "  ${BOLD}Resume mode:${NC} $RESUME_MODE"
    echo ""
    # Show LXC config
    LXC_MEM=$(pct config "$CTID" | awk '/^memory:/{print $2}')
    LXC_CORES=$(pct config "$CTID" | awk '/^cores:/{print $2}')
    e "  ${BOLD}LXC Memory:${NC}  ${LXC_MEM:-2048}MB"
    e "  ${BOLD}LXC Cores:${NC}   ${LXC_CORES:-2}"
    echo ""
    # Space check
    DEFAULT_WORK_BASE="/var/lib/vz/dump"
    WORK_CHECK="${WORK_DIR:-$DEFAULT_WORK_BASE}"
    REQUIRED_MB=$(( (DISK_SIZE + 1) * 1024 ))
    AVAIL_MB=$(df -BM --output=avail "$WORK_CHECK" 2>/dev/null | tail -1 | tr -d ' M')
    if [[ "${AVAIL_MB:-0}" -ge "$REQUIRED_MB" ]]; then
        e "  ${GREEN}[✓]${NC} Disk space OK: ${AVAIL_MB}MB available (need ${REQUIRED_MB}MB) in $WORK_CHECK"
    else
        e "  ${RED}[✗]${NC} Insufficient space: ${AVAIL_MB:-0}MB available (need ${REQUIRED_MB}MB) in $WORK_CHECK"
    fi
    echo ""
    e "  ${BOLD}Shrink:${NC}      $SHRINK_FIRST"
    e "  ${BOLD}Snapshot:${NC}     $CREATE_SNAPSHOT"
    e "  ${BOLD}Rollback:${NC}      $ROLLBACK_ON_FAILURE"
    e "  ${BOLD}Destroy source:${NC}  $DESTROY_SOURCE"
    echo ""
    e "  ${BOLD}Steps that would be performed:${NC}"
    if $CREATE_SNAPSHOT; then
        echo "    -0. Create snapshot 'pre-conversion' for rollback safety"
    fi
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
    if $DESTROY_SOURCE; then
        echo "    8. Destroy original LXC container $CTID"
    fi
    echo ""
    ok "Dry run complete. Remove --dry-run to execute."
    exit 0
fi

# --- Disk Space Check ---
# We need at least DISK_SIZE GB for the raw image, plus ~1GB headroom for chroot packages.
REQUIRED_MB=$(( (DISK_SIZE + 1) * 1024 ))
DEFAULT_WORK_BASE="/var/lib/vz/dump"

# -----------------------------------------------------------------------------
# Disk Space Check Function
# Arguments:
#   $1 - Directory to check
# Returns: Available space in MB via echo
# -----------------------------------------------------------------------------
check_space() {
    local dir="$1"
    local avail_mb
    avail_mb=$(df -BM --output=avail "$dir" 2>/dev/null | tail -1 | tr -d ' M')
    echo "${avail_mb:-0}"
}

# ==============================================================================
# MAIN CONVERSION FUNCTION
# ==============================================================================

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
    e "  ${YELLOW}Note:${NC} The script needs filesystem space for a temporary ${DISK_SIZE}GB raw image." >&2
    e "  ${YELLOW}      ${NC} LVM/ZFS storage (e.g. local-lvm) cannot be used directly as a working directory." >&2
    e "  ${YELLOW}      ${NC} The temp image is imported to your target storage after creation." >&2

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
    e "${BOLD}Available mount points with sufficient space (>${REQUIRED_MB}MB):${NC}" >&2
    for i in "${!candidates_mp[@]}"; do
        e "  ${GREEN}[$((i+1))]${NC} ${BOLD}${candidates_mp[$i]}${NC}  — ${candidates_avail[$i]}MB free" >&2
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

do_conversion() {

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
    for ((i=1; i<=10; i++)); do
        [[ -b "$LOOP_MAP" && -b "$EFI_PART" ]] && break
        sleep 0.5
    done
    [[ -b "$EFI_PART" ]]  || die "EFI partition device $EFI_PART did not appear."
    [[ -b "$LOOP_MAP" ]]  || die "Root partition device $LOOP_MAP did not appear."

    log "Formatting EFI partition ($EFI_PART)..."
    mkfs.fat -F32 "$EFI_PART" >> "$LOG_FILE" 2>&1

    log "Formatting root partition ($LOOP_MAP)..."
    # Disable metadata_csum (FEATURE_C12) at creation time to ensure initramfs compatibility
    mkfs.ext4 -F -O ^metadata_csum "$LOOP_MAP" >> "$LOG_FILE" 2>&1

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

    for ((i=1; i<=10; i++)); do
        [[ -b "$LOOP_MAP" ]] && break
        sleep 0.5
    done
    [[ -b "$LOOP_MAP" ]] || die "Partition device $LOOP_MAP did not appear."

    log "Formatting partition ($LOOP_MAP)..."
    # Disable metadata_csum (FEATURE_C12) at creation time to ensure initramfs compatibility
    mkfs.ext4 -F -O ^metadata_csum "$LOOP_MAP" >> "$LOG_FILE" 2>&1

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

# Detect unprivileged LXC ID mapping so ownership can be normalized in VM.
# Without this, files copied from an unprivileged CT can retain shifted host
# IDs (e.g. 100000:100000), which breaks systemd and core boot services.
NEED_UID_GID_NORMALIZATION=false
CT_CONFIG_RAW="$(pct config "$CTID" 2>/dev/null || true)"
if echo "$CT_CONFIG_RAW" | grep -qE '^unprivileged:\s*1'; then
    UID_SHIFT_BASE="$(echo "$CT_CONFIG_RAW" | awk '$1=="lxc.idmap:" && $2=="u" && $3=="0" {print $4; exit}')"
    UID_SHIFT_COUNT="$(echo "$CT_CONFIG_RAW" | awk '$1=="lxc.idmap:" && $2=="u" && $3=="0" {print $5; exit}')"
    GID_SHIFT_BASE="$(echo "$CT_CONFIG_RAW" | awk '$1=="lxc.idmap:" && $2=="g" && $3=="0" {print $4; exit}')"
    GID_SHIFT_COUNT="$(echo "$CT_CONFIG_RAW" | awk '$1=="lxc.idmap:" && $2=="g" && $3=="0" {print $5; exit}')"

    [[ "$UID_SHIFT_BASE" =~ ^[0-9]+$ ]] || UID_SHIFT_BASE=100000
    [[ "$UID_SHIFT_COUNT" =~ ^[0-9]+$ ]] || UID_SHIFT_COUNT=65536
    [[ "$GID_SHIFT_BASE" =~ ^[0-9]+$ ]] || GID_SHIFT_BASE="$UID_SHIFT_BASE"
    [[ "$GID_SHIFT_COUNT" =~ ^[0-9]+$ ]] || GID_SHIFT_COUNT="$UID_SHIFT_COUNT"

    NEED_UID_GID_NORMALIZATION=true
    log "Detected unprivileged CT with ID mapping u:0->${UID_SHIFT_BASE} (${UID_SHIFT_COUNT}), g:0->${GID_SHIFT_BASE} (${GID_SHIFT_COUNT}); will normalize ownership after copy."
fi

rsync -axHAX --info=progress2 --no-inc-recursive \
    --partial --partial-dir="${TEMP_DIR}/.rsync-partial" \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/tmp/*' \
    --exclude='/run/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/lost+found' \
    "${LXC_ROOT_MOUNT}/" "${MOUNT_POINT}/" || {
    # If rsync fails, save resume state
    save_resume_state "$CTID" "$VMID" "rsync-failed" "partial_dir=${TEMP_DIR}/.rsync-partial"
    die "Rsync failed. Resume with: $0 -c $CTID -v $VMID --resume"
}

if $NEED_UID_GID_NORMALIZATION; then
    command -v python3 >/dev/null 2>&1 || die "python3 is required to normalize unprivileged CT ownership mappings."
    log "Normalizing shifted UID/GID ownership in copied filesystem..."
    python3 - "$MOUNT_POINT" "$UID_SHIFT_BASE" "$UID_SHIFT_COUNT" "$GID_SHIFT_BASE" "$GID_SHIFT_COUNT" >> "$LOG_FILE" 2>&1 <<'PY'
import os
import sys

root = sys.argv[1]
uid_base = int(sys.argv[2])
uid_count = int(sys.argv[3])
gid_base = int(sys.argv[4])
gid_count = int(sys.argv[5])

uid_end = uid_base + uid_count
gid_end = gid_base + gid_count

changed = 0
errors = 0

def remap(value, base, end):
    if base <= value < end:
        return value - base
    return value

def process_path(path):
    global changed, errors
    try:
        st = os.lstat(path)
        new_uid = remap(st.st_uid, uid_base, uid_end)
        new_gid = remap(st.st_gid, gid_base, gid_end)
        if new_uid != st.st_uid or new_gid != st.st_gid:
            os.lchown(path, new_uid, new_gid)
            changed += 1
    except Exception as exc:
        errors += 1
        if errors <= 20:
            print(f"ownership remap warning: {path}: {exc}")

process_path(root)
for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    for name in dirnames:
        process_path(os.path.join(dirpath, name))
    for name in filenames:
        process_path(os.path.join(dirpath, name))

print(f"ownership remap changed={changed} errors={errors}")
if errors > 0:
    sys.exit(1)
PY
    ok "Ownership normalization complete."
fi

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
    # Parse os-release without sourcing it. Sourcing can fail when this script's
    # readonly VERSION constant conflicts with VERSION=... inside os-release.
    DISTRO_ID="$(awk -F= '$1=="ID"{print $2; exit}' "$MOUNT_POINT/etc/os-release" 2>/dev/null || true)"
    DISTRO_ID="${DISTRO_ID//\"/}"
    DISTRO_ID="${DISTRO_ID//\'/}"
    DISTRO_ID="${DISTRO_ID,,}"
    [[ -n "$DISTRO_ID" ]] || DISTRO_ID="unknown"
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
echo "UUID=${NEW_UUID} / ext4 defaults,errors=remount-ro 0 1" > /etc/fstab
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

# Remove stale one-shot flags that can force repeated recovery/failsafe behavior
# after container-to-VM migration.
cat >> "$CHROOT_SCRIPT" <<'FSCK_MARKERS_BLOCK'
# --- Clear stale fsck/relabel markers ---
rm -f /forcefsck /.autorelabel
FSCK_MARKERS_BLOCK

# Normalize man-db cache path to avoid post-conversion apt trigger failures
# (seen as fopen/permission errors under /var/cache/man).
cat >> "$CHROOT_SCRIPT" <<'MAN_CACHE_BLOCK'
# --- Normalize man cache permissions ---
mkdir -p /var/cache/man
if command -v chattr >/dev/null 2>&1; then
    chattr -R -i /var/cache/man 2>/dev/null || true
fi
chown root:root /var/cache/man 2>/dev/null || true
chmod 0755 /var/cache/man 2>/dev/null || true
MAN_CACHE_BLOCK

# Ensure common API filesystem mountpoints exist on first VM boot.
# These are often absent in container rootfs snapshots and can cause
# systemd mount units (dev-mqueue, dev-hugepages, etc.) to fail noisily.
cat >> "$CHROOT_SCRIPT" <<'API_MOUNTPOINTS_BLOCK'
# --- API filesystem mountpoints ---
mkdir -p /dev/pts /dev/shm /dev/hugepages /dev/mqueue
mkdir -p /proc/sys/fs/binfmt_misc
mkdir -p /sys/fs/fuse/connections /sys/kernel/config /sys/kernel/debug /sys/kernel/tracing
API_MOUNTPOINTS_BLOCK

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
apt-get install -y linux-image-generic systemd-sysv grub-efi-amd64 udev dbus qemu-guest-agent e2fsprogs 2>/dev/null \
    || apt-get install -y linux-image-amd64 systemd-sysv grub-efi-amd64 udev dbus qemu-guest-agent e2fsprogs
grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck --no-nvram --force --removable
# Force rw root remount on boot. Some converted guests can otherwise remain on
# kernel cmdline default 'ro' if remount service runs in a constrained context.
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="rw quiet"/' /etc/default/grub
else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="rw quiet"' >> /etc/default/grub
fi
update-grub
# Regenerate initramfs with full e2fsprogs to support modern ext4 features (metadata_csum)
# instead of busybox e2fsck which fails on FEATURE_C12
echo "e2fsprogs" >> /etc/initramfs-tools/modules 2>/dev/null || true
update-initramfs -u -k all || update-initramfs -u
systemctl enable getty@tty1.service serial-getty@ttyS0.service systemd-logind.service dbus.service qemu-guest-agent.service 2>/dev/null || true
DEBIAN_EFI
        else
            cat >> "$CHROOT_SCRIPT" <<DEBIAN_BIOS
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic systemd-sysv grub-pc udev dbus qemu-guest-agent e2fsprogs 2>/dev/null \
    || apt-get install -y linux-image-amd64 systemd-sysv grub-pc udev dbus qemu-guest-agent e2fsprogs
rm -f /tmp/lxc-to-vm-grub-bios-fallback.flag
GRUB_INSTALL_OK=0
if grub-install --target=i386-pc --recheck --force --skip-fs-probe "${LOOP_DEV}"; then
    GRUB_INSTALL_OK=1
elif grub-install --target=i386-pc --boot-directory=/boot --force --skip-fs-probe "${LOOP_DEV}"; then
    GRUB_INSTALL_OK=1
fi
if [ "\$GRUB_INSTALL_OK" -ne 1 ]; then
    echo "chroot-bios-grub-install-failed" > /tmp/lxc-to-vm-grub-bios-fallback.flag
fi
# Force rw root remount on boot. Some converted guests can otherwise remain on
# kernel cmdline default 'ro' if remount service runs in a constrained context.
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="rw quiet"/' /etc/default/grub
else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="rw quiet"' >> /etc/default/grub
fi
update-grub
# Regenerate initramfs with full e2fsprogs to support modern ext4 features (metadata_csum)
# instead of busybox e2fsck which fails on FEATURE_C12
echo "e2fsprogs" >> /etc/initramfs-tools/modules 2>/dev/null || true
update-initramfs -u -k all || update-initramfs -u
systemctl enable getty@tty1.service serial-getty@ttyS0.service systemd-logind.service dbus.service qemu-guest-agent.service 2>/dev/null || true
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

# Some Ubuntu/Debian BIOS images on loop-backed ext4 can fail grub-install inside
# chroot with "unknown filesystem" despite successful package install. If marked,
# run a host-side grub-install fallback against the same loop device + boot dir.
if [[ "$DISTRO_FAMILY" == "debian" && "$BIOS_TYPE" == "seabios" && -f "$MOUNT_POINT/tmp/lxc-to-vm-grub-bios-fallback.flag" ]]; then
    warn "Chroot BIOS grub-install failed; attempting host-side grub-install fallback..."
    command -v grub-install >/dev/null 2>&1 || die "Host grub-install is required for BIOS fallback but is not available."
    grub-install --target=i386-pc --boot-directory="$MOUNT_POINT/boot" --recheck --force --skip-fs-probe "$LOOP_DEV" >> "$LOG_FILE" 2>&1 \
        || die "Host-side BIOS grub-install fallback failed. Review $LOG_FILE for details."
    chroot "$MOUNT_POINT" /bin/bash -lc 'update-grub || grub-mkconfig -o /boot/grub/grub.cfg' >> "$LOG_FILE" 2>&1 \
        || die "Host-side BIOS fallback succeeded but failed to generate grub.cfg. Review $LOG_FILE for details."
    ok "Host-side BIOS grub-install fallback succeeded."
fi
rm -f "$MOUNT_POINT/tmp/lxc-to-vm-grub-bios-fallback.flag"
rm -f "$MOUNT_POINT/tmp/chroot-setup.sh"

# Host-side boot artifact checks before import. This catches guests that would
# otherwise appear converted but hang at BIOS/boot stage.
if ! compgen -G "$MOUNT_POINT/boot/vmlinuz*" >/dev/null; then
    die "No kernel image found in $MOUNT_POINT/boot after chroot install. Conversion aborted."
fi
if ! compgen -G "$MOUNT_POINT/boot/grub/grub.cfg" >/dev/null && ! compgen -G "$MOUNT_POINT/boot/grub2/grub.cfg" >/dev/null; then
    die "No GRUB configuration found in converted image. Conversion aborted."
fi

log "Verifying converted root filesystem is writable before import..."
touch "$MOUNT_POINT/.lxc-to-vm-rw-test" 2>>"$LOG_FILE" \
    || die "Converted root filesystem is not writable at $MOUNT_POINT. Check source filesystem health and retry."
rm -f "$MOUNT_POINT/.lxc-to-vm-rw-test"

# ==============================================================================
# 6. VM CREATION
# ==============================================================================

# Pull settings from the source LXC config (before unmount)
MEMORY=$(pct config "$CTID" | awk '/^memory:/{print $2}')
[[ -z "$MEMORY" || "$MEMORY" -lt 512 ]] && MEMORY=2048
CORES=$(pct config "$CTID" | awk '/^cores:/{print $2}')
[[ -z "$CORES" || "$CORES" -lt 1 ]] && CORES=2
CT_HOSTNAME=$(echo "${CT_CONFIG_RAW:-}" | awk '/^hostname:/{print $2; exit}')
if [[ -z "$CT_HOSTNAME" ]]; then
    CT_HOSTNAME=$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/{print $2; exit}')
fi
[[ -n "$CT_HOSTNAME" ]] || CT_HOSTNAME="ct${CTID}"
VM_NAME="${CT_HOSTNAME}-converted"
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

# Disable metadata_csum FIRST (before e2fsck) to prevent FEATURE_C12 boot failures.
log "Disabling metadata_csum ext4 feature for initramfs compatibility..."
tune2fs -O ^metadata_csum "$LOOP_MAP" >> "$LOG_FILE" 2>&1 || true

# Run a final offline filesystem check before import so first VM boot does not
# start in a degraded read-only state due to journal/superblock inconsistencies.
log "Running final filesystem check on root partition..."
FSCK_RC=0
e2fsck -fy "$LOOP_MAP" >> "$LOG_FILE" 2>&1 || FSCK_RC=$?
if (( FSCK_RC >= 4 )); then
    die "Filesystem check failed on $LOOP_MAP (e2fsck exit $FSCK_RC). See $LOG_FILE for details."
fi
if (( FSCK_RC > 0 )); then
    warn "e2fsck corrected filesystem issues on $LOOP_MAP (exit $FSCK_RC)."
fi

# Allow kernel time to release the device after unmount
sync
sleep 2

# Detach partition mapping (retry up to 5 times for large disks)
for ((attempt=1; attempt<=5; attempt++)); do
    kpartx -d "$LOOP_DEV" 2>/dev/null && break
    warn "kpartx -d attempt $attempt failed, retrying in 3s..."
    sleep 3
done

# Detach loop device (retry up to 5 times)
for ((attempt=1; attempt<=5; attempt++)); do
    losetup -d "$LOOP_DEV" 2>/dev/null && break
    warn "losetup -d attempt $attempt failed, retrying in 3s..."
    sleep 3
done
LOOP_DEV=""  # Clear so cleanup trap doesn't double-free

log "Creating VM $VMID..."
log "VM name: $VM_NAME"

# Create VM shell
qm create "$VMID" \
    --name "$VM_NAME" \
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

# Surface host-side thin-LVM warnings clearly so they are not confused with
# conversion failures. These warnings reference other LVs and should be fixed
# on the Proxmox host separately.
if echo "$IMPORT_OUTPUT" | grep -qE 'Thin volume .* maps .* while the size is only'; then
    warn "Detected host LVM-thin mapping warning(s) during import. This is a host storage issue, not a VM conversion logic error."
    THIN_WARN_LVS=$(echo "$IMPORT_OUTPUT" | awk '/Thin volume /{for(i=1;i<=NF;i++){if($i=="volume"){print $(i+1)}}}' | sort -u | tr '\n' ' ')
    [[ -n "$THIN_WARN_LVS" ]] && warn "Affected LV(s): $THIN_WARN_LVS"
    warn "Run host checks (outside this script): lvs -a -o+seg_monitor && lvdisplay -m <LV>"
fi
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
VM_HEALTH_ERRORS=0
ROOT_RW_CHECK_FAILED=false
REMOUNT_CHECK_FAILED=false

collect_vm_diagnostics() {
    log "Collecting host-side and guest-side diagnostics for VM $VMID..."
    {
        echo ""
        echo "=== VM HEALTH DIAGNOSTICS (VMID=$VMID) ==="
        echo "--- qm status ---"
        qm status "$VMID" 2>&1 || true
        echo "--- qm config ---"
        qm config "$VMID" 2>&1 || true
        echo "--- qm agent ping ---"
        qm agent "$VMID" ping 2>&1 || true
        echo "--- guest root mount options ---"
        qm guest exec "$VMID" -- /bin/sh -lc 'findmnt -no SOURCE,FSTYPE,OPTIONS /' 2>&1 || true
        echo "--- guest remount service ---"
        qm guest exec "$VMID" -- /bin/sh -lc 'systemctl status systemd-remount-fs.service --no-pager -l || true' 2>&1 || true
        echo "--- guest failed units ---"
        qm guest exec "$VMID" -- /bin/sh -lc 'systemctl --failed --no-pager || true' 2>&1 || true
        echo "--- guest kernel errors ---"
        qm guest exec "$VMID" -- /bin/sh -lc 'journalctl -k -b -p err --no-pager -n 80 || true' 2>&1 || true
        echo "=== END VM HEALTH DIAGNOSTICS ==="
        echo ""
    } >> "$LOG_FILE"
    warn "Saved detailed VM diagnostics to $LOG_FILE"
}

auto_fix_boot_rw_issue() {
    local vm_disk_volid disk_path map_output mapper_name mapper_root
    local fix_mount="/tmp/lxc-to-vm-fix-${VMID}"
    local fix_ok=false

    log "Attempting automatic remediation for VM $VMID (root read-only/remount failure)..."

    qm stop "$VMID" >/dev/null 2>&1 || true

    vm_disk_volid=$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^scsi0:/{print $2; exit}' | cut -d',' -f1)
    [[ -n "$vm_disk_volid" ]] || {
        warn "Auto-fix could not determine VM disk from scsi0."
        return 1
    }

    disk_path=$(pvesm path "$vm_disk_volid" 2>/dev/null || true)
    [[ -n "$disk_path" && -e "$disk_path" ]] || {
        warn "Auto-fix could not resolve storage path for $vm_disk_volid."
        return 1
    }

    map_output=$(kpartx -av "$disk_path" 2>&1) || {
        warn "Auto-fix failed to map partitions for $disk_path"
        echo "$map_output" >> "$LOG_FILE"
        return 1
    }
    echo "$map_output" >> "$LOG_FILE"

    mapper_name=$(echo "$map_output" | awk '/add map/{print $3; exit}')
    [[ -n "$mapper_name" ]] || {
        warn "Auto-fix could not identify mapped root partition for $disk_path"
        kpartx -dv "$disk_path" >/dev/null 2>&1 || true
        return 1
    }
    mapper_root="/dev/mapper/${mapper_name}"
    [[ -b "$mapper_root" ]] || {
        warn "Auto-fix mapped partition $mapper_root is not a block device"
        kpartx -dv "$disk_path" >/dev/null 2>&1 || true
        return 1
    }

    mkdir -p "$fix_mount"
    if mount "$mapper_root" "$fix_mount"; then
        mount --bind /dev "$fix_mount/dev" 2>/dev/null || true
        mount --bind /proc "$fix_mount/proc" 2>/dev/null || true
        mount --bind /sys "$fix_mount/sys" 2>/dev/null || true

        chroot "$fix_mount" /bin/bash -lc '
set -e
if [ -f /etc/default/grub ]; then
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
        sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rw quiet\"/" /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rw quiet\"" >> /etc/default/grub
    fi
    update-grub || true
fi
mkdir -p /tmp /var/cache/man
if command -v chattr >/dev/null 2>&1; then
    chattr -R -i /var/cache/man 2>/dev/null || true
fi
chown root:root /tmp /var/cache/man 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true
chmod 0755 /var/cache/man 2>/dev/null || true
' >> "$LOG_FILE" 2>&1 && fix_ok=true
    else
        warn "Auto-fix failed to mount root partition $mapper_root"
    fi

    umount -lf "$fix_mount/sys" 2>/dev/null || true
    umount -lf "$fix_mount/proc" 2>/dev/null || true
    umount -lf "$fix_mount/dev" 2>/dev/null || true
    umount -lf "$fix_mount" 2>/dev/null || true

    e2fsck -fy "$mapper_root" >> "$LOG_FILE" 2>&1 || true
    kpartx -dv "$disk_path" >/dev/null 2>&1 || true

    if $fix_ok; then
        qm start "$VMID" >> "$LOG_FILE" 2>&1 || {
            warn "Auto-fix updated disk but failed to start VM $VMID"
            return 1
        }
        return 0
    fi

    return 1
}

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
        VM_HEALTH_ERRORS=$((VM_HEALTH_ERRORS + 1))
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
    run_check "VM process entered running state" $([[ "$(qm status "$VMID" 2>/dev/null | awk '{print $2}')" == "running" ]] && echo 0 || echo 1) "$(qm status "$VMID" 2>/dev/null || echo 'unknown')"

    # Wait for QEMU guest agent (up to 120 seconds)
    log "Waiting for VM to boot and guest agent to respond (up to 120s)..."
    AGENT_OK=false
    for ((i=1; i<=24; i++)); do
        if qm agent "$VMID" ping >/dev/null 2>&1; then
            AGENT_OK=true
            break
        fi
        sleep 5
    done

    run_check "Guest agent responsive within timeout" $($AGENT_OK && echo 0 || echo 1) "120s"

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

        # Root mount and remount service health checks.
        ROOT_OPTS_JSON=$(qm guest exec "$VMID" -- /bin/sh -lc 'findmnt -no OPTIONS /' 2>/dev/null || true)
        ROOT_OPTS=$(echo "$ROOT_OPTS_JSON" | grep -oP '"out-data"\s*:\s*"\K[^"]+' 2>/dev/null | sed 's/\\n$//' || true)
        if [[ -n "$ROOT_OPTS" ]]; then
            run_check "Guest root mounted read-write" $([[ "$ROOT_OPTS" == *"rw"* ]] && echo 0 || echo 1) "$ROOT_OPTS"
            [[ "$ROOT_OPTS" == *"rw"* ]] || ROOT_RW_CHECK_FAILED=true
        else
            warn "Could not read guest root mount options via guest agent."
        fi

        REMOUNT_JSON=$(qm guest exec "$VMID" -- /bin/sh -lc 'systemctl is-active systemd-remount-fs.service || true' 2>/dev/null || true)
        REMOUNT_STATE=$(echo "$REMOUNT_JSON" | grep -oP '"out-data"\s*:\s*"\K[^"]+' 2>/dev/null | sed 's/\\n$//' || true)
        if [[ -n "$REMOUNT_STATE" ]]; then
            run_check "systemd-remount-fs.service active" $([[ "$REMOUNT_STATE" == "active" ]] && echo 0 || echo 1) "$REMOUNT_STATE"
            [[ "$REMOUNT_STATE" == "active" ]] || REMOUNT_CHECK_FAILED=true
        fi
    else
        warn "Guest agent did not respond within 120s. VM may still be booting."
        warn "Check manually: qm terminal $VMID -iface serial0"
    fi

    if (( VM_HEALTH_ERRORS > 0 )) && { $ROOT_RW_CHECK_FAILED || $REMOUNT_CHECK_FAILED; }; then
        warn "Detected root remount/readonly issue. Triggering automatic remediation..."
        if $AUTO_FIX && auto_fix_boot_rw_issue; then
            # Re-check after remediation
            AGENT_OK=false
            for ((i=1; i<=18; i++)); do
                if qm agent "$VMID" ping >/dev/null 2>&1; then
                    AGENT_OK=true
                    break
                fi
                sleep 5
            done

            if $AGENT_OK; then
                ROOT_OPTS_JSON=$(qm guest exec "$VMID" -- /bin/sh -lc 'findmnt -no OPTIONS /' 2>/dev/null || true)
                ROOT_OPTS=$(echo "$ROOT_OPTS_JSON" | grep -oP '"out-data"\s*:\s*"\K[^"]+' 2>/dev/null | sed 's/\\n$//' || true)
                REMOUNT_JSON=$(qm guest exec "$VMID" -- /bin/sh -lc 'systemctl is-active systemd-remount-fs.service || true' 2>/dev/null || true)
                REMOUNT_STATE=$(echo "$REMOUNT_JSON" | grep -oP '"out-data"\s*:\s*"\K[^"]+' 2>/dev/null | sed 's/\\n$//' || true)

                if [[ "$ROOT_OPTS" == *"rw"* && "$REMOUNT_STATE" == "active" ]]; then
                    ok "Automatic remediation succeeded: root is rw and remount service is active."
                    VM_HEALTH_ERRORS=0
                    ROOT_RW_CHECK_FAILED=false
                    REMOUNT_CHECK_FAILED=false
                else
                    warn "Automatic remediation ran but VM health is still degraded (root_opts='${ROOT_OPTS:-unknown}', remount='${REMOUNT_STATE:-unknown}')."
                fi
            else
                warn "Automatic remediation completed but guest agent did not recover in time."
            fi
        else
            warn "Automatic remediation is disabled (--no-auto-fix)."
        fi
    elif (( VM_HEALTH_ERRORS > 0 )); then
        warn "Automatic remediation is disabled (--no-auto-fix)."
    fi
fi

if (( VM_HEALTH_ERRORS > 0 )); then
    collect_vm_diagnostics
    die "Post-conversion VM health checks failed (${VM_HEALTH_ERRORS} issue(s)). Review $LOG_FILE for host/guest diagnostics."
fi

# ==============================================================================
# 8. COMPLETION SUMMARY
# ==============================================================================

echo ""
e "${GREEN}${BOLD}==========================================${NC}"
e "${GREEN}${BOLD}         CONVERSION COMPLETE${NC}"
e "${GREEN}${BOLD}==========================================${NC}"
echo ""
e "  ${BOLD}VM ID:${NC}       $VMID"
e "  ${BOLD}Memory:${NC}      ${MEMORY}MB"
e "  ${BOLD}Cores:${NC}       $CORES"
e "  ${BOLD}Disk:${NC}        ${DISK_SIZE}GB ($DISK_FORMAT)"
e "  ${BOLD}Firmware:${NC}    $BIOS_TYPE"
e "  ${BOLD}Distro:${NC}      $DISTRO_FAMILY (${DISTRO_ID:-unknown})"
e "  ${BOLD}Network:${NC}     $($KEEP_NETWORK && echo 'preserved' || echo 'DHCP on ens18') (bridge: $BRIDGE)"
e "  ${BOLD}Snapshot:${NC}    $([[ "$CREATE_SNAPSHOT" == "true" ]] && echo 'created' || echo 'none')"
e "  ${BOLD}Destroy source:${NC}  $DESTROY_SOURCE"
e "  ${BOLD}Validation:${NC}  ${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed"
e "  ${BOLD}Log:${NC}         $LOG_FILE"
echo ""

# Clear resume state on successful conversion
clear_resume_state "$CTID" "$VMID"
echo ""
if ! $AUTO_START; then
    e "  ${YELLOW}Next steps:${NC}"
    e "    1. Review VM config:  ${BOLD}qm config $VMID${NC}"
    e "    2. Start the VM:      ${BOLD}qm start $VMID${NC}"
    e "    3. Open console:      ${BOLD}qm terminal $VMID -iface serial0${NC}"
else
    e "  ${GREEN}VM $VMID is running.${NC}"
    e "  Open console: ${BOLD}qm terminal $VMID -iface serial0${NC}"
fi
echo ""

}  # End of do_conversion()

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================

# If we reach here, we're in single conversion mode (not batch/range)
if [[ -n "$CTID" && -n "$VMID" ]]; then
    # Validate single conversion inputs
    if ! pct config "$CTID" >/dev/null 2>&1; then
        die "Container $CTID does not exist."
    fi

    if qm config "$VMID" >/dev/null 2>&1; then
        die "VM ID $VMID already exists. Choose a different ID."
    fi

    # Create snapshot if requested
    if $CREATE_SNAPSHOT; then
        create_snapshot "$CTID"
    fi

    # Run the conversion
    if do_conversion; then
        # Success - remove snapshot and optionally destroy source
        remove_snapshot "$CTID"

        # Export to remote storage if requested
        if [[ -n "$EXPORT_DEST" ]]; then
            export_vm_disk "$VMID" "$EXPORT_DEST"
        fi

        # Convert to template if requested
        if $AS_TEMPLATE; then
            convert_to_template "$VMID"
        fi

        if $DESTROY_SOURCE; then
            log "Destroying original container $CTID..."
            pct destroy "$CTID" >> "$LOG_FILE" 2>&1 && ok "Source container $CTID destroyed." || warn "Failed to destroy container $CTID"
        fi

        exit 0
    else
        # Failure - rollback if requested
        if $ROLLBACK_ON_FAILURE && $SNAPSHOT_CREATED; then
            rollback_snapshot "$CTID"
        fi
        exit 1
    fi
else
    die "No conversion to perform. Use --help for usage information."
fi