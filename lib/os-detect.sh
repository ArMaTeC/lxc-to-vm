#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: os-detect.sh
# Description: Os detect
# License: MIT
# ==============================================================================

### Function: detect_os_from_disk
# Detect the operating system installed on a disk image.
#
# Arguments:
#   $1 - Path to the disk image to inspect.
#   $2 - Disk image format (default: "raw").
#
# Globals (set by this function):
#   OS_TYPE             - "windows", "linux", or "unknown".
#   OS_DISTRO           - Distribution name (e.g., "windows") or "unknown".
#   OS_VERSION          - OS version string when available.
#   OS_BOOT_MODE        - "uefi", "bios", or "unknown".
#   OS_PARTITION_TABLE  - "gpt", "mbr", or "unknown".
#   OS_HAS_ESP          - "true" if an EFI System Partition is present.
#
# Returns:
#   0 if detection succeeded, 1 if the OS could not be identified.
detect_os_from_disk() {
    local disk_path="$1"
    local img_format="${2:-raw}"

    # Reset globals
    OS_TYPE="unknown"
    OS_DISTRO="unknown"
    OS_VERSION=""
    OS_BOOT_MODE="unknown"
    OS_PARTITION_TABLE="unknown"
    OS_HAS_ESP="false"

    # Primary path: libguestfs inspection
    if command -v virt-inspector &>/dev/null; then
        _detect_via_guestfs "$disk_path" "$img_format" && return 0
    fi

    # Fallback path: partition type heuristics
    if _detect_via_partition_types "$disk_path" "$img_format"; then
        if [[ "$OS_TYPE" == "unknown" ]]; then
            return 1
        fi
        return 0
    fi

    return 1
}

### Function: _detect_via_guestfs
# Internal helper that detects OS details using virt-inspector (libguestfs).
#
# Arguments:
#   $1 - Path to the disk image.
#   $2 - Disk image format (default: "raw").
#
# Globals (set by this function):
#   OS_TYPE, OS_DISTRO, OS_VERSION, OS_BOOT_MODE,
#   OS_PARTITION_TABLE, OS_HAS_ESP
#
# Returns:
#   0 if libguestfs inspection succeeded and produced usable output, 1 otherwise.
_detect_via_guestfs() {
    local disk_path="$1"
    local img_format="${2:-raw}"
    local inspector_out=""

    # Use virt-inspector if available; suppress libguestfs warnings
    if ! inspector_out=$(LIBGUESTFS_BACKEND=direct virt-inspector \
        --format="$img_format" \
        -a "$disk_path" 2>/dev/null); then
        return 1
    fi

    [[ -z "$inspector_out" ]] && return 1

    # Parse OS type
    if echo "$inspector_out" | grep -qi "windows"; then
        OS_TYPE="windows"
        OS_DISTRO="windows"
    elif echo "$inspector_out" | grep -qi "linux"; then
        OS_TYPE="linux"
    else
        OS_TYPE="unknown"
    fi

    # Parse version
    OS_VERSION=$(echo "$inspector_out" | grep -oP '<version>\K[^<]+' | head -1 || true)

    # Parse architecture
    local arch
    arch=$(echo "$inspector_out" | grep -oP '<arch>\K[^<]+' | head -1 || true)
    [[ -z "$arch" ]] && arch="unknown"

    # Detect boot mode from partition table
    if echo "$inspector_out" | grep -qP '<partition_table>\s*gpt\s*</partition_table>'; then
        OS_PARTITION_TABLE="gpt"
        OS_BOOT_MODE="uefi"
    elif echo "$inspector_out" | grep -qP '<partition_table>\s*mbr\s*</partition_table>'; then
        OS_PARTITION_TABLE="mbr"
        OS_BOOT_MODE="bios"
    fi

    # Check for EFI System Partition
    if echo "$inspector_out" | grep -qP '<partition[^>]*>.*?<type>efi</type>.*?</partition>'; then
        OS_HAS_ESP="true"
    fi

    if [[ "$OS_TYPE" == "unknown" ]]; then
        return 1
    fi
    return 0
}

