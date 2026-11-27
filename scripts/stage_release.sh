#!/usr/bin/env bash
# Compatibility wrapper for the v6.7 transactional release staging engine.
# Keeps the existing stage_release.sh CLI and STAGE_* environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
V67_STAGER="${SCRIPT_DIR}/release-v67/staging_tx.sh"

VERSION=""
ARCHIVE_DIR="${STAGE_ARCHIVE_DIR:-${PROJECT_ROOT}/dist-release}"
SSH_HOST="${STAGE_SSH_HOST:-app-server}"
SSH_USER="${STAGE_SSH_USER:-ubuntu}"
SSH_PORT="${STAGE_SSH_PORT:-22}"
SSH_KEY="${STAGE_SSH_KEY:-}"
SSH_CONFIG="${STAGE_SSH_CONFIG:-}"
REMOTE_STAGING_DIR="${STAGE_REMOTE_DIR:-/var/cache/git-repo-analyzer/staging}"
ALLOW_OVERWRITE=false
RECOVER=false
TX_TOKEN=""

usage() {
    cat <<'EOF'
Usage:
  scripts/stage_release.sh [OPTIONS] <VERSION>
  scripts/stage_release.sh --recover --version <VERSION> --tx-token <TOKEN> [SSH OPTIONS]

Options:
  -v, --version VERSION       Release version
  -d, --archive-dir DIR       Local archive directory
  -H, --host HOST             Remote SSH host (default: app-server)
  -u, --user USER             Remote SSH username (default: ubuntu)
  -p, --port PORT             Remote SSH port (default: 22)
  -i, --identity FILE         SSH private key
  -F, --ssh-config FILE       SSH client config
  -r, --remote-dir DIR        Remote staging directory
      --overwrite             Permit replacement of an existing staged release
      --recover               Recover an interrupted transaction
      --tx-token TOKEN        Transaction recovery token (required with --recover)
  -h, --help                  Show this help

Environment:
  STAGE_ARCHIVE_DIR, STAGE_SSH_HOST, STAGE_SSH_USER, STAGE_SSH_PORT,
  STAGE_SSH_KEY, STAGE_SSH_CONFIG, STAGE_REMOTE_DIR
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -v|--version|-d|--archive-dir|-H|--host|-u|--user|-p|--port|-i|--identity|-F|--ssh-config|-r|--remote-dir|--tx-token)
            (($# >= 2)) || fail "Option '$1' requires a value."
            [[ -n "$2" && "$2" != -* ]] || fail "Option '$1' requires a non-empty value."
            case "$1" in
                -v|--version) VERSION="$2" ;;
                -d|--archive-dir) ARCHIVE_DIR="$2" ;;
                -H|--host) SSH_HOST="$2" ;;
                -u|--user) SSH_USER="$2" ;;
                -p|--port) SSH_PORT="$2" ;;
                -i|--identity) SSH_KEY="$2" ;;
                -F|--ssh-config) SSH_CONFIG="$2" ;;
                -r|--remote-dir) REMOTE_STAGING_DIR="$2" ;;
                --tx-token) TX_TOKEN="$2" ;;
            esac
            shift 2
            ;;
        --overwrite) ALLOW_OVERWRITE=true; shift ;;
        --recover) RECOVER=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# == 1)) || fail "Expected exactly one version after --."; [[ -z "$VERSION" ]] || fail "Version supplied more than once."; VERSION="$1"; shift ;;
        -*) fail "Unrecognized option '$1'." ;;
        *) [[ -z "$VERSION" ]] || fail "Unexpected positional argument '$1'."; VERSION="$1"; shift ;;
    esac
done

[[ -x "$V67_STAGER" ]] || fail "v6.7 staging engine missing or not executable: $V67_STAGER"
[[ -f "${SCRIPT_DIR}/release-v67/design_common.sh" ]] || fail "v6.7 shared library missing: ${SCRIPT_DIR}/release-v67/design_common.sh"
command -v bash >/dev/null 2>&1 || fail "bash is required."

