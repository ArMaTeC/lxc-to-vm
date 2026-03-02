#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# Proxmox VM to LXC Converter
# Version: 1.0.0
# ==============================================================================
#
# DESCRIPTION:
#   Converts Proxmox KVM virtual machines to LXC containers with full
#   VM artifact cleanup and container configuration. Supports multiple Linux
#   distributions and provides advanced features like batch processing,
#   predictive disk sizing, and Proxmox API integration.
#
# TARGET DISTRIBUTIONS:
#   - Debian/Ubuntu (systemd)
#   - Alpine Linux (OpenRC)
#   - RHEL/CentOS/Rocky/Alma (systemd)
#   - Arch Linux (systemd)
#
# KEY FEATURES:
#   - Automatic VM artifact removal (kernel, bootloader, initramfs)
#   - Multi-distro detection and LXC-specific configuration
#   - Network configuration migration (ens18 → eth0)
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

# ==============================================================================
# DEBUG MODE CONFIGURATION
# ==============================================================================
DEBUG=${VM_TO_LXC_DEBUG:-0}
LOG_FILE="/var/log/vm-to-lxc.log"

set -Eeuo pipefail

if [[ "${DEBUG:-0}" -eq 1 ]]; then
    export PS4='[${BASH_SOURCE}:${LINENO}] '
    set -x
fi

readonly VERSION="1.0.0"

# ==============================================================================
# CONSTANTS
# ==============================================================================
readonly MIN_DISK_GB=1
readonly DEFAULT_BRIDGE="vmbr0"
readonly REQUIRED_CMDS=(rsync kpartx losetup)

readonly E_INVALID_ARG=1
readonly E_NOT_FOUND=2
readonly E_DISK_FULL=3
readonly E_PERMISSION=4
readonly E_MIGRATION=5
readonly E_CONVERSION=6

# -----------------------------------------------------------------------------
# 0. HELPER FUNCTIONS
# -----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; PURPLE='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' BOLD='' NC=''
fi

e() { echo -e "$*"; }
log()  { printf "${BLUE}[*]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
debug() { [[ "${DEBUG:-0}" -eq 1 ]] || return 0; printf "${BLUE}[D]${NC} %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
verbose() { debug "$@"; }
checkpoint() { printf "\n${PURPLE}[+]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
die() { err "$*"; exit "${E_INVALID_ARG}"; }

dump_system_info() {
    [[ "${DEBUG:-0}" -eq 1 ]] || return 0
    log "System Information Dump:"
    log "  Hostname: $(hostname)"
    log "  Kernel: $(uname -r)"
    log "  Proxmox Version: $(pveversion 2>/dev/null || echo 'Unknown')"
}

dump_vm_info() {
    [[ "${DEBUG:-0}" -eq 1 ]] || return 0
    local vmid="$1"; [[ -n "$vmid" ]] || return 0
    log "VM Information Dump (VM $vmid):"
    qm config "$vmid" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE" >/dev/null || true
}

destroy_ct_if_exists() {
    local ctid="$1"
    pct config "$ctid" >/dev/null 2>&1 || return 0
    warn "CT ID $ctid already exists; stopping and destroying due to --replace-ct..."
    pct unlock "$ctid" >>"$LOG_FILE" 2>&1 || true
    pct stop "$ctid" >>"$LOG_FILE" 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pct status "$ctid" 2>/dev/null | grep -q 'stopped' && break; sleep 1
    done
    if pct destroy "$ctid" --destroy-unreferenced-disks 1 --purge 1 >>"$LOG_FILE" 2>&1; then
        ok "Destroyed existing CT $ctid."; return 0
    fi
    die "Failed to destroy existing CT $ctid. Check $LOG_FILE for details."
}

error_reason_and_fix() {
    local failed_cmd="$1"
    local reason="Command failed during conversion workflow."
    local fix="Check the full log and rerun with --dry-run to verify inputs and environment."
    case "$failed_cmd" in
        *"qm config"*) reason="VM configuration read failed."; fix="Run: qm status <VMID>; verify storage health." ;;
        *"rsync"*) reason="File copy failed."; fix="Check free space and retry (or use --resume)." ;;
        *"losetup"*|*"kpartx"*|*"mount"*) reason="Disk mounting failed."; fix="Check loop devices (losetup -a)." ;;
        *"pct create"*|*"pct set"*) reason="Container creation failed."; fix="Validate storage/bridge names." ;;
    esac
    printf '%s|%s\n' "$reason" "$fix"
}

error_exit_code() {
    local failed_cmd="$1"
    case "$failed_cmd" in
        *"pct config"*|*"qm config"*|*"pvesm path"*) echo "$E_NOT_FOUND" ;;
        *"df "*|*"rsync"*) echo "$E_DISK_FULL" ;;
        *"qm migrate"*) echo "$E_MIGRATION" ;;
        *"pct "*|*"qm "*|*"mount "*|*"losetup"*|*"kpartx"*) echo "$E_CONVERSION" ;;
        *) echo "$E_INVALID_ARG" ;;
    esac
}

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    local src_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    local failed_cmd="${BASH_COMMAND:-unknown}"
    trap - ERR
    local reason_fix=$(error_reason_and_fix "$failed_cmd")
    local reason="${reason_fix%%|*}" fix="${reason_fix#*|}"
    local mapped_code=$(error_exit_code "$failed_cmd")
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
${BOLD}Proxmox VM to LXC Converter v${VERSION}${NC}

Usage: $0 [OPTIONS]

Options:
  -v, --vmid <ID>        Source VM ID
  -c, --ctid <ID>        Target LXC container ID
  -s, --storage <NAME>   Proxmox storage target (e.g. local-lvm)
  -d, --disk-size <GB>   Container disk size in GB (omit for auto-calculate)
  -b, --bridge <NAME>    Network bridge (default: vmbr0)
  -t, --temp-dir <PATH>  Working directory for temp files (default: /var/lib/vz/dump)
  -n, --dry-run          Show what would be done without making changes
  -k, --keep-network     Preserve original network config (skip ens18 → eth0 translation)
  -S, --start            Auto-start container and run health checks after conversion
  --snapshot             Create VM snapshot before conversion (for rollback)
  --rollback-on-failure  Auto-rollback to snapshot if conversion fails
  --destroy-source       Destroy original VM after successful conversion
  --replace-ct           Replace existing container (stop & destroy if CTID exists)
  --resume               Resume interrupted conversion from partial state
  --batch <FILE>         Batch file with VMID/CTID pairs for mass conversion
  --range <START>-<END>  Convert VM range to CT range (e.g., 200-210:100-110)
  --save-profile <NAME>  Save current options as a named profile
  --profile <NAME>       Load options from a saved profile
  --wizard               Start interactive TUI wizard with progress bars
  --parallel <N>         Run N conversions in parallel (batch mode)
  --validate-only        Run pre-flight checks without converting
  --unprivileged         Create unprivileged container (default: privileged)
  --password <PASS>      Set root password for the container
  --api-host <HOST>      Proxmox API host for cluster operations
  --api-token <TOKEN>    API token for cluster authentication
  --api-user <USER>      API user (default: root@pam)
  --migrate-to-local     Auto-migrate VM to local node if on remote
  --predict-size         Use predictive advisor for disk size
  --no-auto-fix          Disable automatic remediation on health check failures
  -h, --help             Show this help message
  -V, --version          Show version

