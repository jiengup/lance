#!/bin/bash
set -euo pipefail

readonly REPO_ROOT=$(cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd)

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

assert_eq() {
    local EXPECTED=$1
    local ACTUAL=$2
    local MESSAGE=$3
    if [ "${EXPECTED}" != "${ACTUAL}" ]; then
        fail "${MESSAGE}: expected '${EXPECTED}', got '${ACTUAL}'"
    fi
}

assert_file_contains() {
    local PATHNAME=$1
    local PATTERN=$2
    if ! grep -q "${PATTERN}" "${PATHNAME}"; then
        fail "${PATHNAME} does not contain pattern: ${PATTERN}"
    fi
}

write_version_files() {
    local VERSION=$1

    cat > Cargo.toml <<EOF
[workspace]
members = ["python", "java/lance-jni"]

[workspace.package]
version = "${VERSION}"
EOF

    cat > .bumpversion.toml <<EOF
[tool.bumpversion]
current_version = "${VERSION}"
parse = "(?P<major>\\\\d+)\\\\.(?P<minor>\\\\d+)\\\\.(?P<patch>\\\\d+)(-(?P<prerelease>(beta|rc))\\\\.(?P<prerelease_num>\\\\d+))?"
serialize = [
    "{major}.{minor}.{patch}-{prerelease}.{prerelease_num}",
    "{major}.{minor}.{patch}"
]
search = "{current_version}"
replace = "{new_version}"
regex = false
ignore_missing_files = false
ignore_missing_version = false
tag = false
commit = false

[[tool.bumpversion.files]]
filename = "Cargo.toml"
search = 'version = "{current_version}"'
replace = 'version = "{new_version}"'

[[tool.bumpversion.files]]
filename = "python/Cargo.toml"
search = 'version = "{current_version}"'
replace = 'version = "{new_version}"'

[[tool.bumpversion.files]]
filename = "java/lance-jni/Cargo.toml"
search = 'version = "{current_version}"'
replace = 'version = "{new_version}"'

[[tool.bumpversion.files]]
filename = "java/pom.xml"
search = "<version>{current_version}</version>"
replace = "<version>{new_version}</version>"
EOF

    mkdir -p python java/lance-jni
    cat > python/Cargo.toml <<EOF
[package]
name = "python"
version = "${VERSION}"
EOF

    cat > java/lance-jni/Cargo.toml <<EOF
[package]
name = "lance-jni"
version = "${VERSION}"
EOF

    cat > java/pom.xml <<EOF
<project>
  <version>${VERSION}</version>
</project>
EOF
}

init_repo() {
    local TARGET_DIR=$1
    local ORIGIN_DIR=$2

    mkdir -p "${TARGET_DIR}"
    cd "${TARGET_DIR}"
    git init -b main >/dev/null
    git config user.name "Test User"
    git config user.email "test@example.com"

    write_version_files "5.0.0-beta.6"
    echo "base" > feature.txt
    git add .
    git commit -m "base release line" >/dev/null
    git tag -a v5.0.0-beta.6 -m "v5.0.0-beta.6" >/dev/null

    git checkout -b release/v5.0 >/dev/null
    write_version_files "5.0.0-rc.1"
    git add .
    git commit -m "release candidate" >/dev/null
    git tag -a v5.0.0-rc.1 -m "v5.0.0-rc.1" >/dev/null

    git checkout main >/dev/null
    write_version_files "5.1.0-beta.3"
    echo "main" > feature.txt
    echo "new data" > main-only.txt
    git add .
    git commit -m "main diverges" >/dev/null

    git init --bare "${ORIGIN_DIR}" >/dev/null
    git remote add origin "${ORIGIN_DIR}"
    git push origin main release/v5.0 --tags >/dev/null
}

test_retarget_preserves_release_version_and_imports_main() {
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "${TMP_DIR}"' RETURN

    init_repo "${TMP_DIR}/seed" "${TMP_DIR}/origin.git"

    git clone "${TMP_DIR}/origin.git" "${TMP_DIR}/work" >/dev/null
    cd "${TMP_DIR}/work"
    git config user.name "Test User"
    git config user.email "test@example.com"

    LANCE_RELEASE_SKIP_LOCK_UPDATE=1 bash "${REPO_ROOT}/ci/retarget_active_release.sh" main >/dev/null

    assert_eq "5.0.0-rc.1" "$(grep '^version = ' Cargo.toml | head -n1 | cut -d'"' -f2)" "root Cargo.toml version"
    assert_file_contains ".bumpversion.toml" 'current_version = "5.0.0-rc.1"'
    assert_file_contains "python/Cargo.toml" 'version = "5.0.0-rc.1"'
    assert_file_contains "java/lance-jni/Cargo.toml" 'version = "5.0.0-rc.1"'
    assert_file_contains "java/pom.xml" '<version>5.0.0-rc.1</version>'
    assert_eq "new data" "$(cat main-only.txt)" "main-only file should be present"
    assert_eq "main" "$(cat feature.txt)" "main content should be retained"
    assert_eq "chore: retarget release/v5.0 to main" "$(git log -1 --format=%s)" "retarget commit subject"

    local DIFF_FILES
    DIFF_FILES=$(git diff --name-only origin/main..HEAD | sort)
    assert_eq $'.bumpversion.toml\nCargo.toml\njava/lance-jni/Cargo.toml\njava/pom.xml\npython/Cargo.toml' "${DIFF_FILES}" "retarget diff against main"
}

test_stable_release_branch_is_not_active() {
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "${TMP_DIR}"' RETURN

    mkdir -p "${TMP_DIR}/seed"
    cd "${TMP_DIR}/seed"
    git init -b main >/dev/null
    git config user.name "Test User"
    git config user.email "test@example.com"

    write_version_files "4.1.0-rc.1"
    git add .
    git commit -m "seed" >/dev/null
    git checkout -b release/v4.1 >/dev/null
    git commit --allow-empty -m "release branch" >/dev/null
    git tag -a v4.1.0 -m "stable" >/dev/null
    git checkout main >/dev/null

    git init --bare "${TMP_DIR}/origin.git" >/dev/null
    git remote add origin "${TMP_DIR}/origin.git"
    git push origin main release/v4.1 --tags >/dev/null

    git clone "${TMP_DIR}/origin.git" "${TMP_DIR}/work" >/dev/null
    cd "${TMP_DIR}/work"
    git config user.name "Test User"
    git config user.email "test@example.com"

    set +e
    OUTPUT=$(LANCE_RELEASE_SKIP_LOCK_UPDATE=1 bash "${REPO_ROOT}/ci/retarget_active_release.sh" main 2>&1)
    STATUS=$?
    set -e

    if [ "${STATUS}" -eq 0 ]; then
        fail "retarget_active_release.sh should fail when no active release branch exists"
    fi

    if ! echo "${OUTPUT}" | grep -q "Expected exactly one active release branch"; then
        fail "unexpected failure output: ${OUTPUT}"
    fi
}

test_retarget_preserves_release_version_and_imports_main
test_stable_release_branch_is_not_active

echo "retarget_active_release.sh tests passed"
