#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: bump-release.sh
# Description: Bump the readonly VERSION of every script changed since the last
#              release tag, rotate the CHANGELOG [Unreleased] section, commit,
#              tag vX.Y.Z, and push — which triggers the GitHub release
#              workflow (.github/workflows/release.yml).
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

Bump the readonly VERSION of every script changed since the last v* release
tag, update CHANGELOG.md, commit, tag, and push to trigger the GitHub
release workflow.

Options:
  -t, --type <TYPE>     Bump type: patch | minor | major (default: patch)
  -v, --version <VER>   Set an explicit version X.Y.Z (overrides --type)
  -m, --notes <TEXT>    Release notes appended to the commit/tag message
      --all             Bump every script with a VERSION constant, not just
                        those changed since the last release tag
      --no-tag          Commit the bump but do not create a git tag
      --no-push         Commit/tag locally but do not push
  -n, --dry-run         Show what would be done without making changes
  -h, --help            Show this help message

Examples:
  $(basename "$0")                          # patch bump on all changed scripts
  $(basename "$0") -t minor -m "New flags"  # minor bump with release notes
  $(basename "$0") --all -v 6.2.0 --no-push
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------------
BUMP_TYPE="patch"
NEW_VERSION=""
NOTES=""
BUMP_ALL=false DO_TAG=true DO_PUSH=true DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)    BUMP_TYPE="$2";    shift 2 ;;
        -v|--version) NEW_VERSION="$2";  shift 2 ;;
        -m|--notes)   NOTES="$2";        shift 2 ;;
        --all)        BUMP_ALL=true;     shift ;;
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

[[ -f "CHANGELOG.md" ]] || die "CHANGELOG.md not found (run from repo root)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] || die "Detached HEAD — check out a branch first."

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Working tree has uncommitted changes. Commit or stash them first."
fi

# Latest repo release tag (tags are repo-wide, so this is the release line).
LATEST_TAG_VERSION="$(git tag -l 'v*' | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
LAST_TAG=""
[[ -n "$LATEST_TAG_VERSION" ]] && LAST_TAG="v${LATEST_TAG_VERSION}"

# ------------------------------------------------------------------------------
# Scripts to bump: files changed since the last release that carry a
# readonly VERSION constant (or all such files with --all / first release).
# ------------------------------------------------------------------------------
mapfile -t CANDIDATE_FILES < <(
    if $BUMP_ALL || [[ -z "$LAST_TAG" ]]; then
        git ls-files
    else
        git diff --name-only "${LAST_TAG}..HEAD"
    fi
)

BUMP_FILES=()
for f in "${CANDIDATE_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q 'readonly VERSION="[0-9]\+\.[0-9]\+\.[0-9]\+"' "$f"; then
        BUMP_FILES+=("$f")
    fi
done

if [[ ${#BUMP_FILES[@]} -eq 0 ]]; then
    if $BUMP_ALL || [[ -z "$LAST_TAG" ]]; then
        die "No scripts with a readonly VERSION constant found."
    fi
    warn "No VERSION-bearing files changed since ${LAST_TAG}."
    warn "Nothing to bump. Use --all to bump every script, or release anyway? Aborting."
    exit 1
fi

# Bump base = highest of the latest tag and the VERSION of every script being
# bumped, so a script ahead of the tag line is never downgraded by a release.
BASE_VERSION="${LATEST_TAG_VERSION:-0.0.0}"
declare -A OLD_VERSIONS=()
for f in "${BUMP_FILES[@]}"; do
    OLD_VERSIONS[$f]="$(grep -m1 'readonly VERSION="' "$f" | sed 's/.*readonly VERSION="\([^"]*\)".*/\1/')"
    BASE_VERSION="$(printf '%s\n%s\n' "$BASE_VERSION" "${OLD_VERSIONS[$f]}" | sort -V | tail -1)"
done

# Compute new version
if [[ -z "$NEW_VERSION" ]]; then
    IFS=. read -r v_major v_minor v_patch <<< "$BASE_VERSION"
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

log "Last tag: ${LAST_TAG:-none}"
log "Bump:     $BUMP_TYPE  (base: $BASE_VERSION -> $NEW_VERSION)"
log "Tag:      $TAG$($DO_TAG || printf ' (skipped)')"
log "Push:     $DO_PUSH"
log "Branch:   $BRANCH"
log "Scripts:"
for f in "${BUMP_FILES[@]}"; do
    log "  $f  ${OLD_VERSIONS[$f]} -> $NEW_VERSION"
done
$DRY_RUN && { log "Dry run — no changes made."; exit 0; }

# ------------------------------------------------------------------------------
# Apply
# ------------------------------------------------------------------------------
for f in "${BUMP_FILES[@]}"; do
    sed -i "s/readonly VERSION=\"[0-9]\+\.[0-9]\+\.[0-9]\+\"/readonly VERSION=\"${NEW_VERSION}\"/" "$f"
    case "$f" in
        *.sh|*.bash) bash -n "$f" || die "Syntax check failed on $f after version bump." ;;
    esac
done

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

git add "${BUMP_FILES[@]}" CHANGELOG.md
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
