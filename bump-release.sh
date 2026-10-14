#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: bump-release.sh
# Description: Bump a script's VERSION constant, rotate the CHANGELOG
#              [Unreleased] section, commit, tag vX.Y.Z, and push — which
#              triggers the GitHub release workflow (.github/workflows/release.yml).
# License: MIT
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bump a script's VERSION, update CHANGELOG.md, commit, tag, and push to
trigger the GitHub release workflow.

Options:
  -s, --script <FILE>   Script whose readonly VERSION to bump (default: lxc-to-vm.sh)
  -t, --type <TYPE>     Bump type: patch | minor | major (default: patch)
  -v, --version <VER>   Set an explicit version X.Y.Z (overrides --type)
  -m, --notes <TEXT>    Release notes appended to the commit/tag message
      --no-tag          Commit the bump but do not create a git tag
      --no-push         Commit/tag locally but do not push
  -n, --dry-run         Show what would be done without making changes
  -h, --help            Show this help message

Examples:
  $(basename "$0")                          # patch bump on lxc-to-vm.sh, tag + push
  $(basename "$0") -t minor -m "New flags"  # minor bump with release notes
  $(basename "$0") -s shrink-lxc.sh -v 6.0.7 --no-push
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------------
SCRIPT_FILE="lxc-to-vm.sh"
BUMP_TYPE="patch"
NEW_VERSION=""
NOTES=""
DO_TAG=true DO_PUSH=true DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--script)  SCRIPT_FILE="$2";  shift 2 ;;
        -t|--type)    BUMP_TYPE="$2";    shift 2 ;;
        -v|--version) NEW_VERSION="$2";  shift 2 ;;
        -m|--notes)   NOTES="$2";        shift 2 ;;
        --no-tag)     DO_TAG=false;      shift ;;
        --no-push)    DO_PUSH=false;     shift ;;
        -n|--dry-run) DRY_RUN=true;      shift ;;
        -h|--help)    usage ;;
        *)            die "Unknown option: $1 (use --help)" ;;
    esac
done

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
cd "$(dirname "$0")"

[[ -f "$SCRIPT_FILE" ]] || die "Script not found: $SCRIPT_FILE"
[[ -f "CHANGELOG.md" ]] || die "CHANGELOG.md not found (run from repo root)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] || die "Detached HEAD — check out a branch first."

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Working tree has uncommitted changes. Commit or stash them first."
fi

CURRENT_VERSION="$(grep -m1 'readonly VERSION="' "$SCRIPT_FILE" | sed 's/.*readonly VERSION="\([^"]*\)".*/\1/')"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Could not parse readonly VERSION in $SCRIPT_FILE (got: '$CURRENT_VERSION')"

# Compute new version
if [[ -z "$NEW_VERSION" ]]; then
    IFS=. read -r v_major v_minor v_patch <<< "$CURRENT_VERSION"
    case "$BUMP_TYPE" in
        patch) NEW_VERSION="${v_major}.${v_minor}.$((v_patch + 1))" ;;
        minor) NEW_VERSION="${v_major}.$((v_minor + 1)).0" ;;
        major) NEW_VERSION="$((v_major + 1)).0.0" ;;
        *)     die "Invalid bump type: '$BUMP_TYPE' (use patch|minor|major)" ;;
    esac
fi
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid version: '$NEW_VERSION' (expected X.Y.Z)"

TAG="v${NEW_VERSION}"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    die "Tag ${TAG} already exists."
fi

log "Script:   $SCRIPT_FILE"
log "Version:  $CURRENT_VERSION -> $NEW_VERSION"
log "Branch:   $BRANCH"
log "Tag:      $TAG$($DO_TAG || printf ' (skipped)')"
log "Push:     $DO_PUSH"
$DRY_RUN && { log "Dry run — no changes made."; exit 0; }

# ------------------------------------------------------------------------------
# Apply
# ------------------------------------------------------------------------------
sed -i "0,/readonly VERSION=\"${CURRENT_VERSION}\"/s//readonly VERSION=\"${NEW_VERSION}\"/" "$SCRIPT_FILE"
bash -n "$SCRIPT_FILE" || die "Syntax check failed on $SCRIPT_FILE after version bump."

# Rotate CHANGELOG: promote [Unreleased] to the new version, keep a fresh
# empty Unreleased section on top. If no Unreleased section exists, insert the
# new version heading before the first release entry.
RELEASE_DATE="$(date +%Y-%m-%d)"
if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    sed -i "s|^## \[Unreleased\]|## [Unreleased]\n\n## [${NEW_VERSION}] - ${RELEASE_DATE}|" CHANGELOG.md
elif grep -q '^## \[' CHANGELOG.md; then
    sed -i "0,/^## \[/s//## [${NEW_VERSION}] - ${RELEASE_DATE}\n\n## [/" CHANGELOG.md
else
    warn "No versioned section found in CHANGELOG.md — update it manually."
fi

git add "$SCRIPT_FILE" CHANGELOG.md
git commit -m "Release ${TAG}${NOTES:+ - ${NOTES}}"

if $DO_TAG; then
    git tag -a "$TAG" -m "Release ${TAG}${NOTES:+ - ${NOTES}}"
fi

if $DO_PUSH; then
    git push origin "$BRANCH"
    $DO_TAG && git push origin "$TAG"
    log "Pushed ${BRANCH} and ${TAG} — GitHub Actions will create the release."
else
    log "Done locally. Push with: git push origin ${BRANCH} && git push origin ${TAG}"
fi