Hooks:
  Place executable scripts in /var/lib/vm-to-lxc/hooks/ to run at stages:
    pre-convert, post-convert, health-check-failed, pre-destroy
  Hooks receive VMID and CTID as arguments, with HOOK_VMID, HOOK_CTID, HOOK_STAGE env vars.

Examples:
  $0                                       # Interactive mode
  $0 -v 200 -c 100 -s local-lvm -d 16     # Non-interactive
  $0 -v 200 -c 100 -s local-lvm --start   # Auto-start + health checks
  $0 -v 200 -c 100 -s local-lvm --snapshot --rollback-on-failure
  $0 --batch conversions.txt               # Batch mode
  $0 --range 200-210:100-110 -s local-lvm  # Range mode
  $0 -v 200 -c 100 -s local-lvm --wizard  # TUI wizard mode
  $0 --batch conversions.txt --parallel 4  # Parallel batch
  $0 -v 200 --validate-only               # Pre-flight check
  $0 -v 200 -c 100 -s local-lvm --replace-ct --unprivileged
USAGE
    exit 0
}

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (try: sudo $0)"
fi

# --- Initialise log ---
mkdir -p "$(dirname "$LOG_FILE")"
echo "--- vm-to-lxc run: $(date -Is) ---" >> "$LOG_FILE"

ensure_dependency() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Dependency '$cmd' is missing. Installing package '$pkg'..."
        apt-get update -qq >> "$LOG_FILE" 2>&1 && apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1
        command -v "$cmd" >/dev/null 2>&1 || die "Failed to install '$pkg'. Install manually: apt install $pkg"
        ok "'$pkg' installed successfully."
    fi
}

cleanup() {
    echo ""
    log "Cleaning up resources..."
    [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]] && umount -Rlf "${MOUNT_POINT}" 2>/dev/null || true
    umount -lf "${MOUNT_POINT:-/nonexistent}" 2>/dev/null || true
    if [[ -n "${LOOP_DEV:-}" ]]; then
        kpartx -d "$LOOP_DEV" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        LOOP_DEV=""
    fi
    if [[ -n "${MOUNT_DISK_TEMP:-}" && -f "$MOUNT_DISK_TEMP" ]]; then
        kpartx -d "$MOUNT_DISK_TEMP" 2>/dev/null || true
    fi
    [[ -d "${TEMP_DIR:-}" ]] && { log "Removing temporary directory: $TEMP_DIR"; rm -rf "$TEMP_DIR"; }
}
trap cleanup EXIT INT TERM

# ==============================================================================
# PROXMOX API / CLUSTER INTEGRATION
# ==============================================================================

get_cluster_info() {
    local vmid="$1"
    qm config "$vmid" >/dev/null 2>/dev/null || return 1
    local hostname; hostname=$(hostname)
    pvesh get /nodes/$hostname/qemu/$vmid/status/current >/dev/null 2>&1 && { echo "$hostname"; return 0; }
    local nodes; nodes=$(pvesh get /nodes --output-format json 2>/dev/null | grep -oP '"node":"\K[^"]+' || echo "")
    for n in $nodes; do
        pvesh get /nodes/$n/qemu/$vmid/status/current >/dev/null 2>&1 && { echo "$n"; return 0; }
    done
    return 1
}

pve_api_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    [[ -z "$API_HOST" || -z "$API_TOKEN" ]] && die "API credentials not configured."
    local url="https://${API_HOST}:8006/api2/json${endpoint}"
    local auth_header="Authorization: PVEAPIToken=${API_USER}!${API_TOKEN}"
    if [[ "$method" == "GET" ]]; then curl -s -k -H "$auth_header" "$url" 2>/dev/null
    else curl -s -k -H "$auth_header" -X "$method" -d "$data" "$url" 2>/dev/null; fi
}

migrate_vm_to_local() {
    local vmid="$1"
    local target_node; target_node=$(get_cluster_info "$vmid") || die "Cannot determine node for VM $vmid"
    local local_node; local_node=$(hostname)
    [[ "$target_node" == "$local_node" ]] && { log "VM $vmid already on local node"; return 0; }
    log "VM $vmid is on remote node: $target_node"
    if $MIGRATE_TO_LOCAL; then
        $DRY_RUN && { log "[DRY-RUN] Would migrate VM $vmid to $local_node"; return 0; }
        local status; status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$status" == "running" ]] && { log "Stopping VM $vmid..."; qm stop "$vmid"; sleep 2; }
        qm migrate "$vmid" "$local_node" && { ok "VM $vmid migrated to $local_node"; sleep 3; return 0; }
        die "Migration failed. VM $vmid is still on $target_node"
    else
        warn "VM $vmid is on remote node $target_node. Use --migrate-to-local or run from $target_node"
        return 1
    fi
}

# ==============================================================================
# PLUGIN / HOOK SYSTEM
# ==============================================================================

HOOKS_DIR="/var/lib/vm-to-lxc/hooks"

run_hook() {
    local hook_name="$1" vmid="${2:-$VMID}" ctid="${3:-$CTID}"
    local hook_script="${HOOKS_DIR}/${hook_name}"
    if [[ -x "$hook_script" ]]; then
        log "Running hook: $hook_name"
        export HOOK_VMID="$vmid" HOOK_CTID="$ctid" HOOK_LOG_FILE="$LOG_FILE" HOOK_STAGE="$hook_name"
        "$hook_script" "$vmid" "$ctid" >> "$LOG_FILE" 2>&1 || { warn "Hook $hook_name exited with error (non-fatal)"; return 1; }
    fi
    return 0
}

# ==============================================================================
# PREDICTIVE DISK SIZE ADVISOR
# ==============================================================================

get_size_recommendation() {
    local mount_point="$1"
    log "Analyzing VM filesystem for disk size recommendation..."
    local used_bytes; used_bytes=$(du -sb --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
        --exclude='tmp/*' --exclude='run/*' --exclude='mnt/*' --exclude='media/*' --exclude='lost+found' \
        --exclude='boot/vmlinuz*' --exclude='boot/initr*' --exclude='boot/grub*' --exclude='boot/efi/*' \
        --exclude='lib/modules/*' "${mount_point}/" 2>/dev/null | awk '{print $1}')
    local used_mb=$(( ${used_bytes:-0} / 1024 / 1024 ))
    local used_gb=$(( (used_mb + 1023) / 1024 ))
    local recommended=$((used_gb + 2))
    [[ "$recommended" -lt 2 ]] && recommended=2
    local used_hr; used_hr=$(numfmt --to=iec-i --suffix=B "${used_bytes:-0}" 2>/dev/null || echo "${used_mb}MB")
    e "  ${BOLD}VM filesystem usage:${NC} ${used_hr} (~${used_gb}GB)"
    e "  ${GREEN}${BOLD}Recommendation:${NC} ${recommended}GB (usage + 2GB headroom)"
    echo "$recommended"
}

# ==============================================================================
# PROFILE MANAGEMENT
# ==============================================================================

PROFILE_DIR="/var/lib/vm-to-lxc/profiles"

ensure_profile_dir() { mkdir -p "$PROFILE_DIR" 2>/dev/null || die "Cannot create profile directory: $PROFILE_DIR"; }

