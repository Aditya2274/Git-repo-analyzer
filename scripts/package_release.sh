#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/package_release.sh
# Purpose: Reproducible, secure release packager for Git Repository Analyzer.
#          Builds React frontend and Node.js backend, isolates production
#          dependencies, generates release-manifest.json, and produces a
#          hardlink-compatible tar.gz archive and SHA-256 sidecar checksums
#          fully verified by puppet/modules/application/files/release_manager.py.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
OUTPUT_DIR="${PROJECT_ROOT}/dist-release"
SKIP_BUILD=false

usage() {
    cat << 'EOF'
Usage: scripts/package_release.sh [OPTIONS] <VERSION>
       scripts/package_release.sh -v <VERSION> [-o <OUTPUT_DIR>] [--skip-build]

Options:
  -v, --version <VERSION>      Release version identifier (e.g., 1.0.0, v1.0.0)
  -o, --output-dir <DIR>       Destination directory for release artifacts
                               (default: <PROJECT_ROOT>/dist-release)
  -s, --skip-build             Skip 'npm run build' if builds are already current
  -h, --help                   Display this help message and exit

Description:
  Automates production packaging for the React frontend and Node.js backend.
  Validates Node.js 24 runtime, executes production builds, isolates production
  dependencies via 'npm ci --omit=dev' into a clean staging tree, generates
  release-manifest.json conforming to release_manager.py specifications, and
  creates standard archives and SHA-256 sidecars:
    - git-repo-analyzer-release-<VERSION>.tar.gz
    - git-repo-analyzer-release-<VERSION>.tar.gz.sha256
    - <VERSION>.tar.gz (hardlinked regular file for Puppet staging compatibility)
    - <VERSION>.tar.gz.sha256
EOF
    exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# 1. Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                echo "Error: Argument '$1' requires a version value." >&2
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        -o|--output-dir)
            if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                echo "Error: Argument '$1' requires a directory path." >&2
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -s|--skip-build)
            SKIP_BUILD=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Error: Unrecognized option '$1'" >&2
            usage 1
            ;;
        *)
            if [[ -z "${VERSION}" ]]; then
                VERSION="$1"
                shift
            else
                echo "Error: Unexpected positional argument '$1'" >&2
                usage 1
            fi
            ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    echo "Error: Missing required release version." >&2
    usage 1
fi

