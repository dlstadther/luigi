#!/usr/bin/env bash
set -euo pipefail

# Release automation script for Luigi
# Usage:
#   ./scripts/release.sh prepare <patch|minor|major> [remote]
#   ./scripts/release.sh tag
#   ./scripts/release.sh publish

VERSION_FILE="luigi/__version__.py"
PYPI_PACKAGE="luigi"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}==>${NC} $*"; }
success() { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
error()   { echo -e "${RED}==> ERROR:${NC} $*" >&2; exit 1; }

# --- Helper functions ---

check_tool() {
    local tool="$1"
    local install_hint="${2:-}"
    if ! command -v "$tool" &>/dev/null; then
        error "'$tool' is not installed.${install_hint:+ Install: $install_hint}"
    fi
}

current_version() {
    local version
    version=$(grep -E '^VERSION *= *"[0-9]+\.[0-9]+\.[0-9]+"' "$VERSION_FILE" \
        | sed -E 's/^VERSION *= *"([0-9]+\.[0-9]+\.[0-9]+)"/\1/')
    if [[ -z "$version" ]]; then
        error "Could not parse version from $VERSION_FILE"
    fi
    echo "$version"
}

next_version() {
    local current="$1"
    local bump="$2"

    local major minor patch
    IFS='.' read -r major minor patch <<< "$current"

    case "$bump" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *) error "Invalid BUMP value '$bump'. Must be one of: patch, minor, major" ;;
    esac
}

confirm() {
    local prompt="$1"
    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi
    echo -en "${YELLOW}${prompt} [y/N]${NC} "
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
}

check_clean_tree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        error "Working tree is not clean. Commit or stash your changes first."
    fi
}

check_on_master() {
    local branch
    branch=$(git branch --show-current)
    if [[ "$branch" != "master" ]]; then
        error "Must be on 'master' branch (currently on '$branch')."
    fi
}

# --- Subcommands ---