list_profiles() {
    ensure_profile_dir; e "${BOLD}Available profiles:${NC}"; local found=false
    for profile in "$PROFILE_DIR"/*.conf; do
        [[ -f "$profile" ]] || continue; found=true
        local name=$(basename "$profile" .conf)
        local created=$(stat -c %y "$profile" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        e "  ${GREEN}•${NC} ${BOLD}$name${NC} (created: $created)"
    done; $found || echo "  (none)"; exit 0
}

save_profile() {
    local name="$1"; ensure_profile_dir
    cat > "$PROFILE_DIR/${name}.conf" <<PROFILE_EOF
STORAGE="${STORAGE:-}"
DISK_SIZE="${DISK_SIZE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
WORK_DIR="${WORK_DIR:-}"
KEEP_NETWORK="${KEEP_NETWORK:-false}"
AUTO_START="${AUTO_START:-false}"
UNPRIVILEGED="${UNPRIVILEGED:-false}"
PROFILE_EOF
    ok "Profile '${name}' saved"
}

load_profile() {
    local name="$1" profile_file="$PROFILE_DIR/${name}.conf"
    [[ -f "$profile_file" ]] || die "Profile '$name' not found."
    log "Loading profile: $name"; source "$profile_file"
}

# ==============================================================================
# SNAPSHOT MANAGEMENT
# ==============================================================================

SNAPSHOT_NAME="pre-conversion-$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_CREATED=false

create_snapshot() {
    local vmid="$1"; log "Creating snapshot '${SNAPSHOT_NAME}' for VM $vmid..."
    if qm snapshot "$vmid" "$SNAPSHOT_NAME" --description "Auto-created by vm-to-lxc before conversion" >> "$LOG_FILE" 2>&1; then
        SNAPSHOT_CREATED=true; ok "Snapshot created successfully."
    else warn "Failed to create snapshot. Rollback will not be available."; SNAPSHOT_CREATED=false; fi
}

rollback_snapshot() {
    local vmid="$1"; $SNAPSHOT_CREATED || return 0
    log "Rolling back VM $vmid to snapshot '${SNAPSHOT_NAME}'..."
    if qm rollback "$vmid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
        ok "Rollback successful."; qm delsnapshot "$vmid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1 || true
    else err "Rollback failed! Manual recovery: qm rollback $vmid $SNAPSHOT_NAME"; fi
}

remove_snapshot() {
    local vmid="$1"; $SNAPSHOT_CREATED || return 0
    log "Removing snapshot '${SNAPSHOT_NAME}'..."
    qm delsnapshot "$vmid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1 || warn "Failed to remove snapshot (non-critical)"
}

# ==============================================================================
# RESUME / PROGRESS PERSISTENCE
# ==============================================================================

RESUME_DIR="/var/lib/vm-to-lxc/resume"
RSYNC_PARTIAL_DIR=""

ensure_resume_dir() { mkdir -p "$RESUME_DIR" 2>/dev/null || die "Cannot create resume directory"; }
get_resume_file() { echo "$RESUME_DIR/vm${1}-ct${2}.state"; }

save_resume_state() {
    local vmid="$1" ctid="$2" stage="$3" data="${4:-}"; ensure_resume_dir
    cat > "$(get_resume_file "$vmid" "$ctid")" <<RESUME_EOF
VMID="$vmid"; CTID="$ctid"; STAGE="$stage"; TIMESTAMP="$(date -Is)"; TEMP_DIR="${TEMP_DIR:-}"; DATA="$data"
RESUME_EOF
}

clear_resume_state() {
    local state_file=$(get_resume_file "$1" "$2")
    [[ -f "$state_file" ]] && rm -f "$state_file"
    [[ -n "$RSYNC_PARTIAL_DIR" && -d "$RSYNC_PARTIAL_DIR" ]] && rm -rf "$RSYNC_PARTIAL_DIR" 2>/dev/null || true
}

check_resume_state() {
    local state_file=$(get_resume_file "$1" "$2")
    [[ -f "$state_file" ]] || return 1; source "$state_file"
    log "Found partial conversion state (stage: ${STAGE:-unknown}, from: ${TIMESTAMP:-unknown})"; return 0
}

# ==============================================================================
# BATCH PROCESSING
# ==============================================================================

process_batch_file() {
    local batch_file="$1"; [[ -f "$batch_file" ]] || die "Batch file not found: $batch_file"
    log "Processing batch file: $batch_file"
    local line_num=0 success_count=0 fail_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue; [[ -z "${line// /}" ]] && continue
        local batch_vmid=$(echo "$line" | awk '{print $1}') batch_ctid=$(echo "$line" | awk '{print $2}')
        [[ -z "$batch_vmid" || -z "$batch_ctid" ]] && { warn "Skipping invalid line $line_num"; continue; }
        echo ""; log "========================================"; log "Batch item $line_num: VM $batch_vmid → CT $batch_ctid"; log "========================================"
        run_single_conversion "$batch_vmid" "$batch_ctid" && success_count=$((success_count + 1)) || fail_count=$((fail_count + 1))
    done < "$batch_file"
    echo ""; e "${GREEN}${BOLD}  BATCH CONVERSION COMPLETE${NC}"
    e "  ${BOLD}Successful:${NC} $success_count  ${BOLD}Failed:${NC} $fail_count  ${BOLD}Total:${NC} $((success_count + fail_count))"
    exit 0
}

process_range() {
    local range_spec="$1"
    local vm_range="${range_spec%%:*}" ct_range="${range_spec#*:}"
    local vm_start="${vm_range%%-*}" vm_end="${vm_range#*-}" ct_start="${ct_range%%-*}" ct_end="${ct_range#*-}"
    [[ -z "$vm_start" || -z "$vm_end" || -z "$ct_start" || -z "$ct_end" ]] && die "Invalid range format. Use: --range START-END:START-END"
    local count=$((vm_end - vm_start + 1)) ct_count=$((ct_end - ct_start + 1))
    [[ "$count" -eq "$ct_count" ]] || die "Range sizes must match"
    log "Processing range: VM $vm_start-$vm_end → CT $ct_start-$ct_end ($count VMs)"
    local success_count=0 fail_count=0
    for i in $(seq 0 $((count - 1))); do
        local current_vmid=$((vm_start + i)) current_ctid=$((ct_start + i))
        echo ""; log "========================================"; log "Range item $((i+1))/$count: VM $current_vmid → CT $current_ctid"; log "========================================"
        run_single_conversion "$current_vmid" "$current_ctid" && success_count=$((success_count + 1)) || fail_count=$((fail_count + 1))
    done
    echo ""; e "${GREEN}${BOLD}  RANGE CONVERSION COMPLETE${NC}"
    e "  ${BOLD}Successful:${NC} $success_count  ${BOLD}Failed:${NC} $fail_count  ${BOLD}Total:${NC} $((success_count + fail_count))"
    exit 0
}

# ==============================================================================
# SINGLE CONVERSION WRAPPER
# ==============================================================================

run_single_conversion() {
    local single_vmid="$1" single_ctid="$2"
    VMID="$single_vmid"; CTID="$single_ctid"
    qm config "$VMID" >/dev/null 2>&1 || { err "VM $VMID does not exist. Skipping."; return 1; }
    if pct config "$CTID" >/dev/null 2>&1; then
        $CLEANUP_EXISTING_CT && destroy_ct_if_exists "$CTID" || { err "CT ID $CTID already exists. Skipping."; return 1; }
    fi
    $CREATE_SNAPSHOT && create_snapshot "$VMID"
    if do_conversion; then
        remove_snapshot "$VMID"
        if $DESTROY_SOURCE; then
            run_hook "pre-destroy" "$VMID" "$CTID"
            log "Destroying original VM $VMID..."
            qm stop "$VMID" >> "$LOG_FILE" 2>&1 || true; sleep 2
            qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >> "$LOG_FILE" 2>&1 \
                && ok "Source VM $VMID destroyed." || warn "Failed to destroy VM $VMID"
        fi
        return 0
    else
        $ROLLBACK_ON_FAILURE && $SNAPSHOT_CREATED && rollback_snapshot "$VMID"
        return 1
    fi
}

# ==============================================================================
# 1. ARGUMENT PARSING
# ==============================================================================

VMID="" CTID="" STORAGE="" DISK_SIZE="" BRIDGE="vmbr0" WORK_DIR=""
DRY_RUN=false KEEP_NETWORK=false AUTO_START=false
CREATE_SNAPSHOT=false ROLLBACK_ON_FAILURE=false DESTROY_SOURCE=false RESUME_MODE=false
BATCH_FILE="" RANGE_SPEC="" PROFILE_NAME="" SAVE_PROFILE_NAME=""
WIZARD_MODE=false PARALLEL_JOBS=1 VALIDATE_ONLY=false
UNPRIVILEGED=false CT_PASSWORD=""
API_HOST="" API_TOKEN="" API_USER="root@pam" MIGRATE_TO_LOCAL=false PREDICT_SIZE=false
AUTO_FIX=true CLEANUP_EXISTING_CT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vmid)       VMID="$2";        shift 2 ;;
        -c|--ctid)       CTID="$2";        shift 2 ;;
        -s|--storage)    STORAGE="$2";     shift 2 ;;
        -d|--disk-size)  DISK_SIZE="$2";   shift 2 ;;
        -b|--bridge)     BRIDGE="$2";      shift 2 ;;
        -t|--temp-dir)   WORK_DIR="$2";    shift 2 ;;
        -n|--dry-run)    DRY_RUN=true;      shift ;;
        -k|--keep-network) KEEP_NETWORK=true; shift ;;
        -S|--start)      AUTO_START=true;   shift ;;
        --no-auto-fix)   AUTO_FIX=false;    shift ;;
        --snapshot)      CREATE_SNAPSHOT=true; shift ;;
        --rollback-on-failure) ROLLBACK_ON_FAILURE=true; shift ;;
        --destroy-source) DESTROY_SOURCE=true; shift ;;
        --replace-ct)    CLEANUP_EXISTING_CT=true; shift ;;
        --resume)        RESUME_MODE=true;  shift ;;
        --batch)         BATCH_FILE="$2";  shift 2 ;;
        --range)         RANGE_SPEC="$2";  shift 2 ;;
        --save-profile)  SAVE_PROFILE_NAME="$2"; shift 2 ;;
        --profile)       PROFILE_NAME="$2"; shift 2 ;;
        --wizard)        WIZARD_MODE=true;  shift ;;
        --parallel)      PARALLEL_JOBS="$2"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=true; shift ;;
        --unprivileged)  UNPRIVILEGED=true; shift ;;
        --password)      CT_PASSWORD="$2"; shift 2 ;;
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

[[ -n "$PROFILE_NAME" ]] && load_profile "$PROFILE_NAME"

if $VALIDATE_ONLY; then
    [[ -n "$VMID" ]] || die "VM ID required for validation."
    run_preflight_validation "$VMID"; exit $?
fi

$WIZARD_MODE && run_wizard

[[ -n "$BATCH_FILE" ]] && [[ "$PARALLEL_JOBS" -gt 1 ]] && { process_batch_parallel "$BATCH_FILE" "$PARALLEL_JOBS"; exit 0; }
[[ -n "$BATCH_FILE" ]] && process_batch_file "$BATCH_FILE"
[[ -n "$RANGE_SPEC" ]] && process_range "$RANGE_SPEC"

if [[ -n "$SAVE_PROFILE_NAME" ]]; then
    save_profile "$SAVE_PROFILE_NAME"
    [[ -z "$VMID" || -z "$CTID" ]] && exit 0
fi

if $RESUME_MODE; then
    [[ -z "$VMID" || -z "$CTID" ]] && die "Resume mode requires --vmid and --ctid."
    check_resume_state "$VMID" "$CTID" || die "No resume state found for VM $VMID → CT $CTID."
fi

# ==============================================================================
# TUI / WIZARD MODE
# ==============================================================================

show_progress() {
    local current="$1" total="$2" label="${3:-Progress}" width=50
    local percentage=$((current * 100 / total)) filled=$((current * width / total)) empty=$((width - filled))
    printf "\r${BLUE}[*]${NC} %s [" "$label"
    printf "%${filled}s" | tr ' ' '█'; printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percentage"; [[ "$current" -eq "$total" ]] && printf "\n"
}

run_wizard() {
    echo ""; e "${BOLD}==========================================${NC}"
    e "${BOLD}   VM TO LXC CONVERTER - WIZARD MODE${NC}"; e "${BOLD}==========================================${NC}"; echo ""
    [[ -z "$VMID" ]] && read -rp "Enter Source VM ID (e.g., 200): " VMID
    if [[ -z "$CTID" ]]; then
        local suggested=$((VMID - 100)); [[ "$suggested" -lt 100 ]] && suggested=$((VMID + 100))
        read -rp "Enter Target Container ID [${suggested}]: " CTID; [[ -z "$CTID" ]] && CTID="$suggested"
    fi
    if [[ -z "$STORAGE" ]]; then
        echo ""; e "${BOLD}Available storage:${NC}"; pvesm status | awk 'NR>1{print "  - " $1 " (" $2 ")"}'; echo ""
        read -rp "Enter Target Storage Name: " STORAGE
    fi
    [[ -z "$DISK_SIZE" ]] && { echo ""; read -rp "Container Disk Size in GB (blank=auto): " DISK_SIZE; }
    echo ""; e "${BOLD}Additional Options:${NC}"
    read -rp "Keep original network config? [y/N]: " nc; [[ "$nc" =~ ^[Yy] ]] && KEEP_NETWORK=true
    read -rp "Create unprivileged container? [y/N]: " uc; [[ "$uc" =~ ^[Yy] ]] && UNPRIVILEGED=true
    read -rp "Create snapshot for rollback? [Y/n]: " sc; [[ -z "$sc" || "$sc" =~ ^[Yy] ]] && CREATE_SNAPSHOT=true
    $CREATE_SNAPSHOT && { read -rp "Auto-rollback on failure? [Y/n]: " rc; [[ -z "$rc" || "$rc" =~ ^[Yy] ]] && ROLLBACK_ON_FAILURE=true; }
    read -rp "Auto-start container after conversion? [Y/n]: " ac; [[ -z "$ac" || "$ac" =~ ^[Yy] ]] && AUTO_START=true
    $AUTO_START && { read -rp "Destroy source VM after verification? [y/N]: " dc; [[ "$dc" =~ ^[Yy] ]] && DESTROY_SOURCE=true; }
    echo ""; e "${BOLD}========================================${NC}"; e "${BOLD}Conversion Summary:${NC}"
    e "  Source VM: ${GREEN}$VMID${NC}  Target CT: ${GREEN}$CTID${NC}  Storage: ${GREEN}$STORAGE${NC}"
    e "${BOLD}========================================${NC}"; echo ""
    read -rp "Proceed? [Y/n]: " confirm; [[ -n "$confirm" && ! "$confirm" =~ ^[Yy] ]] && die "Cancelled by user"
}

run_preflight_validation() {
    local check_vmid="${1:-$VMID}"; [[ -z "$check_vmid" ]] && die "VM ID required"
    e "${BOLD}   PRE-FLIGHT VALIDATION${NC}"; echo ""
    local checks_passed=0 checks_total=0
    check_pass() { e "  ${GREEN}[✓]${NC} $1"; ((checks_passed++)); ((checks_total++)); }
    check_fail() { e "  ${RED}[✗]${NC} $1"; ((checks_total++)); }
    check_warn() { e "  ${YELLOW}[!]${NC} $1"; ((checks_total++)); }
    qm config "$check_vmid" >/dev/null 2>&1 && check_pass "VM $check_vmid exists" || { check_fail "VM $check_vmid does not exist"; return 1; }
    local status=$(qm status "$check_vmid" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "stopped" ]] && check_pass "VM is stopped" || check_warn "VM is running"
    local disk_ref=$(qm config "$check_vmid" 2>/dev/null | awk -F': ' '/^(scsi|virtio|ide|sata)0:/{print $2; exit}')
    [[ -n "$disk_ref" ]] && check_pass "VM disk found" || check_fail "No disk found"
    qm config "$check_vmid" | grep -q "net0:" && check_pass "Network configured" || check_warn "No network interface"
    local storage_list=$(pvesm status 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ', ')
    [[ -n "$storage_list" ]] && check_pass "Storage available" || check_fail "No storage"
    local missing=""; for cmd in rsync kpartx losetup; do command -v "$cmd" >/dev/null 2>&1 || missing+="$cmd "; done
    [[ -z "$missing" ]] && check_pass "All dependencies available" || check_warn "Missing: $missing"
    echo ""; e "Validation: ${checks_passed}/${checks_total} passed"
    [[ "$checks_passed" -eq "$checks_total" ]] && { e "${GREEN}VM ready for conversion!${NC}"; return 0; }
    e "${YELLOW}Review warnings above.${NC}"; return 1
}

process_batch_parallel() {
    local batch_file="$1" max_jobs="${2:-1}"; [[ -f "$batch_file" ]] || die "Batch file not found"
    local -a jobs=(); while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue; [[ -z "${line// /}" ]] && continue; jobs+=("$line")
    done < "$batch_file"
    local total=${#jobs[@]} running=0 completed=0
    for job in "${jobs[@]}"; do
        local bv=$(echo "$job" | awk '{print $1}') bc=$(echo "$job" | awk '{print $2}')
        while [[ $running -ge $max_jobs ]]; do sleep 1; running=$(jobs -r | wc -l); done
        ( run_single_conversion "$bv" "$bc" >> "$LOG_FILE" 2>&1 ) &
        ((running++)); ((completed++))
    done; wait
    echo ""; e "${GREEN}${BOLD}  PARALLEL BATCH COMPLETE (${total} items)${NC}"
}

# ==============================================================================
# 2. SETUP & CHECKS
# ==============================================================================

e "${BOLD}==========================================${NC}"
e "${BOLD}   PROXMOX VM TO LXC CONVERTER v${VERSION}${NC}"
e "${BOLD}==========================================${NC}"

ensure_dependency rsync
ensure_dependency kpartx
ensure_dependency losetup util-linux
ensure_dependency qemu-img qemu-utils

[[ -z "$VMID" ]]    && read -rp "Enter Source VM ID (e.g., 200): " VMID
[[ -z "$CTID" ]]    && read -rp "Enter New Container ID (e.g., 100): " CTID
[[ -z "$STORAGE" ]] && read -rp "Enter Target Storage Name (e.g., local-lvm): " STORAGE

[[ "$VMID" =~ ^[0-9]+$ ]] || die "VM ID must be a positive integer, got: '$VMID'"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Container ID must be a positive integer, got: '$CTID'"
[[ -n "$DISK_SIZE" ]] && { [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || die "Disk size must be integer GB"; [[ "$DISK_SIZE" -ge 1 ]] || die "Disk size must be ≥ 1 GB"; }

qm config "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist."
if pct config "$CTID" >/dev/null 2>&1; then
    $CLEANUP_EXISTING_CT && destroy_ct_if_exists "$CTID" || die "CT ID $CTID already exists."
fi
pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE" || die "Storage '$STORAGE' not found."

STORAGE_STATUS=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" 'NR>1 && $1==s{print $3; exit}')
[[ "${STORAGE_STATUS:-}" == "active" ]] || die "Storage '$STORAGE' is not active."

VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
if [[ "$VM_STATUS" == "running" ]]; then
    $DRY_RUN && warn "VM $VMID is running. Would stop it." || { warn "VM $VMID is running. Stopping..."; qm stop "$VMID"; sleep 3; }
fi

if $DRY_RUN; then
    echo ""; e "${BOLD}=== DRY RUN — No changes will be made ===${NC}"; echo ""
    e "  ${BOLD}Source VM:${NC} $VMID  ${BOLD}Target CT:${NC} $CTID  ${BOLD}Storage:${NC} $STORAGE"
    [[ -n "$DISK_SIZE" ]] && e "  ${BOLD}Disk:${NC} ${DISK_SIZE}GB" || e "  ${BOLD}Disk:${NC} auto-calculate"
    e "  ${BOLD}Bridge:${NC} $BRIDGE  ${BOLD}Keep net:${NC} $KEEP_NETWORK  ${BOLD}Unprivileged:${NC} $UNPRIVILEGED"
    e "  ${BOLD}Auto-start:${NC} $AUTO_START  ${BOLD}Snapshot:${NC} $CREATE_SNAPSHOT  ${BOLD}Destroy source:${NC} $DESTROY_SOURCE"
    echo ""; e "  ${BOLD}Steps:${NC}"
    $CREATE_SNAPSHOT && echo "    0. Create VM snapshot"
    echo "    1. Stop VM and mount VM disk"
    echo "    2. Detect OS distribution"
    echo "    3. Copy filesystem (excluding VM-specific files)"
    $KEEP_NETWORK && echo "    4. Preserve network config" || echo "    4. Reconfigure networking (ens18 → eth0)"
    echo "    5. Remove VM artifacts (kernel, bootloader, modules)"
    echo "    6. Create LXC container $CTID on $STORAGE"
    $AUTO_START && echo "    7. Start container + health checks"
    $DESTROY_SOURCE && echo "    8. Destroy source VM $VMID"
    echo ""; ok "Dry run complete. Remove --dry-run to execute."; exit 0
fi

# ==============================================================================
# MAIN CONVERSION FUNCTION
# ==============================================================================

check_space() { local a; a=$(df -BM --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' M'); echo "${a:-0}"; }

pick_work_dir() {
    local base="$1" required_mb="${2:-10240}"
    local avail_mb=$(check_space "$base")
    [[ "$avail_mb" -ge "$required_mb" ]] && { echo "$base"; return 0; }
    warn "Insufficient space in $base: ${avail_mb}MB < ${required_mb}MB" >&2
    [[ -n "$WORK_DIR" ]] && die "Specified --temp-dir too small."
    local -a cmp=() cav=(); local mp="" avail=""
    while read -r avail mp; do avail="${avail%M}"; [[ "$avail" =~ ^[0-9]+$ ]] || continue
        [[ "$mp" == "/boot"* || "$mp" == "/snap"* || "$mp" == "/run"* || "$mp" == "/dev"* ]] && continue
        [[ "$avail" -ge "$required_mb" ]] && { cmp+=("$mp"); cav+=("$avail"); }
    done < <(df -BM --output=avail,target 2>/dev/null | tail -n +2)
    [[ ${#cmp[@]} -eq 0 ]] && die "No mount point with enough space (${required_mb}MB)."
    [[ ${#cmp[@]} -eq 1 ]] && { mkdir -p "${cmp[0]}"; echo "${cmp[0]}"; return 0; }
    echo "" >&2; e "${BOLD}Available mount points:${NC}" >&2
    for i in "${!cmp[@]}"; do e "  ${GREEN}[$((i+1))]${NC} ${cmp[$i]} — ${cav[$i]}MB free" >&2; done
    echo "" >&2; local choice; read -rp "Select [1-${#cmp[@]}] or custom path: " choice
    local sel=""
    [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#cmp[@]} ]] && sel="${cmp[$((choice-1))]}"
    [[ -z "$sel" && -n "$choice" ]] && sel="$choice"; [[ -z "$sel" ]] && sel="${cmp[0]}"
    mkdir -p "$sel"; echo "$sel"
}

do_conversion() {
    local conversion_start_time=$(date +%s)
    dump_vm_info "$VMID"
    verbose "Starting conversion: VM $VMID → CT $CTID"

    # Run pre-convert hook
    run_hook "pre-convert" "$VMID" "$CTID"

    # --- Locate VM disk ---
    log "Locating VM $VMID disk..."
    VM_CONFIG_RAW="$(qm config "$VMID" 2>/dev/null || true)"
    DISK_REF=""
    for bus in scsi virtio ide sata; do
        DISK_REF=$(echo "$VM_CONFIG_RAW" | awk -F': ' "/^${bus}0:/{print \$2; exit}")
        [[ -n "$DISK_REF" ]] && break
    done
    [[ -n "$DISK_REF" ]] || die "No disk found on VM $VMID"
    DISK_VOLID=$(echo "$DISK_REF" | cut -d',' -f1)
    DISK_PATH=$(pvesm path "$DISK_VOLID" 2>/dev/null)
    [[ -n "$DISK_PATH" && -e "$DISK_PATH" ]] || die "Cannot resolve disk path for $DISK_VOLID"
    log "VM disk: $DISK_PATH"

    # --- Work directory ---
    local DEFAULT_WORK_BASE="/var/lib/vz/dump"
    local REQUIRED_MB=$(( (${DISK_SIZE:-32} + 5) * 1024 ))
    WORK_BASE="${WORK_DIR:-$DEFAULT_WORK_BASE}"; mkdir -p "$WORK_BASE" 2>/dev/null || true
    WORK_BASE=$(pick_work_dir "$WORK_BASE" "$REQUIRED_MB")
    TEMP_DIR="${WORK_BASE}/vm-to-lxc-${VMID}"
    STAGING_DIR="${TEMP_DIR}/rootfs"
    MOUNT_POINT="${TEMP_DIR}/mnt"
    MOUNT_DISK_TEMP=""
    log "Working directory: $TEMP_DIR"
    rm -rf "${TEMP_DIR:?}"; mkdir -p "$STAGING_DIR" "$MOUNT_POINT"

    # --- Mount VM disk ---
    log "Mounting VM disk..."
    local disk_fmt=$(qemu-img info "$DISK_PATH" 2>/dev/null | awk '/file format:/{print $3}' || echo "unknown")
    log "Detected disk format: $disk_fmt"
    local mount_disk="$DISK_PATH"
    if [[ "$disk_fmt" != "raw" && "$disk_fmt" != "unknown" ]]; then
        log "Converting $disk_fmt to raw for mounting..."
        MOUNT_DISK_TEMP="${TEMP_DIR}/vm-disk.raw"
        qemu-img convert -f "$disk_fmt" -O raw "$DISK_PATH" "$MOUNT_DISK_TEMP" >> "$LOG_FILE" 2>&1
        mount_disk="$MOUNT_DISK_TEMP"
        ok "Disk converted to raw."
    fi

    log "Mapping disk partitions..."
    local kp_out=$(kpartx -av "$mount_disk" 2>&1) || die "Failed to map partitions"
    echo "$kp_out" >> "$LOG_FILE"
    LOOP_DEV=$(echo "$kp_out" | grep -oP 'loop\d+' | head -1)
    [[ -n "$LOOP_DEV" ]] && LOOP_DEV="/dev/${LOOP_DEV}"

    # Find root partition
    local ROOT_PART=""
    for ps in p2 p1 p3; do
        local mp_name=$(echo "$kp_out" | awk '/add map/{print $3}' | grep "${ps}$" | head -1)
        [[ -n "$mp_name" ]] || continue
        local dev="/dev/mapper/${mp_name}"
        [[ -b "$dev" ]] || continue
        local ft=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
        [[ "$ft" =~ ^(ext[234]|xfs|btrfs)$ ]] && { ROOT_PART="$dev"; break; }
    done
    if [[ -z "$ROOT_PART" ]]; then
        while read -r addline; do
            local mp_name=$(echo "$addline" | awk '{print $3}')
            [[ -n "$mp_name" ]] || continue
            local dev="/dev/mapper/${mp_name}"; [[ -b "$dev" ]] || continue
            local ft=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
            [[ "$ft" =~ ^(ext[234]|xfs|btrfs)$ ]] && { ROOT_PART="$dev"; break; }
        done <<< "$(echo "$kp_out" | grep 'add map')"
    fi
    [[ -n "$ROOT_PART" ]] || die "Could not find Linux root partition in VM disk."
    log "Root partition: $ROOT_PART"
    mount "$ROOT_PART" "$MOUNT_POINT" || die "Failed to mount $ROOT_PART"
    [[ -d "$MOUNT_POINT/etc" ]] || die "Not a valid Linux root filesystem"
    ok "VM root filesystem mounted."

    # --- Detect distro ---
    DISTRO_FAMILY="unknown"; DISTRO_ID="unknown"
    if [[ -f "$MOUNT_POINT/etc/os-release" ]]; then
        DISTRO_ID="$(awk -F= '$1=="ID"{print $2; exit}' "$MOUNT_POINT/etc/os-release" 2>/dev/null || true)"
        DISTRO_ID="${DISTRO_ID//\"/}"; DISTRO_ID="${DISTRO_ID//\'/}"; DISTRO_ID="${DISTRO_ID,,}"
        [[ -n "$DISTRO_ID" ]] || DISTRO_ID="unknown"
        case "$DISTRO_ID" in
            debian|ubuntu|linuxmint|pop|kali|proxmox) DISTRO_FAMILY="debian" ;;
            alpine) DISTRO_FAMILY="alpine" ;;
            centos|rhel|rocky|alma|fedora|ol) DISTRO_FAMILY="rhel" ;;
            arch|manjaro|endeavouros) DISTRO_FAMILY="arch" ;;
            *) DISTRO_FAMILY="debian" ;;
        esac
    elif [[ -f "$MOUNT_POINT/etc/alpine-release" ]]; then DISTRO_FAMILY="alpine"; DISTRO_ID="alpine"
    elif [[ -f "$MOUNT_POINT/etc/redhat-release" ]]; then DISTRO_FAMILY="rhel"; DISTRO_ID="rhel"; fi
    log "Detected distro: $DISTRO_FAMILY ($DISTRO_ID)"

    # --- Auto-calculate disk size ---
    if [[ -z "$DISK_SIZE" ]]; then
        log "Auto-calculating container disk size..."
        DISK_SIZE=$(get_size_recommendation "$MOUNT_POINT" | tail -1)
        [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || DISK_SIZE=8
        ok "Auto-calculated disk size: ${DISK_SIZE}GB"
    fi

    # --- Copy filesystem ---
    log "Copying VM filesystem to staging area..."
    rsync -axHAX --info=progress2 --no-inc-recursive \
        --partial --partial-dir="${TEMP_DIR}/.rsync-partial" \
        --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
        --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
        --exclude='/media/*' --exclude='/lost+found' \
        --exclude='/boot/vmlinuz*' --exclude='/boot/initr*' \
        --exclude='/boot/grub*' --exclude='/boot/grub2*' \
        --exclude='/boot/efi/*' --exclude='/boot/loader/*' \
        --exclude='/boot/System.map*' --exclude='/boot/config-*' \
        --exclude='/lib/modules/*' --exclude='/var/lib/dkms/*' \
        "${MOUNT_POINT}/" "${STAGING_DIR}/" || {
        save_resume_state "$VMID" "$CTID" "rsync-failed"; die "Rsync failed. Resume with: $0 -v $VMID -c $CTID --resume"
    }
    ok "Filesystem copied."

    # Unmount VM disk
    log "Unmounting VM disk..."
    umount -lf "$MOUNT_POINT" 2>/dev/null || true
    kpartx -d "$mount_disk" 2>/dev/null || true
    [[ -n "${LOOP_DEV:-}" ]] && { losetup -d "$LOOP_DEV" 2>/dev/null || true; LOOP_DEV=""; }

    # --- Clean VM artifacts ---
    log "Removing VM artifacts..."
    rm -rf "$STAGING_DIR/boot/grub" "$STAGING_DIR/boot/grub2" "$STAGING_DIR/boot/efi" 2>/dev/null || true
    rm -f "$STAGING_DIR/boot/vmlinuz"* "$STAGING_DIR/boot/initr"* "$STAGING_DIR/boot/System.map"* "$STAGING_DIR/boot/config-"* 2>/dev/null || true
    rm -rf "$STAGING_DIR/lib/modules/"* "$STAGING_DIR/var/lib/dkms" 2>/dev/null || true

    # Remove GRUB default config
    rm -f "$STAGING_DIR/etc/default/grub" 2>/dev/null || true

    # Remove VM-specific systemd units
    rm -f "$STAGING_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true
    rm -f "$STAGING_DIR/etc/modprobe.d/blacklist-pcspkr.conf" 2>/dev/null || true

    # Remove qemu-guest-agent autostart (not needed in LXC)
    rm -f "$STAGING_DIR/etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service" 2>/dev/null || true

    # Remove fstab (container uses Proxmox-managed mounts)
    if [[ -f "$STAGING_DIR/etc/fstab" ]]; then
        log "Cleaning fstab..."
        echo "# Managed by Proxmox LXC" > "$STAGING_DIR/etc/fstab"
    fi

    # --- Network configuration ---
    if ! $KEEP_NETWORK; then
        log "Reconfiguring network for container (ens18 → eth0)..."
        # Debian/Ubuntu interfaces
        if [[ -f "$STAGING_DIR/etc/network/interfaces" ]]; then
            sed -i 's/\bens18\b/eth0/g' "$STAGING_DIR/etc/network/interfaces"
            # Remove any GRUB or VM-specific lines
            sed -i '/^#.*grub/Id' "$STAGING_DIR/etc/network/interfaces"
        fi
        # Netplan
        if [[ -d "$STAGING_DIR/etc/netplan" ]]; then
            rm -f "$STAGING_DIR/etc/netplan/"*.yaml 2>/dev/null || true
            cat > "$STAGING_DIR/etc/netplan/01-netcfg.yaml" <<'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
NETPLAN
        fi
        # NetworkManager
        if [[ -d "$STAGING_DIR/etc/NetworkManager/system-connections" ]]; then
            for f in "$STAGING_DIR/etc/NetworkManager/system-connections/"*; do
                [[ -f "$f" ]] && sed -i 's/interface-name=ens18/interface-name=eth0/g' "$f"
            done
        fi
        # RHEL/CentOS network-scripts
        if [[ -d "$STAGING_DIR/etc/sysconfig/network-scripts" ]]; then
            for f in "$STAGING_DIR/etc/sysconfig/network-scripts/ifcfg-"*; do
                [[ -f "$f" ]] && sed -i 's/ens18/eth0/g' "$f"
            done
            if [[ -f "$STAGING_DIR/etc/sysconfig/network-scripts/ifcfg-ens18" ]]; then
                mv "$STAGING_DIR/etc/sysconfig/network-scripts/ifcfg-ens18" \
                   "$STAGING_DIR/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || true
            fi
        fi
        # Alpine
        if [[ -f "$STAGING_DIR/etc/network/interfaces" ]] && [[ "$DISTRO_FAMILY" == "alpine" ]]; then
            sed -i 's/\bens18\b/eth0/g' "$STAGING_DIR/etc/network/interfaces"
        fi
    fi
    ok "VM artifacts cleaned and container configured."

    # --- Ensure essential dirs exist ---
    mkdir -p "$STAGING_DIR/dev" "$STAGING_DIR/proc" "$STAGING_DIR/sys" \
             "$STAGING_DIR/tmp" "$STAGING_DIR/run" "$STAGING_DIR/mnt" "$STAGING_DIR/media" 2>/dev/null || true
    chmod 1777 "$STAGING_DIR/tmp" 2>/dev/null || true

    # --- Create tarball ---
    log "Creating container rootfs tarball..."
    TARBALL="${TEMP_DIR}/rootfs.tar.gz"
    tar -czf "$TARBALL" -C "$STAGING_DIR" . >> "$LOG_FILE" 2>&1
    ok "Tarball created: $(du -h "$TARBALL" | awk '{print $1}')"

    # --- Extract VM config for container ---
    MEMORY=$(echo "$VM_CONFIG_RAW" | awk '/^memory:/{print $2}')
    [[ -z "$MEMORY" || "$MEMORY" -lt 128 ]] && MEMORY=2048
    CORES=$(echo "$VM_CONFIG_RAW" | awk '/^cores:/{print $2}')
    [[ -z "$CORES" || "$CORES" -lt 1 ]] && CORES=2
    VM_HOSTNAME=$(echo "$VM_CONFIG_RAW" | awk '/^name:/{print $2; exit}')
    [[ -n "$VM_HOSTNAME" ]] || VM_HOSTNAME="vm${VMID}"
    CT_HOSTNAME="${VM_HOSTNAME}-lxc"

    # --- Create LXC container ---
    log "Creating LXC container $CTID..."
    log "  Name: $CT_HOSTNAME, Memory: ${MEMORY}MB, Cores: $CORES, Disk: ${DISK_SIZE}GB"

    local PCT_CREATE_ARGS=(
        "$CTID" "$TARBALL"
        --hostname "$CT_HOSTNAME"
        --memory "$MEMORY"
        --cores "$CORES"
        --storage "$STORAGE"
        --rootfs "${STORAGE}:${DISK_SIZE}"
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
        --ostype "unmanaged"
    )

    if $UNPRIVILEGED; then
        PCT_CREATE_ARGS+=(--unprivileged 1)
    fi

    if [[ -n "$CT_PASSWORD" ]]; then
        PCT_CREATE_ARGS+=(--password "$CT_PASSWORD")
    fi

    pct create "${PCT_CREATE_ARGS[@]}" >> "$LOG_FILE" 2>&1
    ok "Container $CTID created."

    # Run post-convert hook
    run_hook "post-convert" "$VMID" "$CTID"

    # ==============================================================================
    # POST-CONVERSION VALIDATION
    # ==============================================================================

    log "Running post-conversion validation..."
    local CHECKS_PASSED=0 CHECKS_TOTAL=0 CT_HEALTH_ERRORS=0

    run_check() {
        local name="$1" result="$2" detail="${3:-}"
        CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
        if [[ "$result" -eq 0 ]]; then
            ok "CHECK: $name ${detail:+— $detail}"; CHECKS_PASSED=$((CHECKS_PASSED + 1))
        else
            err "CHECK: $name ${detail:+— $detail}"; CT_HEALTH_ERRORS=$((CT_HEALTH_ERRORS + 1))
        fi
    }

    pct config "$CTID" >/dev/null 2>&1; run_check "Container config exists" $?
    local disk_check=$(pct config "$CTID" 2>/dev/null | grep -c "rootfs:")
    run_check "Rootfs configured" $([[ "$disk_check" -ge 1 ]] && echo 0 || echo 1)
    local net_check=$(pct config "$CTID" 2>/dev/null | grep -c "net0:")
    run_check "Network configured (net0)" $([[ "$net_check" -ge 1 ]] && echo 0 || echo 1)

    log "Validation: ${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed."

    # --- Auto-start & health checks ---
    if $AUTO_START; then
        log "Starting container $CTID..."
        pct start "$CTID" >> "$LOG_FILE" 2>&1
        sleep 3
        local ct_status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
        run_check "Container running" $([[ "$ct_status" == "running" ]] && echo 0 || echo 1) "$ct_status"

        if [[ "$ct_status" == "running" ]]; then
            # Wait for container to settle
            sleep 5
            # Check if we can exec into the container
            if pct exec "$CTID" -- /bin/true >/dev/null 2>&1; then
                ok "Container $CTID is responding to exec commands."

                # Get IP address
                local CT_IP=""
                CT_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "unknown")
                [[ "$CT_IP" != "unknown" && -n "$CT_IP" ]] && ok "Container IP: $CT_IP" || warn "Could not determine container IP."

                # Get OS info
                local CT_OS=""
                CT_OS=$(pct exec "$CTID" -- cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "unknown")
                [[ "$CT_OS" != "unknown" ]] && ok "Guest OS: $CT_OS"
            else
                warn "Container started but exec not yet responding. May need more time."
            fi
        fi
    fi

    if (( CT_HEALTH_ERRORS > 0 )); then
        run_hook "health-check-failed" "$VMID" "$CTID"
        warn "Post-conversion health checks had ${CT_HEALTH_ERRORS} issue(s). Review $LOG_FILE."
    fi

    # ==============================================================================
    # COMPLETION SUMMARY
    # ==============================================================================

    local conversion_end_time=$(date +%s)
    local duration=$((conversion_end_time - conversion_start_time))

    echo ""
    e "${GREEN}${BOLD}==========================================${NC}"
    e "${GREEN}${BOLD}         CONVERSION COMPLETE${NC}"
    e "${GREEN}${BOLD}==========================================${NC}"
    echo ""
    e "  ${BOLD}Container ID:${NC}  $CTID"
    e "  ${BOLD}Hostname:${NC}      $CT_HOSTNAME"
    e "  ${BOLD}Memory:${NC}        ${MEMORY}MB"
    e "  ${BOLD}Cores:${NC}         $CORES"
    e "  ${BOLD}Disk:${NC}          ${DISK_SIZE}GB"
    e "  ${BOLD}Distro:${NC}        $DISTRO_FAMILY (${DISTRO_ID})"
    e "  ${BOLD}Network:${NC}       $($KEEP_NETWORK && echo 'preserved' || echo 'DHCP on eth0') (bridge: $BRIDGE)"
    e "  ${BOLD}Unprivileged:${NC}  $UNPRIVILEGED"
    e "  ${BOLD}Snapshot:${NC}      $([[ "$CREATE_SNAPSHOT" == "true" ]] && echo 'created' || echo 'none')"
    e "  ${BOLD}Destroy source:${NC} $DESTROY_SOURCE"
    e "  ${BOLD}Validation:${NC}    ${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed"
    e "  ${BOLD}Duration:${NC}      ${duration}s"
    e "  ${BOLD}Log:${NC}           $LOG_FILE"
    echo ""

    clear_resume_state "$VMID" "$CTID"

    if ! $AUTO_START; then
        e "  ${YELLOW}Next steps:${NC}"
        e "    1. Review config:  ${BOLD}pct config $CTID${NC}"
        e "    2. Start:          ${BOLD}pct start $CTID${NC}"
        e "    3. Enter console:  ${BOLD}pct enter $CTID${NC}"
    else
        e "  ${GREEN}Container $CTID is running.${NC}"
        e "  Enter console: ${BOLD}pct enter $CTID${NC}"
    fi
    echo ""
}  # End of do_conversion()

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================

if [[ -n "$VMID" && -n "$CTID" ]]; then
    qm config "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist."
    if pct config "$CTID" >/dev/null 2>&1; then
        $CLEANUP_EXISTING_CT && destroy_ct_if_exists "$CTID" || die "CT ID $CTID already exists."
    fi
    $CREATE_SNAPSHOT && create_snapshot "$VMID"
    if do_conversion; then
        remove_snapshot "$VMID"
        if $DESTROY_SOURCE; then
            run_hook "pre-destroy" "$VMID" "$CTID"
            log "Destroying original VM $VMID..."
            qm stop "$VMID" >> "$LOG_FILE" 2>&1 || true; sleep 2
            qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >> "$LOG_FILE" 2>&1 \
                && ok "Source VM $VMID destroyed." || warn "Failed to destroy VM $VMID"
        fi
        exit 0
    else
        $ROLLBACK_ON_FAILURE && $SNAPSHOT_CREATED && rollback_snapshot "$VMID"
        exit 1
    fi
else
    die "No conversion to perform. Use --help for usage information."
fi