# ------------------------------------------------------------------------------
# 2. Validate Version String
# ------------------------------------------------------------------------------
# Version must match Puppet / release_manager.py regex: ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
# and must not contain directory traversal sequences (..)
if [[ ! "${VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || [[ "${VERSION}" == *".."* ]]; then
    echo "Error: Invalid release version '${VERSION}'." >&2
    echo "Version must match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' and must not contain '..'" >&2
    exit 1
fi

echo "=============================================================================="
echo " Packaging Git Repository Analyzer Release: ${VERSION}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 3. Environment & Prerequisites Validation
# ------------------------------------------------------------------------------
echo "--- Validating environment prerequisites ---"

# Node.js availability and version 24 check
if ! command -v node >/dev/null 2>&1; then
    echo "Error: 'node' command not found in PATH. Node.js 24 is required." >&2
    exit 1
fi

NODE_RAW_VERSION="$(node -v 2>/dev/null || true)"
if [[ ! "${NODE_RAW_VERSION}" =~ ^v?24(\.|$) ]]; then
    echo "Error: Incompatible Node.js version '${NODE_RAW_VERSION}'. Node.js 24 is strictly required." >&2
    exit 1
fi
echo "  [OK] Node.js version: ${NODE_RAW_VERSION}"

# npm availability
if ! command -v npm >/dev/null 2>&1; then
    echo "Error: 'npm' command not found in PATH." >&2
    exit 1
fi
NPM_RAW_VERSION="$(npm -v 2>/dev/null || true)"
echo "  [OK] npm version: ${NPM_RAW_VERSION}"

# System utilities
for tool in tar sha256sum git; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Error: Required utility '${tool}' not found in PATH." >&2
        exit 1
    fi
done
echo "  [OK] System tools (tar, sha256sum, git) available"

# Project structure and manifests
for req_path in \
    "${PROJECT_ROOT}/backend/package.json" \
    "${PROJECT_ROOT}/backend/package-lock.json" \
    "${PROJECT_ROOT}/frontend/package.json" \
    "${PROJECT_ROOT}/frontend/package-lock.json"; do
    if [[ ! -f "${req_path}" ]]; then
        echo "Error: Required package manifest '${req_path}' not found." >&2
        exit 1
    fi
done
echo "  [OK] Project manifests verified"

# ------------------------------------------------------------------------------
# 4. Production Compilation
# ------------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" == "false" ]]; then
    echo "--- Executing production builds ---"
    echo "  Building backend (npm --prefix backend run build)..."
    npm --prefix "${PROJECT_ROOT}/backend" run build
    echo "  Building frontend (npm --prefix frontend run build)..."
    npm --prefix "${PROJECT_ROOT}/frontend" run build
else
    echo "--- Skipping production builds (--skip-build specified) ---"
fi

# Verify build outputs
if [[ ! -f "${PROJECT_ROOT}/backend/dist/server.js" ]]; then
    echo "Error: Backend build output '${PROJECT_ROOT}/backend/dist/server.js' not found." >&2
    exit 1
fi
if [[ ! -s "${PROJECT_ROOT}/backend/dist/server.js" ]]; then
    echo "Error: Backend build output '${PROJECT_ROOT}/backend/dist/server.js' is empty." >&2
    exit 1
fi

if [[ ! -f "${PROJECT_ROOT}/frontend/dist/index.html" ]]; then
    echo "Error: Frontend build output '${PROJECT_ROOT}/frontend/dist/index.html' not found." >&2
    exit 1
fi
if [[ ! -s "${PROJECT_ROOT}/frontend/dist/index.html" ]]; then
    echo "Error: Frontend build output '${PROJECT_ROOT}/frontend/dist/index.html' is empty." >&2
    exit 1
fi
echo "  [OK] Build outputs verified"

# ------------------------------------------------------------------------------
# 5. Staging Tree Assembly
# ------------------------------------------------------------------------------
echo "--- Assembling release staging tree ---"

STAGING_PARENT="$(mktemp -d -t gra-release-staging-XXXXXX)"
cleanup() {
    rm -rf "${STAGING_PARENT}"
}
trap cleanup EXIT INT TERM

BUNDLE_ROOT="${STAGING_PARENT}/bundle"
mkdir -p "${BUNDLE_ROOT}/backend" "${BUNDLE_ROOT}/frontend"

# 5a. Assemble backend
echo "  Staging backend artifacts..."
cp "${PROJECT_ROOT}/backend/package.json" "${BUNDLE_ROOT}/backend/package.json"
cp "${PROJECT_ROOT}/backend/package-lock.json" "${BUNDLE_ROOT}/backend/package-lock.json"
cp -r "${PROJECT_ROOT}/backend/dist" "${BUNDLE_ROOT}/backend/dist"

echo "  Installing backend production dependencies (npm ci --omit=dev)..."
(
    cd "${BUNDLE_ROOT}/backend"
    npm ci --omit=dev --no-audit --no-fund --ignore-scripts >/dev/null
)

# 5b. Assemble frontend
echo "  Staging frontend production assets..."
cp -r "${PROJECT_ROOT}/frontend/dist" "${BUNDLE_ROOT}/frontend/dist"

# 5c. Generate release-manifest.json
echo "  Generating release-manifest.json..."
GIT_COMMIT="$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Note: release_manager.py strictly forbids 'archiveSha256' key inside release-manifest.json
cat > "${BUNDLE_ROOT}/release-manifest.json" << EOF
{
  "appName": "git-repo-analyzer",
  "releaseId": "${VERSION}",
  "gitCommit": "${GIT_COMMIT}",
  "builtAtUtc": "${BUILT_AT}",
  "nodeVersion": "${NODE_RAW_VERSION}"
}
EOF

# ------------------------------------------------------------------------------
# 6. Safety & Boundary Audit on Staging Tree
# ------------------------------------------------------------------------------
echo "--- Performing safety & boundary checks on staged bundle ---"

# Verify required files
for req in \
    "${BUNDLE_ROOT}/release-manifest.json" \
    "${BUNDLE_ROOT}/backend/dist/server.js" \
    "${BUNDLE_ROOT}/backend/package.json" \
    "${BUNDLE_ROOT}/backend/package-lock.json" \
    "${BUNDLE_ROOT}/frontend/dist/index.html"; do
    if [[ ! -f "${req}" ]]; then
        echo "Error: Required release file '${req}' is missing from staging bundle." >&2
        exit 1
    fi
done

if [[ ! -d "${BUNDLE_ROOT}/backend/node_modules" ]]; then
    echo "Error: Required directory 'backend/node_modules' is missing from staging bundle." >&2
    exit 1
fi

# Reject forbidden development or sensitive artifacts matching release_manager.py rules
# release_manager.py explicitly forbids backend/.env*, backend/.git*, backend/src, backend/test
for forbidden in \
    "${BUNDLE_ROOT}/backend/src" \
    "${BUNDLE_ROOT}/backend/test" \
    "${BUNDLE_ROOT}/backend/tests" \
    "${BUNDLE_ROOT}/backend/.git" \
    "${BUNDLE_ROOT}/frontend/src" \
    "${BUNDLE_ROOT}/frontend/test" \
    "${BUNDLE_ROOT}/frontend/.git"; do
    if [[ -e "${forbidden}" ]]; then
        echo "Error: Forbidden development path detected in release staging: ${forbidden}" >&2
        exit 1
    fi
done

# Ensure no .env* secret files or .git repository trees anywhere in the bundle
FORBIDDEN_FILES="$(find "${BUNDLE_ROOT}" -name ".env*" -o -name ".git" 2>/dev/null || true)"
if [[ -n "${FORBIDDEN_FILES}" ]]; then
    echo "Error: Sensitive or repository artifacts detected in staging: ${FORBIDDEN_FILES}" >&2
    exit 1
fi

# Reject frontend paths outside dist/
NON_DIST_FRONTEND="$(find "${BUNDLE_ROOT}/frontend" -maxdepth 1 ! -name "frontend" ! -name "dist")"
if [[ -n "${NON_DIST_FRONTEND}" ]]; then
    echo "Error: Extraneous path detected under frontend/: ${NON_DIST_FRONTEND}" >&2
    exit 1
fi

echo "  [OK] Safety and boundary verification passed"

# ------------------------------------------------------------------------------
# 7. Create Release Artifacts Using v6.7 Transactional Packager
# ------------------------------------------------------------------------------

echo "--- Creating release artifacts using v6.7 transaction engine ---"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR_REAL="$(cd "${OUTPUT_DIR}" && pwd -P)"
chmod 0700 "${OUTPUT_DIR_REAL}"

V67_PACKAGER="${PROJECT_ROOT}/scripts/release-v67/packaging_tx.sh"

if [[ ! -f "${V67_PACKAGER}" ]]; then
    echo "Error: v6.7 packaging engine not found: ${V67_PACKAGER}" >&2
    exit 1
fi

if ! bash "${V67_PACKAGER}" \
    --package "${OUTPUT_DIR_REAL}" \
    "${VERSION}" \
    "${BUNDLE_ROOT}"; then
    echo "Error: v6.7 transactional packaging failed." >&2
    exit 1
fi

PRIMARY_ARCHIVE="git-repo-analyzer-release-${VERSION}.tar.gz"
PRIMARY_SIDECAR="${PRIMARY_ARCHIVE}.sha256"
COMPAT_ARCHIVE="${VERSION}.tar.gz"
COMPAT_SIDECAR="${COMPAT_ARCHIVE}.sha256"

# Verify all four committed artifacts.
for artifact in \
    "${PRIMARY_ARCHIVE}" \
    "${PRIMARY_SIDECAR}" \
    "${COMPAT_ARCHIVE}" \
    "${COMPAT_SIDECAR}"; do
    if [[ ! -s "${OUTPUT_DIR_REAL}/${artifact}" ]]; then
        echo "Error: Expected release artifact missing: ${artifact}" >&2
        exit 1
    fi
done

# Verify hardlink compatibility.
if [[ "$(stat -c %i "${OUTPUT_DIR_REAL}/${PRIMARY_ARCHIVE}")" != \
      "$(stat -c %i "${OUTPUT_DIR_REAL}/${COMPAT_ARCHIVE}")" ]]; then
    echo "Error: Primary and compatibility archives are not hardlinked." >&2
    exit 1
fi

(
    cd "${OUTPUT_DIR_REAL}"
    sha256sum -c --strict "${PRIMARY_SIDECAR}" >/dev/null
    sha256sum -c --strict "${COMPAT_SIDECAR}" >/dev/null
)

PRIMARY_SHA="$(cut -d ' ' -f 1 "${OUTPUT_DIR_REAL}/${PRIMARY_SIDECAR}")"
ARCHIVE_SIZE="$(du -h "${OUTPUT_DIR_REAL}/${PRIMARY_ARCHIVE}" | cut -f 1)"
