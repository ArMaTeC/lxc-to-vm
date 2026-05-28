#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# OS Detection Library
# Version: 1.0.0
# ==============================================================================
#
# DESCRIPTION:
#   Detects the guest operating system inside a VM disk image or block device.
#   Supports Linux and Windows detection via libguestfs inspection and
#   fallback heuristics.
#
# USAGE:
#   source "$(dirname "$0")/lib/common.sh"
#   lib_source "os-detect.sh"
#   detect_os_from_disk "/path/to/disk.qcow2"
#
# OUTPUT (sets global variables):
#   OS_TYPE          - linux, windows, unknown
#   OS_DISTRO        - debian, ubuntu, alpine, rhel, arch, windows, unknown
#   OS_VERSION       - version string (e.g., "22.04", "11", "2022")
#   OS_BOOT_MODE     - bios, uefi, unknown
#   OS_PARTITION_TABLE - mbr, gpt, unknown
#   OS_HAS_ESP       - true, false
#
# LICENSE: MIT
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# OS Detection from Disk Image
# ------------------------------------------------------------------------------
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
    _detect_via_partition_types "$disk_path" && return 0

    return 1
}

# ------------------------------------------------------------------------------
# libguestfs-based detection (most reliable)
# ------------------------------------------------------------------------------
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
    if echo "$inspector_out" | grep -qP '<partition[^>]*>.*?<partitions>.*?<type>efi</type>'; then
        OS_HAS_ESP="true"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Fallback: partition type heuristics
# ------------------------------------------------------------------------------
_detect_via_partition_types() {
    local disk_path="$1"
    local fdisk_out=""
    local file_out=""

    # We need fdisk or parted
    if ! command -v fdisk &>/dev/null && ! command -v parted &>/dev/null; then
        return 1
    fi

    # Try to get partition table info
    if command -v fdisk &>/dev/null; then
        fdisk_out=$(fdisk -l "$disk_path" 2>/dev/null || true)
    fi

    [[ -z "$fdisk_out" ]] && return 1

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
    local part1=""
    part1=$(echo "$fdisk_out" | grep -E '^/dev/' | head -1 || true)
    if [[ -n "$part1" ]]; then
        # Try file -sL on the disk path itself or the partition device
        if command -v file &>/dev/null; then
            file_out=$(file -sL "$disk_path" 2>/dev/null || true)
        fi

        if [[ -n "$file_out" ]]; then
            if echo "$file_out" | grep -qiE "ntfs|windows"; then
                OS_TYPE="windows"
                OS_DISTRO="windows"
            elif echo "$file_out" | grep -qiE "ext[234]|xfs|btrfs|linux"; then
                OS_TYPE="linux"
            fi
        fi
    fi

    # If still unknown but GPT with ESP, try ntfs-3g probe as last resort
    if [[ "$OS_TYPE" == "unknown" && "$OS_HAS_ESP" == "true" ]]; then
        if command -v ntfscluster &>/dev/null; then
            if ntfscluster "$disk_path" &>/dev/null || \
               ntfscluster "${disk_path}p1" &>/dev/null 2>/dev/null || \
               ntfscluster "${disk_path}1" &>/dev/null 2>/dev/null; then
                OS_TYPE="windows"
                OS_DISTRO="windows"
            fi
        fi
    fi

    return 0
}