if [[ "$RECOVER" == true ]]; then
    [[ -n "$VERSION" ]] || fail "--recover requires --version."
    [[ -n "$TX_TOKEN" ]] || fail "--recover requires --tx-token."
    [[ "$ALLOW_OVERWRITE" == false ]] || fail "--overwrite cannot be combined with --recover."
else
    [[ -n "$VERSION" ]] || { usage >&2; fail "Missing release version."; }
    [[ -z "$TX_TOKEN" ]] || fail "--tx-token is only valid with --recover."
fi

[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail "Invalid release version."
[[ "$VERSION" != *".."* ]] || fail "Version must not contain '..'."
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535)) || fail "Invalid SSH port '$SSH_PORT'."
[[ -n "$SSH_HOST" && -n "$SSH_USER" ]] || fail "SSH host and user must not be empty."

# Preserve the wrapper's historical project-level SSH config auto-detection.
if [[ -z "$SSH_CONFIG" ]]; then
    if [[ -f "${PROJECT_ROOT}/ssh.cfg" ]]; then
        SSH_CONFIG="${PROJECT_ROOT}/ssh.cfg"
    elif [[ -f "${PROJECT_ROOT}/ansible/ssh.cfg" ]]; then
        SSH_CONFIG="${PROJECT_ROOT}/ansible/ssh.cfg"
    fi
fi
if [[ -z "$SSH_KEY" && -f "${HOME}/.ssh/git-repo-analyzer.pem" ]]; then
    SSH_KEY="${HOME}/.ssh/git-repo-analyzer.pem"
fi
[[ -z "$SSH_CONFIG" || -f "$SSH_CONFIG" ]] || fail "SSH config not found: $SSH_CONFIG"
[[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || fail "SSH identity not found: $SSH_KEY"

ENGINE_ARGS=(
    --version "$VERSION"
    --host "$SSH_HOST"
    --user "$SSH_USER"
    --port "$SSH_PORT"
    --remote-dir "$REMOTE_STAGING_DIR"
)
[[ -z "$SSH_KEY" ]] || ENGINE_ARGS+=(--identity "$SSH_KEY")
[[ -z "$SSH_CONFIG" ]] || ENGINE_ARGS+=(--ssh-config "$SSH_CONFIG")

if [[ "$RECOVER" == true ]]; then
    ENGINE_ARGS+=(--recover --tx-token "$TX_TOKEN")
    printf '%s\n' "Recovering interrupted staging transaction for release ${VERSION} on ${SSH_USER}@${SSH_HOST}."
else
    [[ -d "$ARCHIVE_DIR" ]] || fail "Archive directory does not exist: $ARCHIVE_DIR"
    ARCHIVE_DIR="$(cd "$ARCHIVE_DIR" && pwd -P)"
    ARCHIVE="${ARCHIVE_DIR}/${VERSION}.tar.gz"
    SIDECAR="${ARCHIVE}.sha256"

    [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" && -s "$ARCHIVE" ]] || fail "Canonical archive missing, empty, or symlink: $ARCHIVE"
    [[ -f "$SIDECAR" && ! -L "$SIDECAR" && -s "$SIDECAR" ]] || fail "Canonical checksum sidecar missing, empty, or symlink: $SIDECAR"
    (cd "$ARCHIVE_DIR" && sha256sum -c --strict "${VERSION}.tar.gz.sha256") || fail "Local archive checksum verification failed."
    ENGINE_ARGS+=(--archive-dir "$ARCHIVE_DIR")
    [[ "$ALLOW_OVERWRITE" == false ]] || ENGINE_ARGS+=(--overwrite)
    printf '%s\n' "Starting transactional staging for release ${VERSION}."
    printf 'Target: %s@%s:%s\n' "$SSH_USER" "$SSH_HOST" "$REMOTE_STAGING_DIR"
fi

# The v6.7 engine owns SSH hardening, transfer, remote locking, transaction
# journaling, promotion, rollback, and recovery. Do not duplicate those steps here.
exec bash "$V67_STAGER" "${ENGINE_ARGS[@]}"
