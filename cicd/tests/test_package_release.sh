#!/usr/bin/env bash
# ==============================================================================
# Test Suite: cicd/tests/test_package_release.sh
# Purpose: Comprehensive validation of scripts/package_release.sh:
#          - CLI argument and version sanitization
#          - Node.js 24 runtime fail-closed guard
#          - End-to-end production build & release packaging
#          - SHA-256 sidecar syntax and integrity
#          - Dual-naming hardlink regular file compatibility
#          - Archive member isolation (no devDependencies, .git, .env, src)
#          - release-manifest.json schema compliance (no archiveSha256)
#          - Full end-to-end verification via application::release_manager.py
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE_SCRIPT="${PROJECT_ROOT}/scripts/package_release.sh"
RELEASE_MGR="${PROJECT_ROOT}/puppet/modules/application/files/release_manager.py"

PASSED_COUNT=0
TOTAL_COUNT=10

echo "=============================================================================="
echo "Running Test Suite: Application Release Packaging Validation"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Script existence and execution permission
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Script existence and executable permission... "
test -f "${PACKAGE_SCRIPT}"
test -x "${PACKAGE_SCRIPT}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Version parameter and argument parsing validation
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Parameter validation (missing, traversal, illegal chars)... "
export PACKAGE_SCRIPT

python3 - << 'EOF'
import os, subprocess

script = os.environ['PACKAGE_SCRIPT']

bad_args_list = [
    ([], "Missing version argument"),
    (["-v"], "Missing version flag value"),
    (["--output-dir"], "Missing output dir value"),
    (["../1.0.0"], "Path traversal version"),
    (["1.0.0/bad"], "Slash in version"),
    (["1.0.0;rm -rf /"], "Shell metacharacters in version"),
    (["-1.0.0"], "Leading hyphen in version"),
    (["1.0.0..1"], "Double dot in version"),
]

for args, label in bad_args_list:
    res = subprocess.run([script] + args, capture_output=True, text=True)
    assert res.returncode != 0, f"Expected non-zero exit for '{label}', got rc=0"

# --help should succeed with 0
help_res = subprocess.run([script, "--help"], capture_output=True, text=True)
assert help_res.returncode == 0, f"Expected rc=0 for --help, got {help_res.returncode}"
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Node.js 24 fail-closed runtime guard
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Fail-closed guard on incompatible Node.js version... "
python3 - << 'EOF'
import os, subprocess, tempfile

script = os.environ['PACKAGE_SCRIPT']

with tempfile.TemporaryDirectory() as tmpdir:
    mock_node = os.path.join(tmpdir, "node")
    with open(mock_node, "w") as f:
        f.write("#!/bin/sh\necho 'v22.14.0'\n")
    os.chmod(mock_node, 0o755)

    env = os.environ.copy()
    env["PATH"] = f"{tmpdir}:{env['PATH']}"

    res = subprocess.run([script, "-v", "1.0.0", "--skip-build"], env=env, capture_output=True, text=True)
    assert res.returncode != 0, f"Expected failure with mock Node v22, got rc={res.returncode}"
    assert "Incompatible Node.js version" in res.stderr or "Node.js 24 is strictly required" in res.stderr, (
        f"Unexpected error message: {res.stderr}"
    )
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Packaging execution with real production build
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] End-to-end package creation for release 1.0.0-ci... "
TEST_SANDBOX="$(mktemp -d -t gra-test-pkg-XXXXXX)"
trap 'rm -rf "${TEST_SANDBOX}"' EXIT INT TERM

TEST_OUTPUT="${TEST_SANDBOX}/dist-release"
TEST_VERSION="1.0.0-ci"

"${PACKAGE_SCRIPT}" -v "${TEST_VERSION}" -o "${TEST_OUTPUT}" > "${TEST_SANDBOX}/package.log" 2>&1
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Dual archive creation & hardlink regular file verification
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Verification of dual naming, regular file status, and hardlinks... "
PRIMARY_ARCHIVE="${TEST_OUTPUT}/git-repo-analyzer-release-${TEST_VERSION}.tar.gz"
PRIMARY_SIDECAR="${PRIMARY_ARCHIVE}.sha256"
COMPAT_ARCHIVE="${TEST_OUTPUT}/${TEST_VERSION}.tar.gz"
COMPAT_SIDECAR="${COMPAT_ARCHIVE}.sha256"