cmd_prepare() {
    local bump="${1:-}"
    local remote="${2:-origin}"

    # Validate BUMP arg
    if [[ -z "$bump" ]]; then
        error "BUMP argument is required. Usage: make release-prepare BUMP=<patch|minor|major>"
    fi
    if [[ "$bump" != "patch" && "$bump" != "minor" && "$bump" != "major" ]]; then
        error "Invalid BUMP value '$bump'. Must be one of: patch, minor, major"
    fi

    # Check prerequisites
    check_tool "uv" "https://github.com/astral-sh/uv"
    check_tool "gh" "https://cli.github.com"
    check_on_master
    check_clean_tree

    # Ensure master is up-to-date
    info "Fetching latest from '$remote'..."
    git fetch "$remote" master
    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse "$remote/master")
    if [[ "$local_sha" != "$remote_sha" ]]; then
        error "Local master ($local_sha) is not up-to-date with $remote/master ($remote_sha). Run 'git pull' first."
    fi

    # Compute version
    local current new_version branch_name
    current=$(current_version)
    new_version=$(next_version "$current" "$bump")
    branch_name="release/${new_version}"

    info "Current version: $current"
    info "Next version:    $new_version ($bump bump)"
    info "Release branch:  $branch_name"
    echo

    # Check for branch collision
    if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        error "Local branch '$branch_name' already exists. Delete it first: git branch -D $branch_name"
    fi
    if git ls-remote --exit-code "$remote" "refs/heads/$branch_name" &>/dev/null; then
        error "Remote branch '$branch_name' already exists on '$remote'. Delete it first: git push $remote --delete $branch_name"
    fi

    # Create branch
    info "Creating branch '$branch_name'..."
    git checkout -b "$branch_name"

    # Update version file (portable across macOS and Linux)
    info "Updating $VERSION_FILE to $new_version..."
    local tmp_file
    tmp_file=$(mktemp)
    sed -E "s/^(VERSION *= *\")([0-9]+\.[0-9]+\.[0-9]+)(\")/\1${new_version}\3/" "$VERSION_FILE" > "$tmp_file"
    mv "$tmp_file" "$VERSION_FILE"

    # Verify the update
    local written_version
    written_version=$(current_version)
    if [[ "$written_version" != "$new_version" ]]; then
        error "Version file update failed. Expected '$new_version', got '$written_version'."
    fi

    # Commit
    info "Committing version bump..."
    git add "$VERSION_FILE"
    git commit -m "Version ${new_version}"

    # Push
    info "Pushing '$branch_name' to '$remote'..."
    git push -u "$remote" "$branch_name"

    # Open PR
    info "Creating pull request..."
    local pr_body
    pr_body=$(cat <<EOF
## Release ${new_version}

Bumps version from ${current} to ${new_version} (${bump}).

## Post-Merge Checklist

- [ ] Run \`make release-tag\` to create a GitHub Release with auto-generated notes
- [ ] Run \`make release-publish\` to build and upload to PyPI
EOF
)
    gh pr create \
        --title "Version ${new_version}" \
        --body "$pr_body" \
        --base master \
        --head "$branch_name"

    echo
    success "Release ${new_version} prepared!"
    info "Next steps:"
    info "  1. Review and merge the PR"
    info "  2. Run 'make release-tag' to create a GitHub Release"
    info "  3. Run 'make release-publish' to publish to PyPI"
}

cmd_tag() {
    # Check prerequisites
    check_tool "gh" "https://cli.github.com"
    check_on_master
    check_clean_tree

    # Auto-fetch and pull
    info "Fetching latest and pulling master..."
    git fetch --tags
    git pull

    # Read version
    local version
    version=$(current_version)
    info "Version from $VERSION_FILE: $version"

    # Check tag doesn't already exist
    if git tag -l "$version" | grep -q "^${version}$"; then
        error "Tag '$version' already exists. GitHub Release may already have been created."
    fi

    # Create GitHub Release with auto-generated notes
    info "Creating GitHub Release for $version..."
    gh release create "$version" \
        --title "$version" \
        --generate-notes \
        --target master

    echo
    success "GitHub Release $version created!"
    info "Next step: Run 'make release-publish' to publish to PyPI"
}

cmd_publish() {
    # Check prerequisites
    check_tool "uv" "https://github.com/astral-sh/uv"

    if [[ -z "${UV_PUBLISH_TOKEN:-}" ]]; then
        error "UV_PUBLISH_TOKEN is not set. Export your PyPI token: export UV_PUBLISH_TOKEN=\"your-token\""
    fi

    # Auto-fetch and pull
    info "Fetching latest tags and pulling master..."
    git fetch --tags
    git pull

    # Validate state
    check_on_master
    check_clean_tree

    # Check master is up-to-date
    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse origin/master 2>/dev/null || git rev-parse upstream/master 2>/dev/null)
    if [[ "$local_sha" != "$remote_sha" ]]; then
        error "Local master is not up-to-date with remote. This should not happen after 'git pull'."
    fi

    # Read version
    local version
    version=$(current_version)
    info "Version from $VERSION_FILE: $version"

    # Check tag exists
    if ! git tag -l "$version" | grep -q "^${version}$"; then
        error "Git tag '$version' not found. Create a GitHub Release with tag '$version' (no 'v' prefix) first."
    fi

    # Verify tag matches version
    local tag_sha head_sha
    tag_sha=$(git rev-list -n 1 "$version" 2>/dev/null || true)
    head_sha=$(git rev-parse HEAD)
    # The tag should point to HEAD or to the merge commit containing the version bump
    # We check that the tagged commit is an ancestor of (or equal to) HEAD
    if [[ -n "$tag_sha" ]] && ! git merge-base --is-ancestor "$tag_sha" HEAD 2>/dev/null && [[ "$tag_sha" != "$head_sha" ]]; then
        warn "Tag '$version' ($tag_sha) does not point to HEAD ($head_sha) and is not an ancestor of HEAD."
    fi

    # Check PyPI
    if [[ "${FORCE:-0}" != "1" ]]; then
        info "Checking if $PYPI_PACKAGE $version already exists on PyPI..."
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://pypi.org/pypi/${PYPI_PACKAGE}/${version}/json" || true)
        if [[ "$http_code" == "200" ]]; then
            error "Version $version already exists on PyPI. If this is a retry after partial upload, use FORCE=1."
        fi
    else
        warn "Skipping PyPI existence check (FORCE=1)."
    fi

    # Build
    info "Cleaning dist/..."
    rm -rf dist

    info "Building with uv..."
    uv build

    # Confirm
    echo
    info "Ready to publish:"
    info "  Package: $PYPI_PACKAGE"
    info "  Version: $version"
    info "  Files:"
    ls -1 dist/ | sed 's/^/    /'
    echo
    confirm "Publish to PyPI?"

    # Publish
    info "Publishing to PyPI..."
    uv publish

    echo
    success "Luigi $version published to PyPI!"
    info "https://pypi.org/project/${PYPI_PACKAGE}/${version}/"
}

# --- Main ---

case "${1:-}" in
    prepare) shift; cmd_prepare "$@" ;;
    tag)     shift; cmd_tag "$@" ;;
    publish) shift; cmd_publish "$@" ;;
    *)
        echo "Usage: $0 <prepare|tag|publish>"
        echo
        echo "Commands:"
        echo "  prepare <patch|minor|major> [remote]   Bump version, create branch, PR"
        echo "  tag                                     Create GitHub Release with auto-generated notes"
        echo "  publish                                 Validate, build, publish to PyPI"
        echo
        echo "Examples:"
        echo "  $0 prepare minor              # Bump minor version, push to origin"
        echo "  $0 prepare patch upstream      # Bump patch version, push to upstream"
        echo "  $0 tag                         # Create GitHub Release for current version"
        echo "  FORCE=1 $0 publish             # Publish, skipping PyPI existence check"
        exit 1
        ;;
esac
