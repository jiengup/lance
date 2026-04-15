#!/bin/bash
set -euo pipefail

# Rebuilds the unique active release branch from the latest source branch tip
# while keeping the release branch on its existing prerelease version line.
#
# Usage: retarget_active_release.sh [source_branch] [tag_prefix]
# Example: retarget_active_release.sh main

SOURCE_BRANCH=${1:-main}
TAG_PREFIX=${2:-"v"}

readonly SELF_DIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

source "${SELF_DIR}/release_common.sh"

echo "Retargeting active release branch from source branch: ${SOURCE_BRANCH}"

git fetch --tags origin \
    "refs/heads/${SOURCE_BRANCH}:refs/remotes/origin/${SOURCE_BRANCH}" \
    "refs/heads/release/*:refs/remotes/origin/release/*"

SOURCE_REF="origin/${SOURCE_BRANCH}"
if ! git rev-parse "${SOURCE_REF}" >/dev/null 2>&1; then
    echo "ERROR: Source branch ${SOURCE_BRANCH} does not exist on origin"
    exit 1
fi

ACTIVE_RELEASE_BRANCH=$(find_active_release_branch origin "${TAG_PREFIX}")
ACTIVE_RELEASE_REF="origin/${ACTIVE_RELEASE_BRANCH}"

PREVIOUS_HEAD=$(git rev-parse "${ACTIVE_RELEASE_REF}")
SOURCE_SHA=$(git rev-parse "${SOURCE_REF}")
RELEASE_VERSION=$(get_version_from_cargo_ref "${ACTIVE_RELEASE_REF}")

validate_release_branch_version "${ACTIVE_RELEASE_BRANCH}" "${RELEASE_VERSION}"

echo "Active release branch: ${ACTIVE_RELEASE_BRANCH}"
echo "Previous release head: ${PREVIOUS_HEAD}"
echo "Source branch head: ${SOURCE_SHA}"
echo "Retaining release version: ${RELEASE_VERSION}"

git checkout --detach "${SOURCE_REF}"

SOURCE_VERSION=$(get_version_from_cargo)
echo "Source branch version: ${SOURCE_VERSION}"

if [ "${SOURCE_VERSION}" != "${RELEASE_VERSION}" ]; then
    echo "Rewriting source version ${SOURCE_VERSION} -> ${RELEASE_VERSION}"
    bump-my-version bump -vv --new-version "${RELEASE_VERSION}" --no-tag patch
    update_lockfiles
else
    echo "Source branch already uses ${RELEASE_VERSION}"
fi

if ! git diff --quiet; then
    git add -A
    git commit -m "chore: retarget ${ACTIVE_RELEASE_BRANCH} to ${SOURCE_BRANCH}

Source: ${SOURCE_SHA}
Release version: ${RELEASE_VERSION}"
fi

TARGET_SHA=$(git rev-parse HEAD)
echo "Retargeted branch head: ${TARGET_SHA}"

OUTPUT_FILE=${GITHUB_OUTPUT:-/dev/null}
echo "ACTIVE_RELEASE_BRANCH=${ACTIVE_RELEASE_BRANCH}" >> "${OUTPUT_FILE}" 2>/dev/null || true
echo "PREVIOUS_HEAD=${PREVIOUS_HEAD}" >> "${OUTPUT_FILE}" 2>/dev/null || true
echo "SOURCE_BRANCH=${SOURCE_BRANCH}" >> "${OUTPUT_FILE}" 2>/dev/null || true
echo "SOURCE_SHA=${SOURCE_SHA}" >> "${OUTPUT_FILE}" 2>/dev/null || true
echo "RELEASE_VERSION=${RELEASE_VERSION}" >> "${OUTPUT_FILE}" 2>/dev/null || true
echo "TARGET_SHA=${TARGET_SHA}" >> "${OUTPUT_FILE}" 2>/dev/null || true