test -f "${PRIMARY_ARCHIVE}"
test -f "${PRIMARY_SIDECAR}"
test -f "${COMPAT_ARCHIVE}"
test -f "${COMPAT_SIDECAR}"

# release_manager.py strictly requires that the archive is NOT a symlink: os.path.islink() must be False
test ! -L "${PRIMARY_ARCHIVE}"
test ! -L "${COMPAT_ARCHIVE}"

# Verify hardlink: both files share the same inode number
INODE_PRIMARY="$(stat -c %i "${PRIMARY_ARCHIVE}")"
INODE_COMPAT="$(stat -c %i "${COMPAT_ARCHIVE}")"
if [[ "${INODE_PRIMARY}" -ne "${INODE_COMPAT}" ]]; then
    echo "FAILED (primary and compat archive inodes do not match: ${INODE_PRIMARY} != ${INODE_COMPAT})" >&2
    exit 1
fi
echo "PASS (both archives are regular files sharing inode ${INODE_PRIMARY})"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Checksum format and verification
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] SHA-256 sidecar format and sha256sum -c --strict verification... "
(
    cd "${TEST_OUTPUT}"
    sha256sum -c --strict "git-repo-analyzer-release-${TEST_VERSION}.tar.gz.sha256" >/dev/null
    sha256sum -c --strict "${TEST_VERSION}.tar.gz.sha256" >/dev/null
)

# Verify single non-empty line format
LINE_COUNT_PRI="$(grep -c . "${PRIMARY_SIDECAR}")"
LINE_COUNT_CMP="$(grep -c . "${COMPAT_SIDECAR}")"
if [[ "${LINE_COUNT_PRI}" -ne 1 || "${LINE_COUNT_CMP}" -ne 1 ]]; then
    echo "FAILED (sidecars must have exactly 1 non-empty line)" >&2
    exit 1
fi
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Archive member structure and content boundaries
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Tar member hierarchy and isolation checks... "
EXTRACT_DIR="${TEST_SANDBOX}/extracted"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${PRIMARY_ARCHIVE}" -C "${EXTRACT_DIR}"

# Check required files
test -f "${EXTRACT_DIR}/release-manifest.json"
test -f "${EXTRACT_DIR}/backend/dist/server.js"
test -f "${EXTRACT_DIR}/backend/package.json"
test -f "${EXTRACT_DIR}/backend/package-lock.json"
test -d "${EXTRACT_DIR}/backend/node_modules"
test -f "${EXTRACT_DIR}/frontend/dist/index.html"

# Verify production dependencies present
test -d "${EXTRACT_DIR}/backend/node_modules/express"
test -d "${EXTRACT_DIR}/backend/node_modules/cors"
test -d "${EXTRACT_DIR}/backend/node_modules/zod"

# Verify devDependencies excluded
test ! -d "${EXTRACT_DIR}/backend/node_modules/typescript"
test ! -d "${EXTRACT_DIR}/backend/node_modules/vitest"
test ! -d "${EXTRACT_DIR}/backend/node_modules/@types"

# Verify forbidden paths excluded
test ! -e "${EXTRACT_DIR}/backend/src"
test ! -e "${EXTRACT_DIR}/backend/test"
test ! -e "${EXTRACT_DIR}/backend/.git"
test ! -e "${EXTRACT_DIR}/frontend/src"
test ! -e "${EXTRACT_DIR}/frontend/test"
test ! -e "${EXTRACT_DIR}/frontend/.git"
if find "${EXTRACT_DIR}" -name ".env*" -o -name ".git" | grep -q .; then
    echo "FAILED (forbidden development/secret artifacts found in extracted archive)" >&2
    exit 1
fi

