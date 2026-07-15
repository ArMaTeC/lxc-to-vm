#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: add-file-headers.sh
# Description: Automatically adds, detects, and replaces file headers across
#              the project. Supports --dry-run and --check modes.
# License: MIT
# ==============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly VERSION="1.0.0"
readonly LOG_FILE="/var/log/add-file-headers.log"
readonly MARKER="### lxc-to-vm file header ###"

# Whitelist of file extensions to process
readonly SUPPORTED_EXTS=(
    sh bash md yml yaml ps1 txt cfg conf
)

# Specific filenames (no extension) to process
readonly SUPPORTED_NAMES=(
    .gitignore Makefile Dockerfile
)

# Directories to skip
readonly SKIP_DIRS=(
    .git node_modules .specify .windsurf .github
)

# ============================================================================
# Helper Functions
# ============================================================================

### Function: usage
# Display usage information and exit.
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automatically add or replace file headers across the project.

Options:
  --dry-run    Preview changes without writing to disk
  --check      Report files needing updates; exit 1 if any found
  --help       Show this help message

Exit Codes:
  0  Success (or --check: all files up-to-date)
  1  General error or --check found outdated headers
  2  Invalid argument
EOF
}

### Function: die
# Print a fatal error message and exit.
#
# Arguments:
#   $1 - Error message.
#   $2 - Exit code (default: 1).
die() {
    echo "ERROR: $1" >&2
    log_msg "FATAL: $1"
    exit "${2:-1}"
}

### Function: log_msg
# Append a timestamped message to the script log file.
#
# Arguments:
#   $1 - Message text.
log_msg() {
    local msg="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Ensure log directory exists
    if [[ -d "$(dirname "$LOG_FILE")" ]]; then
        printf '%s [%s] %s\n' "$timestamp" "$(basename "$0")" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

### Function: array_contains
# Check whether a value exists in an array.
#
# Arguments:
#   $1 - Value to search for.
#   $@ - Array elements (after the value).
#
# Returns:
#   0 if the value is found; 1 otherwise.
array_contains() {
    local value="$1"
    shift
    for item; do
        [[ "$item" == "$value" ]] && return 0
    done
    return 1
}

### Function: is_binary
# Determine whether a file appears to be binary.
#
# Arguments:
#   $1 - Path to the file.
#
# Returns:
#   0 if binary; 1 if text or indeterminate.
is_binary() {
    local file="$1"
    if command -v file >/dev/null 2>&1; then
        local ftype
        ftype=$(file -b --mime-type "$file" 2>/dev/null || true)
        [[ "$ftype" != text/* && "$ftype" != application/json ]] && return 0
    fi
    # Fallback: detect null bytes in first 4KB
    if grep -qP '\x00' "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

### Function: get_comment_style
# Determine the appropriate comment style for a file.
#
# Arguments:
#   $1 - Path to the file.
#
# Outputs:
#   "hash", "html", or "none" to stdout.
get_comment_style() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")
    local ext="${basename_file##*.}"

    # If no extension, check against known names
    if [[ "$basename_file" == "$ext" ]]; then
        array_contains "$basename_file" "${SUPPORTED_NAMES[@]}" && echo "hash" || echo "none"
        return
    fi

    case "$ext" in
        md) echo "html" ;;
        sh|bash|yml|yaml|ps1|txt|cfg|conf)
            echo "hash"
            ;;
        *) echo "none" ;;
    esac
}

### Function: generate_description
# Generate a short description string for a file.
#
# Arguments:
#   $1 - Path to the file.
#
# Outputs:
#   Description string to stdout.
#
# Notes:
#   First tries to extract an existing Description field, then falls back to
#   a hardcoded map of known files, and finally generates one from the filename.
generate_description() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")
    local name_no_ext="${basename_file%.*}"

    # Try to extract from existing comments (first 30 lines)
    local extracted=""
    extracted=$(grep -iE '^[#<![:space:]-]*[[:space:]]*[dD][eE][sS][cC][rR][iI][pP][tT][iI][oO][nN][[:space:]]*[:=][[:space:]]*' "$file" 2>/dev/null | head -1 || true)
    if [[ -n "$extracted" ]]; then
        # Strip comment markers and "Description:" prefix
        extracted=$(printf '%s' "$extracted" | sed -E 's/^[#<![:space:]-]*//; s/^[dD][eE][sS][cC][rR][iI][pP][tT][iI][oO][nN][[:space:]]*[:=][[:space:]]*//; s/[[:space:]]+$//')
        if [[ -n "$extracted" ]]; then
            printf '%s' "$extracted"
            return
        fi
    fi

    # Hardcoded descriptions for known project files
    case "$basename_file" in
        lxc-to-vm.sh)     echo "Converts Proxmox LXC containers to KVM virtual machines" ;;
        vm-to-lxc.sh)     echo "Converts KVM virtual machines to Proxmox LXC containers" ;;
        shrink-lxc.sh)    echo "Optimizes and shrinks LXC container disk usage" ;;
        expand-lxc.sh)    echo "Expands LXC container disk size with multiple modes" ;;
        shrink-vm.sh)     echo "Shrinks VM disk images to usage plus headroom" ;;
        expand-vm.sh)     echo "Expands VM disk size with hot-expand support" ;;
        clone-replace-disk.sh) echo "Clones and replaces disks to fix expansion issues" ;;
        test-remote-pve.sh)    echo "Automated remote PVE test helper for conversions" ;;
        test-remote-pve.ps1)   echo "PowerShell remote PVE test helper for conversions" ;;
        README.md)        echo "Project documentation and usage guide" ;;
        CHANGELOG.md)     echo "Version history and release notes" ;;
        CONTRIBUTING.md)  echo "Contribution guidelines for the project" ;;
        LICENSE)          echo "MIT License text" ;;
        SECURITY.md)      echo "Security policy and vulnerability reporting" ;;
        *)
            # Generate from filename
            local desc="$name_no_ext"
            desc="${desc//-/ }"
            desc="${desc//_/ }"
            # Capitalize first letter
            desc="$(tr '[:lower:]' '[:upper:]' <<< "${desc:0:1}")${desc:1}"
            echo "$desc"
            ;;
    esac
}