### Function: _detect_via_partition_types
# Internal fallback that detects OS details from partition table heuristics.
#
# Arguments:
#   $1 - Path to the disk image.
#   $2 - Disk image format (default: "raw"). Non-raw formats (e.g. qcow2)
#        are exposed read-only via qemu-nbd when available.
#
# Globals (set by this function):
#   OS_TYPE, OS_DISTRO, OS_BOOT_MODE,
#   OS_PARTITION_TABLE, OS_HAS_ESP
#
# Returns:
#   0 on success (even if OS_TYPE remains "unknown"), 1 if fdisk/parted unavailable.
_detect_via_partition_types() {
    local disk_path="$1"
    local img_format="${2:-raw}"
    local fdisk_out=""
    local file_out=""

    # We need fdisk or parted
    if ! command -v fdisk &>/dev/null && ! command -v parted &>/dev/null; then
        return 1
    fi

    # Non-raw images (e.g. qcow2) cannot be read by fdisk/file directly —
    # expose them read-only through qemu-nbd when available.
    local probe_path="$disk_path" nbd_dev=""
    if [[ "$img_format" != "raw" ]]; then
        command -v qemu-nbd &>/dev/null || return 1
        modprobe nbd max_part=8 2>/dev/null || true
        local i
        for i in $(seq 0 15); do
            if [[ -b "/dev/nbd${i}" && ! -e "/sys/block/nbd${i}/pid" ]]; then
                nbd_dev="/dev/nbd${i}"
                break
            fi
        done
        [[ -n "$nbd_dev" ]] || return 1
        qemu-nbd -r -c "$nbd_dev" "$disk_path" 2>/dev/null || return 1
        probe_path="$nbd_dev"
        # Give the kernel a moment to notice the partition table
        sleep 1
        partprobe "$nbd_dev" 2>/dev/null || true
    fi

    # --- Probe phase (needs a readable block device) ---
    if command -v fdisk &>/dev/null; then
        fdisk_out=$(fdisk -l "$probe_path" 2>/dev/null || true)
    fi

    local part1="" ntfs_probe=false
    if [[ -n "$fdisk_out" ]]; then
        part1=$(echo "$fdisk_out" | grep -E '^/dev/' | head -1 || true)

        if [[ -n "$part1" ]] && command -v file &>/dev/null; then
            file_out=$(file -sL "$probe_path" 2>/dev/null || true)
        fi

        # Pre-probe for NTFS while the device is still attached
        if echo "$fdisk_out" | grep -qiE "EFI|EF00" && command -v ntfscluster &>/dev/null; then
            if ntfscluster "$probe_path" &>/dev/null || \
               ntfscluster "${probe_path}p1" &>/dev/null || \
               ntfscluster "${probe_path}1" &>/dev/null; then
                ntfs_probe=true
            fi
        fi
    fi

    if [[ -n "$nbd_dev" ]]; then
        qemu-nbd -d "$nbd_dev" 2>/dev/null || true
    fi

    [[ -z "$fdisk_out" ]] && return 1

    # --- Evaluation phase ---
    # Check for GPT
    if echo "$fdisk_out" | grep -qi "gpt"; then
        OS_PARTITION_TABLE="gpt"
        OS_BOOT_MODE="uefi"
        # Look for EFI System Partition (type EF00 or "EFI System")
        if echo "$fdisk_out" | grep -qiE "EFI|EF00"; then
            OS_HAS_ESP="true"
        fi
    elif echo "$fdisk_out" | grep -qi "dos"; then
        OS_PARTITION_TABLE="mbr"
        OS_BOOT_MODE="bios"
    fi

    # Check first partition filesystem type
    if [[ -n "$part1" && -n "$file_out" ]]; then
        if echo "$file_out" | grep -qiE "ntfs|windows"; then
            OS_TYPE="windows"
            OS_DISTRO="windows"
        elif echo "$file_out" | grep -qiE "ext[234]|xfs|btrfs|linux"; then
            OS_TYPE="linux"
        fi
    fi

    # If still unknown but GPT with ESP, use the NTFS probe result
    if [[ "$OS_TYPE" == "unknown" && "$OS_HAS_ESP" == "true" && "$ntfs_probe" == "true" ]]; then
        OS_TYPE="windows"
        OS_DISTRO="windows"
    fi

    return 0
}
