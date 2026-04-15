#!/bin/bash

# Common functions for release scripts

# Gets the current version from Cargo.toml
# Returns: version string (e.g., "1.3.0-beta.1")
get_version_from_cargo() {
    grep '^version = ' Cargo.toml | head -n1 | cut -d'"' -f2
}

# Gets the version from Cargo.toml at a git ref
# Args: GIT_REF
# Returns: version string (e.g., "1.3.0-beta.1")
get_version_from_cargo_ref() {
    local GIT_REF=$1
    git show "${GIT_REF}:Cargo.toml" | grep '^version = ' | head -n1 | cut -d'"' -f2
}

# Parses version components from a version string
# Args: VERSION_STRING
# Returns: three values separated by spaces: MAJOR MINOR PATCH
# Example: parse_version_components "1.3.0-rc.2" returns "1 3 0"
parse_version_components() {
    local VERSION=$1
    local MAJOR=$(echo "${VERSION}" | cut -d. -f1 | sed 's/^v//')
    local MINOR=$(echo "${VERSION}" | cut -d. -f2)
    local PATCH=$(echo "${VERSION}" | cut -d. -f3 | cut -d- -f1)
    echo "${MAJOR} ${MINOR} ${PATCH}"
}

# Updates lockfiles after a version rewrite.
# Set LANCE_RELEASE_SKIP_LOCK_UPDATE=1 to skip this in tests.
update_lockfiles() {
    if [ "${LANCE_RELEASE_SKIP_LOCK_UPDATE:-0}" = "1" ]; then
        echo "Skipping lockfile updates because LANCE_RELEASE_SKIP_LOCK_UPDATE=1"
        return
    fi

    cargo update
    (cd python && cargo update)
    (cd java/lance-jni && cargo update)
}

# Bumps version and commits the change
# Args: NEW_VERSION COMMIT_MESSAGE
bump_and_commit_version() {
    local NEW_VERSION=$1
    local COMMIT_MESSAGE=$2

    bump-my-version bump -vv --new-version "${NEW_VERSION}" --no-tag patch

    # Update Cargo.lock files after version bump
    update_lockfiles

    git add -A
    git commit -m "${COMMIT_MESSAGE}"
}

# Lists release branches from a remote.
# Args: [REMOTE]
list_release_branches() {
    local REMOTE=${1:-origin}
    git for-each-ref --format='%(refname:short)' "refs/remotes/${REMOTE}/release/*" \
        | sed "s#^${REMOTE}/##"
}

# Returns 0 if the release branch has already published its stable X.Y.0 tag.
# Args: RELEASE_BRANCH [TAG_PREFIX]
release_branch_has_stable_tag() {
    local RELEASE_BRANCH=$1
    local TAG_PREFIX=${2:-"v"}

    if [[ ! "${RELEASE_BRANCH}" =~ ^release/v([0-9]+)\.([0-9]+)$ ]]; then
        echo "ERROR: Invalid release branch name: ${RELEASE_BRANCH}" >&2
        return 2
    fi

    local MAJOR="${BASH_REMATCH[1]}"
    local MINOR="${BASH_REMATCH[2]}"
    git rev-parse "${TAG_PREFIX}${MAJOR}.${MINOR}.0" >/dev/null 2>&1
}

# Finds the unique active release branch on a remote.
# An active release branch is a release/vX.Y branch whose stable vX.Y.0 tag does not exist yet.
# Args: [REMOTE] [TAG_PREFIX]
# Returns: branch name (e.g. release/v5.0)
find_active_release_branch() {
    local REMOTE=${1:-origin}
    local TAG_PREFIX=${2:-"v"}
    local ACTIVE_BRANCHES=()
    local RELEASE_BRANCH

    while IFS= read -r RELEASE_BRANCH; do
        [ -z "${RELEASE_BRANCH}" ] && continue
        if ! release_branch_has_stable_tag "${RELEASE_BRANCH}" "${TAG_PREFIX}"; then
            ACTIVE_BRANCHES+=("${RELEASE_BRANCH}")
        fi
    done < <(list_release_branches "${REMOTE}")

    if [ "${#ACTIVE_BRANCHES[@]}" -ne 1 ]; then
        echo "ERROR: Expected exactly one active release branch, found ${#ACTIVE_BRANCHES[@]}: ${ACTIVE_BRANCHES[*]-}" >&2
        return 1
    fi

    echo "${ACTIVE_BRANCHES[0]}"
}