### Function: generate_header
# Render the standardized file header block.
#
# Arguments:
#   $1 - Path to the file (used to determine the filename).
#   $2 - Comment style ("hash" or "html").
#   $3 - Description text.
#
# Outputs:
#   Header block to stdout.
generate_header() {
    local file="$1"
    local style="$2"
    local description="$3"
    local basename_file
    basename_file=$(basename "$file")

    if [[ "$style" == "hash" ]]; then
        cat <<EOF
# ==============================================================================
# ${MARKER}
# File: ${basename_file}
# Description: ${description}
# License: MIT
# ==============================================================================
EOF
    elif [[ "$style" == "html" ]]; then
        cat <<EOF
<!-- ==============================================================================
     ${MARKER}
     File: ${basename_file}
     Description: ${description}
     License: MIT
     ============================================================================== -->
EOF
    fi
}

### Function: process_file
# Add or update the standardized header in a single file.
#
# Arguments:
#   $1 - Path to the file.
#   $2 - Dry-run flag (1 = preview only).
#   $3 - Check-mode flag (1 = report, do not modify).
#
# Returns:
#   0 if the file was skipped or is up-to-date; 1 if it was/would be updated.
process_file() {
    local file="$1"
    local dry_run="$2"
    local check_mode="$3"

    local style
    style=$(get_comment_style "$file")
    [[ "$style" == "none" ]] && return 0

    if is_binary "$file"; then
        log_msg "SKIP (binary): $file"
        return 0
    fi

    # Quick check: does file already have our marker?
    if grep -qF "$MARKER" "$file" 2>/dev/null; then
        return 0
    fi

    if [[ "$check_mode" -eq 1 ]]; then
        echo "NEEDS UPDATE: $file"
        return 1
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo "[DRY-RUN] Would update: $file"
        return 1
    fi

    # Actually perform the update
    local description
    description=$(generate_description "$file")
    local header
    header=$(generate_header "$file" "$style" "$description")

    # Create new file content
    local newfile
    newfile=$(mktemp)

    {
        # Print prefix lines (shebang, shellcheck, etc.)
        awk -v style="$style" '
        BEGIN { state = "prefix" }
        state == "prefix" {
            if ($0 ~ /^#!/) { print; next }
            if ($0 ~ /^#[ \t]*shellcheck/) { print; next }
            if ($0 ~ /^#[ \t]*-[*]-/) { print; next }
            state = "done"
        }
        ' "$file"

        # Print new header
        printf '%s\n' "$header"

        # Print body (skip prefix and old header)
        awk -v style="$style" '
        BEGIN { state = "prefix" }
        state == "prefix" {
            if ($0 ~ /^#!/) { next }
            if ($0 ~ /^#[ \t]*shellcheck/) { next }
            if ($0 ~ /^#[ \t]*-[*]-/) { next }
            state = "header"
        }
        state == "header" {
            if (style == "hash" && $0 ~ /^#/) { next }
            if (style == "html" && $0 ~ /^<!--/) {
                if ($0 ~ /-->/ ) { next }
                state = "html_header"
                next
            }
            state = "body"
        }
        state == "html_header" {
            if ($0 ~ /-->/ ) { state = "body"; next }
            next
        }
        state == "body" { print }
        ' "$file"
    } > "$newfile"

    mv "$newfile" "$file"
    log_msg "Updated header in: $file"
    return 1
}

# ============================================================================
# Main
# ============================================================================

main() {
    local dry_run=0
    local check_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --check)
                check_mode=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Invalid argument: $1" 2
                ;;
        esac
    done

    # Validate mutually exclusive modes
    if [[ "$dry_run" -eq 1 && "$check_mode" -eq 1 ]]; then
        die "--dry-run and --check are mutually exclusive" 2
    fi

    log_msg "Starting add-file-headers.sh v${VERSION} (dry_run=${dry_run}, check=${check_mode})"

    local updated_count=0
    local skip_count=0

    # Build find exclusion arguments
    local find_excludes=()
    for dir in "${SKIP_DIRS[@]}"; do
        find_excludes+=( -not -path "*/${dir}/*" )
    done

    # Discover and process files
    while IFS= read -r -d '' file; do
        local basename_file
        basename_file=$(basename "$file")
        local ext="${basename_file##*.}"

        # Check if file extension or name is supported
        local supported=0
        if [[ "$basename_file" != "$ext" ]]; then
            array_contains "$ext" "${SUPPORTED_EXTS[@]}" && supported=1
        else
            array_contains "$basename_file" "${SUPPORTED_NAMES[@]}" && supported=1
        fi

        [[ "$supported" -eq 0 ]] && continue

        # Process the file
        if process_file "$file" "$dry_run" "$check_mode"; then
            ((skip_count++)) || true
        else
            ((updated_count++)) || true
        fi
    done < <(find . -type f "${find_excludes[@]}" -print0 2>/dev/null)

    log_msg "Finished: ${updated_count} updated, ${skip_count} skipped"

    if [[ "$check_mode" -eq 1 ]]; then
        if [[ "$updated_count" -gt 0 ]]; then
            echo ""
            echo "${updated_count} file(s) need header updates."
            exit 1
        else
            echo "All file headers are up-to-date."
            exit 0
        fi
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo ""
        echo "${updated_count} file(s) would be updated, ${skip_count} skipped."
    else
        echo ""
        echo "Done: ${updated_count} file(s) updated, ${skip_count} skipped."
    fi
}

main "$@"