# Verify frontend contains nothing outside dist/
NON_DIST="$(find "${EXTRACT_DIR}/frontend" -maxdepth 1 ! -name "frontend" ! -name "dist")"
if [[ -n "${NON_DIST}" ]]; then
    echo "FAILED (extraneous frontend paths found outside dist/: ${NON_DIST})" >&2
    exit 1
fi
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. release-manifest.json semantic validation
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] release-manifest.json schema and forbidden key checks... "
MANIFEST_PATH="${EXTRACT_DIR}/release-manifest.json"
python3 - << EOF
import json, re

with open("${MANIFEST_PATH}", "r") as f:
    manifest = json.load(f)

assert manifest.get("appName") == "git-repo-analyzer", f"Bad appName: {manifest.get('appName')}"
assert manifest.get("releaseId") == "${TEST_VERSION}", f"Bad releaseId: {manifest.get('releaseId')}"
assert manifest.get("gitCommit") and manifest.get("gitCommit") != "", "gitCommit must be non-empty"
assert manifest.get("builtAtUtc") and manifest.get("builtAtUtc") != "", "builtAtUtc must be non-empty"
assert re.match(r"^v?24(\.|$)", manifest.get("nodeVersion", "")), f"Incompatible nodeVersion: {manifest.get('nodeVersion')}"

# release_manager.py line 533 explicitly forbids self-referential 'archiveSha256'
assert "archiveSha256" not in manifest, "Forbidden self-referential 'archiveSha256' found in release-manifest.json"
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Full integration with application::release_manager.py
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Direct validation via release_manager.py extraction and inspection... "
python3 - << EOF
import os, sys, tempfile, shutil

sys.path.insert(0, os.path.abspath("${PROJECT_ROOT}/puppet/modules/application/files"))
import release_manager

with tempfile.TemporaryDirectory() as sandbox:
    staging = os.path.join(sandbox, "staging")
    os.makedirs(staging, exist_ok=True)

    # Copy compat archive and sidecar into staging
    shutil.copy("${COMPAT_ARCHIVE}", staging)
    shutil.copy("${COMPAT_SIDECAR}", staging)

    sidecar_path = os.path.join(staging, "${TEST_VERSION}.tar.gz.sha256")
    with open(sidecar_path, "r") as f:
        expected_sha = f.read().split()[0]

    # Test 9a: verify_sidecar_and_checksum
    verified_archive = release_manager.verify_sidecar_and_checksum(staging, "${TEST_VERSION}", expected_sha)
    assert verified_archive == os.path.join(staging, "${TEST_VERSION}.tar.gz")

    # Test 9b: validate_and_extract_archive
    extract_target = os.path.join(sandbox, "release-root")
    manifest = release_manager._validate_and_extract_archive(verified_archive, "${TEST_VERSION}", extract_target)
    assert manifest["releaseId"] == "${TEST_VERSION}"

    # Test 9c: permission tree application without root chown
    release_manager._apply_permissions_tree(
        release_root=extract_target,
        backend_owner="unused",
        backend_group="unused",
        frontend_owner="unused",
        frontend_group="unused",
        apply_chown=False
    )
EOF
echo "PASS (release_manager.py verified and extracted release cleanly)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Repeat packaging with --skip-build flag
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Packaging with --skip-build flag... "
SKIP_OUTPUT="${TEST_SANDBOX}/dist-skip"
"${PACKAGE_SCRIPT}" -v "1.0.1-fast" -o "${SKIP_OUTPUT}" --skip-build > "${TEST_SANDBOX}/skip.log" 2>&1
test -f "${SKIP_OUTPUT}/git-repo-analyzer-release-1.0.1-fast.tar.gz"
test -f "${SKIP_OUTPUT}/1.0.1-fast.tar.gz"
(
    cd "${SKIP_OUTPUT}"
    sha256sum -c --strict "1.0.1-fast.tar.gz.sha256" >/dev/null
)
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "All ${PASSED_COUNT}/${TOTAL_COUNT} Application Release Packaging Tests PASSED"
echo "=============================================================================="