# Validates that a prerelease version belongs to a release branch line and remains on the RC/Beta track.
# Args: RELEASE_BRANCH VERSION
validate_release_branch_version() {
    local RELEASE_BRANCH=$1
    local VERSION=$2

    if [[ ! "${RELEASE_BRANCH}" =~ ^release/v([0-9]+)\.([0-9]+)$ ]]; then
        echo "ERROR: Invalid release branch name: ${RELEASE_BRANCH}" >&2
        return 1
    fi

    local EXPECTED_MAJOR="${BASH_REMATCH[1]}"
    local EXPECTED_MINOR="${BASH_REMATCH[2]}"

    if [[ ! "${VERSION}" =~ ^([0-9]+)\.([0-9]+)\.0-(beta|rc)\.([0-9]+)$ ]]; then
        echo "ERROR: Release branch version must stay on the prerelease track: ${VERSION}" >&2
        return 1
    fi

    local VERSION_MAJOR="${BASH_REMATCH[1]}"
    local VERSION_MINOR="${BASH_REMATCH[2]}"

    if [ "${EXPECTED_MAJOR}" != "${VERSION_MAJOR}" ] || [ "${EXPECTED_MINOR}" != "${VERSION_MINOR}" ]; then
        echo "ERROR: Version ${VERSION} does not match release branch ${RELEASE_BRANCH}" >&2
        return 1
    fi
}

# Determines the previous tag for release notes comparison
# Args: MAJOR MINOR PATCH [TAG_PREFIX]
# Returns: previous tag name or empty string
#
# For major/minor releases (PATCH=0):
#   - Checks for minor-release-root tag (minor release from release branch)
#   - Otherwise uses release-root tag (standard flow from main)
# For patch releases (PATCH>0):
#   - Compares against previous patch stable tag
determine_previous_tag() {
    local MAJOR=$1
    local MINOR=$2
    local PATCH=$3
    local TAG_PREFIX=${4:-"v"}

    if [ "${PATCH}" = "0" ]; then
        # Major/Minor release: check for minor-release-root tag first
        # This tag is created when a minor release is cut from a release branch
        local MINOR_RELEASE_ROOT_TAG="minor-release-root/${MAJOR}.${MINOR}.0"
        if git rev-parse "${MINOR_RELEASE_ROOT_TAG}" >/dev/null 2>&1; then
            # Read the source tag from the tag message
            local SOURCE_TAG=$(git tag -l --format='%(contents:subject)' "${MINOR_RELEASE_ROOT_TAG}")
            if [ -n "${SOURCE_TAG}" ]; then
                echo "${SOURCE_TAG}"
                return
            fi
        fi

        # Standard flow: use release-root tag
        local RELEASE_ROOT_TAG="release-root/${MAJOR}.${MINOR}.${PATCH}-beta.N"
        if git rev-parse "${RELEASE_ROOT_TAG}" >/dev/null 2>&1; then
            echo "${RELEASE_ROOT_TAG}"
        else
            echo ""
        fi
    else
        # Patch release: compare against previous stable tag
        local PREV_PATCH=$((PATCH - 1))
        local PREV_TAG="${TAG_PREFIX}${MAJOR}.${MINOR}.${PREV_PATCH}"
        if git rev-parse "${PREV_TAG}" >/dev/null 2>&1; then
            echo "${PREV_TAG}"
        else
            echo ""
        fi
    fi
}
