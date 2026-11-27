#!/usr/bin/env bash
# Staging SSH transport, upload validation, and deliberate recovery prototype.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/design_common.sh"

# Build SSH options preserving strict host-key verification and public-key auth
build_ssh_exec_opts() {
    local ssh_config="$1"
    local ssh_key="$2"
    local ssh_port="$3"

    SSH_EXEC_OPTS=()
    if [ -n "${ssh_config}" ]; then
        SSH_EXEC_OPTS+=("-F" "${ssh_config}")
    fi
    if [ -n "${ssh_key}" ]; then
        SSH_EXEC_OPTS+=("-i" "${ssh_key}")
    fi
    if [ "${ssh_port}" != "22" ]; then
        SSH_EXEC_OPTS+=("-p" "${ssh_port}")
    fi
    SSH_EXEC_OPTS+=(
        "-T"
        "-o" "BatchMode=yes"
        "-o" "StrictHostKeyChecking=yes"
        "-o" "ConnectTimeout=10"
        "-o" "ServerAliveInterval=15"
        "-o" "ServerAliveCountMax=3"
    )
}

run_ssh_command_with_locked_anchor() {
    local ssh_user="$1"
    local ssh_host="$2"
    local root_dir="$3"
    local lock_name="$4"
    local remote_script_body="$5"
    local stdin_file="${6:-/dev/null}"
    shift 6

    while [[ "${remote_script_body}" == *$'\n' ]]; do
        remote_script_body="${remote_script_body%$'\n'}"
    done

    local script_b64=""
    local expected_script_sha=""
    script_b64="$(printf '%s' "${remote_script_body}" | base64 -w 0)" || return 1
    expected_script_sha="$(printf '%s' "${remote_script_body}" | sha256sum | cut -d ' ' -f 1)" || return 1

    # Safely serialize root_dir, lock_name, and all remaining script arguments as Base64-encoded JSON.
    # This avoids shell interpolation or quoting issues across OpenSSH remote shell parsing regardless of spaces, quotes, $, newlines, backslashes, or empty values.
    local args_b64=""
    local expected_args_sha=""
    args_b64="$(/usr/bin/python3 -c 'import base64, json, sys; payload = json.dumps(sys.argv[1:], ensure_ascii=False).encode("utf-8"); print(base64.b64encode(payload).decode("ascii"))' "${root_dir}" "${lock_name}" "$@")" || return 1
    expected_args_sha="$(printf '%s' "${args_b64}" | base64 -d | sha256sum | cut -d ' ' -f 1)" || return 1

    # Remote bootstrap receives strictly pure Base64 and lowercase hex arguments ([A-Za-z0-9+/=]).
    local bootstrap=""
    bootstrap="/usr/bin/python3 -c '
import base64, fcntl, hashlib, json, os, stat, sys
s_b64, s_sha, a_b64, a_sha = sys.argv[1:5]
try:
    script = base64.b64decode(s_b64.encode(\"ascii\"), validate=True)
    args_raw = base64.b64decode(a_b64.encode(\"ascii\"), validate=True)
except Exception as exc:
    sys.stderr.write(f\"RESULT_TOKEN=SCRIPT_DELIVERY_FAILED\\nDecode error: {exc}\\n\")
    sys.exit(70)
if hashlib.sha256(script).hexdigest() != s_sha or hashlib.sha256(args_raw).hexdigest() != a_sha:
    sys.stderr.write(\"RESULT_TOKEN=SCRIPT_DELIVERY_FAILED\\nDigest mismatch\\n\")
    sys.exit(71)
try:
    decoded_args = json.loads(args_raw.decode(\"utf-8\"))
except Exception as exc:
    sys.stderr.write(f\"RESULT_TOKEN=SCRIPT_DELIVERY_FAILED\\nArgs JSON error: {exc}\\n\")
    sys.exit(70)
if not isinstance(decoded_args, list) or len(decoded_args) < 2 or not all(isinstance(x, str) and \"\\x00\" not in x for x in decoded_args):
    sys.stderr.write(\"RESULT_TOKEN=SCRIPT_DELIVERY_FAILED\\nInvalid argument list\\n\")
    sys.exit(71)
st_dir = decoded_args[0]
l_name = decoded_args[1]
script_args = decoded_args[2:]
euid = os.geteuid()
try:
    dfd = os.open(st_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError as exc:
    sys.stderr.write(f\"RESULT_TOKEN=DIR_INVALID\\n{exc}\\n\")
    sys.exit(72)
dst = os.fstat(dfd)
if dst.st_uid != euid or (dst.st_mode & 0o022) != 0:
    os.close(dfd)
    sys.stderr.write(f\"RESULT_TOKEN=DIR_UNTRUSTED\\nmode={oct(dst.st_mode)}\\n\")
    sys.exit(72)
try:
    lfd = os.open(l_name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o640, dir_fd=dfd)
except OSError as exc:
    os.close(dfd)
    sys.stderr.write(f\"RESULT_TOKEN=LOCK_OPEN_FAILED\\n{exc}\\n\")
    sys.exit(73)
st = os.fstat(lfd)
if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != euid:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write(\"RESULT_TOKEN=LOCK_HARDLINK_OR_TYPE_REJECTED\\n\")
    sys.exit(74)
try:
    fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write(\"RESULT_TOKEN=MUTEX_BUSY\\n\")
    sys.exit(75)
try:
    pst = os.lstat(l_name, dir_fd=dfd)
except OSError:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write(\"RESULT_TOKEN=LOCK_UNLINKED_RACE\\n\")
    sys.exit(76)
os.close(dfd)
if pst.st_dev != st.st_dev or pst.st_ino != st.st_ino or pst.st_nlink != 1 or not stat.S_ISREG(pst.st_mode):
    os.close(lfd)
    sys.stderr.write(\"RESULT_TOKEN=LOCK_REPLACED_RACE\\n\")
    sys.exit(76)
os.dup2(lfd, 9)
if lfd != 9:
    os.close(lfd)
os.set_inheritable(9, True)
os.execv(\"/bin/bash\", [\"bash\", \"-c\", script.decode(\"utf-8\"), \"gra-remote\"] + script_args)
' '${script_b64}' '${expected_script_sha}' '${args_b64}' '${expected_args_sha}'"

    local stdout_tmp="" stderr_tmp=""
    stdout_tmp="$(mktemp -t gra-ssh-out-XXXXXX)" || return 1
    stderr_tmp="$(mktemp -t gra-ssh-err-XXXXXX)" || { rm -f -- "${stdout_tmp}"; return 1; }

    local ssh_rc=0
    if ssh "${SSH_EXEC_OPTS[@]}" "${ssh_user}@${ssh_host}" "${bootstrap}" < "${stdin_file}" > "${stdout_tmp}" 2> "${stderr_tmp}"; then
        ssh_rc=0
    else
        ssh_rc=$?
    fi

    cat "${stdout_tmp}"
    if [ "${ssh_rc}" -ne 0 ]; then
        cat "${stderr_tmp}" >&2
        rm -f -- "${stdout_tmp}" "${stderr_tmp}" || return 1
        return "${ssh_rc}"
    fi
    rm -f -- "${stdout_tmp}" "${stderr_tmp}" || return 1
    return 0
}

# Build self-contained remote library header injected into remote stage and recover commands
get_remote_common_code() {
    cat "${SCRIPT_DIR}/design_common.sh"
    cat << 'EOF_REMOTE_STAGING_HELPERS'
parse_and_validate_staging_manifest() {
    local manifest_file="$1"
    local expected_version="$2"
    local expected_tx_id="$3"
    local expected_token="$4"

    if [ ! -f "${manifest_file}" ] || [ -L "${manifest_file}" ] || [ ! -s "${manifest_file}" ]; then
        return 1
    fi
    local last_hex=""
    last_hex="$(tail -c 1 -- "${manifest_file}" | od -An -tx1 | tr -d ' \n')" || return 1
    [ "${last_hex}" = "0a" ] || return 1

    SM_SCHEMA_VERSION="" SM_TX_ID="" SM_VERSION="" SM_SESSION_TOKEN=""
    SM_ARCH_NAME="" SM_ARCH_BASE_EXISTS="" SM_ARCH_BASE_SHA="" SM_ARCH_STAGE_SHA=""
    SM_SIDE_NAME="" SM_SIDE_BASE_EXISTS="" SM_SIDE_BASE_SHA="" SM_SIDE_STAGE_SHA=""

    local s_sch=0 s_tx=0 s_ver=0 s_tok=0
    local s_an=0 s_ae=0 s_ab=0 s_as=0
    local s_sn=0 s_se=0 s_sb=0 s_ss=0
    local raw_line="" key="" val=""

    while IFS= read -r raw_line; do
        if [[ "${raw_line}" == *$'\r'* ]] || [[ -z "${raw_line}" ]] || [[ "${raw_line}" == \#* ]] || [[ "${raw_line}" != *"="* ]]; then
            return 1
        fi
        key="${raw_line%%=*}"
        val="${raw_line#*=}"
        [ -n "${val}" ] || return 1

        case "${key}" in
            SCHEMA_VERSION) [ "${s_sch}" -eq 0 ] || return 1; s_sch=1; [ "${val}" = "1" ] || return 1; SM_SCHEMA_VERSION="${val}" ;;
            TX_ID) [ "${s_tx}" -eq 0 ] || return 1; s_tx=1; [ "${val}" = "${expected_tx_id}" ] || return 1; SM_TX_ID="${val}" ;;
            VERSION) [ "${s_ver}" -eq 0 ] || return 1; s_ver=1; [ "${val}" = "${expected_version}" ] || return 1; SM_VERSION="${val}" ;;
            SESSION_TOKEN) [ "${s_tok}" -eq 0 ] || return 1; s_tok=1; [ "${val}" = "${expected_token}" ] || return 1; SM_SESSION_TOKEN="${val}" ;;
            ARCHIVE_NAME) [ "${s_an}" -eq 0 ] || return 1; s_an=1; [ "${val}" = "${expected_version}.tar.gz" ] || return 1; SM_ARCH_NAME="${val}" ;;
            ARCHIVE_BASELINE_EXISTS) [ "${s_ae}" -eq 0 ] || return 1; s_ae=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; SM_ARCH_BASE_EXISTS="${val}" ;;
            ARCHIVE_BASELINE_SHA) [ "${s_ab}" -eq 0 ] || return 1; s_ab=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; SM_ARCH_BASE_SHA="${val}" ;;
            ARCHIVE_STAGE_SHA) [ "${s_as}" -eq 0 ] || return 1; s_as=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; SM_ARCH_STAGE_SHA="${val}" ;;
            SIDECAR_NAME) [ "${s_sn}" -eq 0 ] || return 1; s_sn=1; [ "${val}" = "${expected_version}.tar.gz.sha256" ] || return 1; SM_SIDE_NAME="${val}" ;;
            SIDECAR_BASELINE_EXISTS) [ "${s_se}" -eq 0 ] || return 1; s_se=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; SM_SIDE_BASE_EXISTS="${val}" ;;
            SIDECAR_BASELINE_SHA) [ "${s_sb}" -eq 0 ] || return 1; s_sb=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; SM_SIDE_BASE_SHA="${val}" ;;
            SIDECAR_STAGE_SHA) [ "${s_ss}" -eq 0 ] || return 1; s_ss=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; SM_SIDE_STAGE_SHA="${val}" ;;
            *) return 1 ;;
        esac
    done < "${manifest_file}"

    [ $((s_sch + s_tx + s_ver + s_tok + s_an + s_ae + s_ab + s_as + s_sn + s_se + s_sb + s_ss)) -eq 12 ] || return 1
    if [ "${SM_ARCH_BASE_EXISTS}" = "1" ] && [ "${SM_ARCH_BASE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${SM_ARCH_BASE_EXISTS}" = "0" ] && [ "${SM_ARCH_BASE_SHA}" != "NONE" ]; then return 1; fi
    if [ "${SM_SIDE_BASE_EXISTS}" = "1" ] && [ "${SM_SIDE_BASE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${SM_SIDE_BASE_EXISTS}" = "0" ] && [ "${SM_SIDE_BASE_SHA}" != "NONE" ]; then return 1; fi
    return 0
}

reconcile_one_staging_artifact() {
    local staging_dir="$1"
    local tx_dir="$2"
    local art_name="$3"
    local base_exists="$4"
    local base_sha="$5"
    local stage_sha="$6"
    local j_state="$7"
    local tx_id="$8"
    local canonical="${staging_dir}/${art_name}"

    case "${j_state}" in
        UNINITIALIZED|BASELINE_INSPECTED|BACKUP_INTENT|BACKUP_CREATED|BACKUP_DATA_SYNCED|BACKUP_DIR_SYNCED)
            if [ "${base_exists}" = "1" ]; then
                [ -f "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
                local csha=""
                csha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
                [ "${csha}" = "${base_sha}" ] || return 1
            else
                [ ! -e "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
            fi
            return 0
            ;;
        PROMOTE_INTENT|CANONICAL_REPLACED|CANONICAL_DIR_SYNCED|PROMOTED_VERIFIED)
            restore_artifact_nondestructive \
                "${staging_dir}" \
                "${art_name}" \
                "${base_exists}" \
                "${base_sha}" \
                "${stage_sha}" \
                "${tx_dir}/backup" \
                "${tx_id}" \
                "0640" || return 1
            return 0
            ;;
        *) return 1 ;;
    esac
}

reconcile_all_staging_artifacts() {
    local staging_dir="$1"
    local tx_dir="$2"
    local tx_id="$3"

    local allowed="^("
    allowed+="UNINITIALIZED|BASELINE_INSPECTED|"
    allowed+="BACKUP_INTENT|BACKUP_CREATED|BACKUP_DATA_SYNCED|BACKUP_DIR_SYNCED|"
    allowed+="PROMOTE_INTENT|CANONICAL_REPLACED|CANONICAL_DIR_SYNCED|PROMOTED_VERIFIED"
    allowed+=")$"

    read_bound_state_file "${tx_dir}/journal.ARCHIVE" "${tx_id}" "STATE" "${allowed}" || return 1
    local ja="${BOUND_VAL}"
    read_bound_state_file "${tx_dir}/journal.SIDECAR" "${tx_id}" "STATE" "${allowed}" || return 1
    local js="${BOUND_VAL}"

    local ok=1
    if ! reconcile_one_staging_artifact \
        "${staging_dir}" \
        "${tx_dir}" \
        "${SM_ARCH_NAME}" \
        "${SM_ARCH_BASE_EXISTS}" \
        "${SM_ARCH_BASE_SHA}" \
        "${SM_ARCH_STAGE_SHA}" \
        "${ja}" \
        "${tx_id}"; then
        ok=0
    fi
    if ! reconcile_one_staging_artifact \
        "${staging_dir}" \
        "${tx_dir}" \
        "${SM_SIDE_NAME}" \
        "${SM_SIDE_BASE_EXISTS}" \
        "${SM_SIDE_BASE_SHA}" \
        "${SM_SIDE_STAGE_SHA}" \
        "${js}" \
        "${tx_id}"; then
        ok=0
    fi
    [ "${ok}" -eq 1 ] || return 1
    return 0
}

verify_staging_baseline_only() {
    local staging_dir="$1"
    for pair in "${SM_ARCH_NAME}:${SM_ARCH_BASE_EXISTS}:${SM_ARCH_BASE_SHA}" "${SM_SIDE_NAME}:${SM_SIDE_BASE_EXISTS}:${SM_SIDE_BASE_SHA}"; do
        IFS=':' read -r nm ex bsha <<< "${pair}"
        local target="${staging_dir}/${nm}"
        if [ "${ex}" = "1" ]; then
            [ -f "${target}" ] && [ ! -L "${target}" ] || return 1
            local csha=""
            csha="$(sha256sum "${target}" | cut -d ' ' -f 1)" || return 1
            [ "${csha}" = "${bsha}" ] || return 1
        else
            [ ! -e "${target}" ] && [ ! -L "${target}" ] || return 1
        fi
    done
    return 0
}

mark_staging_recovery_required() {
    local tx_dir="$1"
    local tx_id="$2"
    if ! persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_dir}"; then
        echo "CRITICAL: Failed persisting TX_RECOVERY_REQUIRED inside '${tx_dir}'; preserving all evidence." >&2
        return 1
    fi
    return 0
}

finalize_staging_after_commit() {
    local staging_dir="$1"
    local tx_dir="$2"
    local version="$3"
    local tx_id="$4"
    local token="$5"

    local auth_tag=""
    auth_tag="$(compute_auth_tag "${version}" "${tx_id}" "${token}")" || return 1
    local retired_dir="${staging_dir}/.tx-retired-${version}-${tx_id}-${auth_tag}"

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_PRUNING_AFTER_COMMIT" "${tx_dir}" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${version}.tar.gz" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${version}.tar.gz.sha256" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/backup" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz.sha256" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/stage" || return 1

    sync "${tx_dir}" || return 1
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_CLEANUP_INIT" "${tx_dir}" || return 1

    [ ! -e "${retired_dir}" ] && [ ! -L "${retired_dir}" ] || return 1
    mv -f -T "${tx_dir}" "${retired_dir}" || return 1
    sync "${staging_dir}" || return 2

    cleanup_retired_tx_directory "${staging_dir}" "${retired_dir}" "${version}" "${tx_id}" "${token}" "${auth_tag}" || return 1
    return 0
}

finalize_staging_after_verified_rollback() {
    local staging_dir="$1"
    local tx_dir="$2"
    local version="$3"
    local tx_id="$4"
    local token="$5"

    local auth_tag=""
    auth_tag="$(compute_auth_tag "${version}" "${tx_id}" "${token}")" || return 1
    local retired_dir="${staging_dir}/.tx-retired-${version}-${tx_id}-${auth_tag}"

    if [ -f "${tx_dir}/manifest.env" ]; then
        if ! verify_staging_baseline_only "${staging_dir}"; then
            echo "CRITICAL: Canonical staging baseline check failed during pruning; halting." >&2
            if ! mark_staging_recovery_required "${tx_dir}" "${tx_id}"; then
                echo "CRITICAL: Failed persisting TX_RECOVERY_REQUIRED during pruning abort." >&2
            fi
            return 1
        fi
    fi

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_PRUNING_AFTER_ROLLBACK" "${tx_dir}" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${version}.tar.gz" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${version}.tar.gz.sha256" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/backup" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz.sha256" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/stage" || return 1

    sync "${tx_dir}" || return 1
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_CLEANUP_INIT" "${tx_dir}" || return 1

    [ ! -e "${retired_dir}" ] && [ ! -L "${retired_dir}" ] || return 1
    mv -f -T "${tx_dir}" "${retired_dir}" || return 1
    sync "${staging_dir}" || return 2

    cleanup_retired_tx_directory "${staging_dir}" "${retired_dir}" "${version}" "${tx_id}" "${token}" "${auth_tag}" || return 1
    return 0
}

finalize_staging_after_upload_abort() {
    local staging_dir="$1"
    local tx_dir="$2"
    local version="$3"
    local tx_id="$4"
    local token="$5"

    local auth_tag=""
    auth_tag="$(compute_auth_tag "${version}" "${tx_id}" "${token}")" || return 1
    local retired_dir="${staging_dir}/.tx-retired-${version}-${tx_id}-${auth_tag}"

    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/backup" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${version}.tar.gz.sha256" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/stage" || return 1

    sync "${tx_dir}" || return 1
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_UPLOAD_ABORT" "${tx_dir}" || return 1

    [ ! -e "${retired_dir}" ] && [ ! -L "${retired_dir}" ] || return 1
    mv -f -T "${tx_dir}" "${retired_dir}" || return 1
    sync "${staging_dir}" || return 2

    cleanup_retired_tx_directory "${staging_dir}" "${retired_dir}" "${version}" "${tx_id}" "${token}" "${auth_tag}" || return 1
    return 0
}
EOF_REMOTE_STAGING_HELPERS
}

run_remote_locked_stage_transfer() {
    local ssh_user="$1"
    local ssh_host="$2"
    local staging_dir="$3"
    local version="$4"
    local session_token="$5"
    local tx_id="$6"
    local allow_overwrite="$7"
    local local_archive="$8"
    local local_sha="$9"

    local archive_bytes=""
    archive_bytes="$(stat -c %s "${local_archive}")" || return 1

    local remote_body=""
    remote_body="$(get_remote_common_code)"
    remote_body="${remote_body}
$(cat << 'EOF_STAGE_MAIN'
set -euo pipefail
STAGING_DIR="$1"
VERSION="$2"
TOKEN="$3"
TX_ID="$4"
ALLOW_OW="$5"
EXP_SHA="$6"
EXP_BYTES="$7"

LOCK_HELD=1
TX_DIR="${STAGING_DIR}/.tx-${VERSION}"
CAN_ARCH="${STAGING_DIR}/${VERSION}.tar.gz"
CAN_SIDE="${STAGING_DIR}/${VERSION}.tar.gz.sha256"
TRAP_DONE=0
ORIG_CODE=0
OWNS_TX_DIR=0

release_flock() {
    if [ "${LOCK_HELD}" -eq 1 ]; then
        exec 9>&-
        LOCK_HELD=0
    fi
}

_fail_and_mark_recovery_required() {
    local tx_d="$1"
    local tid="$2"
    if ! mark_staging_recovery_required "${tx_d}" "${tid}"; then
        echo "CRITICAL: Secondary error: failed persisting TX_RECOVERY_REQUIRED inside '${tx_d}'." >&2
    fi
}

remote_exit_trap() {
    local rc=$?
    [ "${TRAP_DONE}" -eq 0 ] || return 0
    TRAP_DONE=1
    trap '' INT TERM HUP
    [ "${ORIG_CODE}" -ne 0 ] && rc="${ORIG_CODE}"

    if [ "${OWNS_TX_DIR}" -ne 1 ] || { [ ! -e "${TX_DIR}" ] && [ ! -L "${TX_DIR}" ]; }; then
        release_flock
        exit "${rc}"
    fi

    local cur_phase="MISSING"
    if read_bound_state_file "${TX_DIR}/tx_phase" "${TX_ID}" "PHASE" "^[A-Z0-9_]+$" 2>/dev/null; then
        cur_phase="${BOUND_VAL}"
    fi

    case "${cur_phase}" in
        TX_COMMITTED|TX_PRUNING_AFTER_COMMIT|TX_FINALIZING_CLEANUP_INIT)
            if ! finalize_staging_after_commit "${STAGING_DIR}" "${TX_DIR}" "${VERSION}" "${TX_ID}" "${TOKEN}"; then
                release_flock
                exit 1
            fi
            release_flock
            exit 0
            ;;
        TX_ROLLED_BACK_VERIFIED|TX_PRUNING_AFTER_ROLLBACK)
            if ! finalize_staging_after_verified_rollback "${STAGING_DIR}" "${TX_DIR}" "${VERSION}" "${TX_ID}" "${TOKEN}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            release_flock
            [ "${rc}" -eq 0 ] && rc=1
            exit "${rc}"
            ;;
        TX_UPLOAD_IN_PROGRESS)
            if ! finalize_staging_after_upload_abort "${STAGING_DIR}" "${TX_DIR}" "${VERSION}" "${TX_ID}" "${TOKEN}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            release_flock
            [ "${rc}" -eq 0 ] && rc=1
            exit "${rc}"
            ;;
        TX_INITIALIZED|TX_BACKUPS_READY|TX_PROMOTING|TX_VALIDATED)
            if ! parse_and_validate_staging_manifest "${TX_DIR}/manifest.env" "${VERSION}" "${TX_ID}" "${TOKEN}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            if ! reconcile_all_staging_artifacts "${STAGING_DIR}" "${TX_DIR}" "${TX_ID}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            if ! persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_ROLLED_BACK_VERIFIED" "${TX_DIR}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            if ! finalize_staging_after_verified_rollback "${STAGING_DIR}" "${TX_DIR}" "${VERSION}" "${TX_ID}" "${TOKEN}"; then
                _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
                release_flock
                exit 1
            fi
            release_flock
            [ "${rc}" -eq 0 ] && rc=1
            exit "${rc}"
            ;;
        *)
            _fail_and_mark_recovery_required "${TX_DIR}" "${TX_ID}"
            release_flock
            exit 1
            ;;
    esac
}

trap 'ORIG_CODE=130; exit 130' INT
trap 'ORIG_CODE=143; exit 143' TERM
trap 'ORIG_CODE=129; exit 129' HUP
trap 'remote_exit_trap' EXIT

if [ -e "${TX_DIR}" ] || [ -L "${TX_DIR}" ]; then
    echo "RESULT_TOKEN=LOCKED_OR_RECOVERY_REQUIRED" >&2
    exit 1
fi
shopt -s nullglob dotglob
for rcand in "${STAGING_DIR}/.tx-retired-${VERSION}-"*; do
    if [ -e "${rcand}" ] || [ -L "${rcand}" ]; then
        echo "RESULT_TOKEN=RETIRED_CLEANUP_PENDING" >&2
        exit 1
    fi
done
shopt -u nullglob dotglob

if [ -e "${CAN_ARCH}" ] || [ -L "${CAN_ARCH}" ] || [ -e "${CAN_SIDE}" ] || [ -L "${CAN_SIDE}" ]; then
    [ "${ALLOW_OW}" = "true" ] || { echo "RESULT_TOKEN=EXISTS_REFUSED" >&2; exit 1; }
fi

ORIG_ARCH_EX=0 ORIG_ARCH_SHA="NONE"
if [ -e "${CAN_ARCH}" ]; then
    [ -f "${CAN_ARCH}" ] && [ ! -L "${CAN_ARCH}" ] || exit 1
    ORIG_ARCH_EX=1
    ORIG_ARCH_SHA="$(sha256sum "${CAN_ARCH}" | cut -d ' ' -f 1)" || exit 1
fi
ORIG_SIDE_EX=0 ORIG_SIDE_SHA="NONE"
if [ -e "${CAN_SIDE}" ]; then
    [ -f "${CAN_SIDE}" ] && [ ! -L "${CAN_SIDE}" ] || exit 1
    ORIG_SIDE_EX=1
    ORIG_SIDE_SHA="$(sha256sum "${CAN_SIDE}" | cut -d ' ' -f 1)" || exit 1
fi

mkdir -- "${TX_DIR}"
OWNS_TX_DIR=1
chmod 0700 "${TX_DIR}"
mkdir -- "${TX_DIR}/stage" "${TX_DIR}/backup"
write_state_atomic "${TX_DIR}/token" "${TOKEN}" "${TX_DIR}"
write_state_atomic "${TX_DIR}/tx_id" "${TX_ID}" "${TX_DIR}"
persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_UPLOAD_IN_PROGRESS" "${TX_DIR}"

TMP_ARCH="${TX_DIR}/stage/${VERSION}.tar.gz"
TMP_SIDE="${TX_DIR}/stage/${VERSION}.tar.gz.sha256"

head -c "${EXP_BYTES}" > "${TMP_ARCH}"
GOT_BYTES="$(stat -c %s "${TMP_ARCH}")"
if [ "${GOT_BYTES}" != "${EXP_BYTES}" ]; then
    echo "Error: Truncated upload (${GOT_BYTES} != ${EXP_BYTES})." >&2
    exit 1
fi
EXTRA_BYTES="$(head -c 1 | wc -c)"
EXTRA_BYTES="${EXTRA_BYTES//[[:space:]]/}"
if [ "${EXTRA_BYTES}" != "0" ]; then
    echo "Error: Trailing garbage bytes on upload." >&2
    exit 1
fi
GOT_SHA="$(sha256sum "${TMP_ARCH}" | cut -d ' ' -f 1)"
if [ "${GOT_SHA}" != "${EXP_SHA}" ]; then
    echo "Error: Digest mismatch on uploaded archive." >&2
    exit 1
fi
printf '%s  %s\n' "${EXP_SHA}" "${VERSION}.tar.gz" > "${TMP_SIDE}"
chmod 0640 "${TMP_ARCH}" "${TMP_SIDE}"
STAGE_SIDE_SHA="$(sha256sum "${TMP_SIDE}" | cut -d ' ' -f 1)"
sync "${TMP_ARCH}" && sync "${TMP_SIDE}" && sync "${TX_DIR}/stage"

# Create manifest atomically using exclusive temp file
MANIFEST_TMP="$(mktemp "${TX_DIR}/.manifest.env.tmp.XXXXXX")"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=%s\nSESSION_TOKEN=%s\nARCHIVE_NAME=%s\nARCHIVE_BASELINE_EXISTS=%s\nARCHIVE_BASELINE_SHA=%s\nARCHIVE_STAGE_SHA=%s\nSIDECAR_NAME=%s\nSIDECAR_BASELINE_EXISTS=%s\nSIDECAR_BASELINE_SHA=%s\nSIDECAR_STAGE_SHA=%s\n' \
    "${TX_ID}" "${VERSION}" "${TOKEN}" \
    "${VERSION}.tar.gz" "${ORIG_ARCH_EX}" "${ORIG_ARCH_SHA}" "${EXP_SHA}" \
    "${VERSION}.tar.gz.sha256" "${ORIG_SIDE_EX}" "${ORIG_SIDE_SHA}" "${STAGE_SIDE_SHA}" > "${MANIFEST_TMP}"
sync "${MANIFEST_TMP}"
mv -f -T "${MANIFEST_TMP}" "${TX_DIR}/manifest.env"
sync "${TX_DIR}"

parse_and_validate_staging_manifest "${TX_DIR}/manifest.env" "${VERSION}" "${TX_ID}" "${TOKEN}"
write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "BASELINE_INSPECTED" "${TX_DIR}"
write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "BASELINE_INSPECTED" "${TX_DIR}"
persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_INITIALIZED" "${TX_DIR}"

# Backups
if [ "${ORIG_ARCH_EX}" -eq 1 ]; then
    write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "BACKUP_INTENT" "${TX_DIR}"
    cp -p "${CAN_ARCH}" "${TX_DIR}/backup/${VERSION}.tar.gz"
    write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "BACKUP_CREATED" "${TX_DIR}"
    sync "${TX_DIR}/backup/${VERSION}.tar.gz"
    [ "$(sha256sum "${TX_DIR}/backup/${VERSION}.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_ARCH_SHA}" ]
    write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "BACKUP_DATA_SYNCED" "${TX_DIR}"
    sync "${TX_DIR}/backup"
    write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "BACKUP_DIR_SYNCED" "${TX_DIR}"
fi
if [ "${ORIG_SIDE_EX}" -eq 1 ]; then
    write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "BACKUP_INTENT" "${TX_DIR}"
    cp -p "${CAN_SIDE}" "${TX_DIR}/backup/${VERSION}.tar.gz.sha256"
    write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "BACKUP_CREATED" "${TX_DIR}"
    sync "${TX_DIR}/backup/${VERSION}.tar.gz.sha256"
    [ "$(sha256sum "${TX_DIR}/backup/${VERSION}.tar.gz.sha256" | cut -d ' ' -f 1)" = "${ORIG_SIDE_SHA}" ]
    write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "BACKUP_DATA_SYNCED" "${TX_DIR}"
    sync "${TX_DIR}/backup"
    write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "BACKUP_DIR_SYNCED" "${TX_DIR}"
fi
persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_BACKUPS_READY" "${TX_DIR}"

# Simulated hook for fault injection testing
if [ "${MOCK_FAIL_AFTER_BACKUP:-0}" = "1" ]; then
    echo "Injected failure after backup" >&2
    exit 1
fi

persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_PROMOTING" "${TX_DIR}"
write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "PROMOTE_INTENT" "${TX_DIR}"
mv -f -T "${TMP_ARCH}" "${CAN_ARCH}"
write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "CANONICAL_REPLACED" "${TX_DIR}"
sync "${CAN_ARCH}" && sync "${STAGING_DIR}"
write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "CANONICAL_DIR_SYNCED" "${TX_DIR}"

if [ "${MOCK_FAIL_AFTER_ARCH_PROMOTE:-0}" = "1" ]; then
    echo "Injected failure after archive promotion" >&2
    exit 1
fi

write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "PROMOTE_INTENT" "${TX_DIR}"
mv -f -T "${TMP_SIDE}" "${CAN_SIDE}"
write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "CANONICAL_REPLACED" "${TX_DIR}"
sync "${CAN_SIDE}" && sync "${STAGING_DIR}"
write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "CANONICAL_DIR_SYNCED" "${TX_DIR}"

if [ "${MOCK_FAIL_AFTER_SIDE_PROMOTE:-0}" = "1" ]; then
    echo "Injected failure after sidecar promotion" >&2
    exit 1
fi

chmod 0640 "${CAN_ARCH}" "${CAN_SIDE}"
(cd "${STAGING_DIR}" && sha256sum -c --strict "${VERSION}.tar.gz.sha256" >/dev/null)
write_bound_state_atomic "${TX_DIR}/journal.ARCHIVE" "${TX_ID}" "STATE" "PROMOTED_VERIFIED" "${TX_DIR}"
write_bound_state_atomic "${TX_DIR}/journal.SIDECAR" "${TX_ID}" "STATE" "PROMOTED_VERIFIED" "${TX_DIR}"
persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_VALIDATED" "${TX_DIR}"

# Two-Phase Commit Point
persist_bound_phase_or_halt "${TX_DIR}/tx_phase" "${TX_ID}" "TX_COMMITTED" "${TX_DIR}"
finalize_staging_after_commit "${STAGING_DIR}" "${TX_DIR}" "${VERSION}" "${TX_ID}" "${TOKEN}"
release_flock
echo "RESULT_TOKEN=STAGE_COMMITTED"
EOF_STAGE_MAIN
)"

    run_ssh_command_with_locked_anchor "${ssh_user}" "${ssh_host}" "${staging_dir}" ".gra-tx-${version}.flock" \
        "${remote_body}" "${local_archive}" \
        "${staging_dir}" "${version}" "${session_token}" "${tx_id}" "${allow_overwrite}" "${local_sha}" "${archive_bytes}"
}

dispatch_stage_recovery() {
    local ssh_user="$1"
    local ssh_host="$2"
    local staging_dir="$3"
    local version="$4"
    local supplied_token="$5"

    if [[ ! "${version}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || [[ "${version}" == *".."* ]]; then
        echo "Error: Invalid version '${version}'." >&2
        return 1
    fi
    if [[ ! "${supplied_token}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$ ]]; then
        echo "Error: Invalid --tx-token format." >&2
        return 1
    fi
    validate_canonical_path "${staging_dir}" "-r/--remote-dir" || return 1

    local recover_body=""
    recover_body="$(get_remote_common_code)"
    recover_body="${recover_body}
$(cat << 'EOF_STAGE_RECOVER'
set -euo pipefail
STAGING_DIR="$1"
VERSION="$2"
SUPPLIED_TOKEN="$3"

ACTIVE_DIR="${STAGING_DIR}/.tx-${VERSION}"
RETIRED_RE="^\.tx-retired-${VERSION}-([0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16})-([0-9a-f]{32})$"

_fail_recover_state() {
    local tx_d="$1"
    local tid="$2"
    if ! mark_staging_recovery_required "${tx_d}" "${tid}"; then
        echo "CRITICAL: Secondary error writing TX_RECOVERY_REQUIRED inside '${tx_d}'." >&2
    fi
}

RETIRED_LIST=()
shopt -s nullglob dotglob
for ent in "${STAGING_DIR}/.tx-retired-"*; do
    bn="$(basename "${ent}")"
    if [[ "${bn}" == ".tx-retired-${VERSION}-"* ]]; then
        if [[ ! "${bn}" =~ ${RETIRED_RE} ]]; then
            echo "CRITICAL: Malformed retired directory name '${bn}'." >&2
            exec 9>&-
            exit 1
        fi
        RETIRED_LIST+=("${ent}")
    fi
done
shopt -u nullglob dotglob

ACT_EXISTS=0
if [ -e "${ACTIVE_DIR}" ] || [ -L "${ACTIVE_DIR}" ]; then
    ACT_EXISTS=1
fi

if [ "${ACT_EXISTS}" -eq 1 ] && [ "${#RETIRED_LIST[@]}" -gt 0 ]; then
    echo "CRITICAL: Conflicting active and retired directories exist." >&2
    exec 9>&-
    exit 1
fi
if [ "${#RETIRED_LIST[@]}" -gt 1 ]; then
    echo "CRITICAL: Multiple retired directories exist." >&2
    exec 9>&-
    exit 1
fi
if [ "${ACT_EXISTS}" -eq 0 ] && [ "${#RETIRED_LIST[@]}" -eq 0 ]; then
    echo "Error: No transaction directory found for version '${VERSION}'." >&2
    exec 9>&-
    exit 1
fi

if [ "${ACT_EXISTS}" -eq 1 ]; then
    if [ ! -d "${ACTIVE_DIR}" ] || [ -L "${ACTIVE_DIR}" ]; then
        exec 9>&-
        exit 1
    fi
    if [ ! -f "${ACTIVE_DIR}/token" ] || [ -L "${ACTIVE_DIR}/token" ] || [ ! -s "${ACTIVE_DIR}/token" ]; then
        echo "CRITICAL: Active directory missing token." >&2
        exec 9>&-
        exit 1
    fi
    stored_tok=""
    if ! IFS= read -r stored_tok < "${ACTIVE_DIR}/token"; then
        exec 9>&-
        exit 1
    fi
    if [ "${stored_tok}" != "${SUPPLIED_TOKEN}" ]; then
        echo "Error: Token mismatch on active directory." >&2
        exec 9>&-
        exit 1
    fi
    if [ ! -f "${ACTIVE_DIR}/tx_id" ] || [ -L "${ACTIVE_DIR}/tx_id" ]; then
        echo "CRITICAL: Missing tx_id inside active directory." >&2
        exec 9>&-
        exit 1
    fi
    tx_id=""
    if ! IFS= read -r tx_id < "${ACTIVE_DIR}/tx_id"; then
        exec 9>&-
        exit 1
    fi
    if [[ ! "${tx_id}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}$ ]]; then
        exec 9>&-
        exit 1
    fi

    if ! read_bound_state_file "${ACTIVE_DIR}/tx_phase" "${tx_id}" "PHASE" "^[A-Z0-9_]+$"; then
        echo "CRITICAL: Invalid bound tx_phase inside active directory." >&2
        exec 9>&-
        exit 1
    fi
    phase="${BOUND_VAL}"

    if [ "${phase}" = "TX_UPLOAD_IN_PROGRESS" ]; then
        if ! finalize_staging_after_upload_abort "${STAGING_DIR}" "${ACTIVE_DIR}" "${VERSION}" "${tx_id}" "${SUPPLIED_TOKEN}"; then
            _fail_recover_state "${ACTIVE_DIR}" "${tx_id}"
            exec 9>&-
            exit 1
        fi
        exec 9>&-
        echo "RESULT_TOKEN=RECOVERED_UPLOAD_ABORT"
        exit 0
    fi

    if ! parse_and_validate_staging_manifest "${ACTIVE_DIR}/manifest.env" "${VERSION}" "${tx_id}" "${SUPPLIED_TOKEN}"; then
        echo "CRITICAL: Invalid manifest inside '${ACTIVE_DIR}'." >&2
        _fail_recover_state "${ACTIVE_DIR}" "${tx_id}"
        exec 9>&-
        exit 1
    fi

    case "${phase}" in
        TX_COMMITTED|TX_PRUNING_AFTER_COMMIT|TX_FINALIZING_CLEANUP_INIT)
            if ! finalize_staging_after_commit "${STAGING_DIR}" "${ACTIVE_DIR}" "${VERSION}" "${tx_id}" "${SUPPLIED_TOKEN}"; then
                exec 9>&-
                exit 1
            fi
            ;;
        TX_ROLLED_BACK_VERIFIED|TX_PRUNING_AFTER_ROLLBACK)
            if ! finalize_staging_after_verified_rollback "${STAGING_DIR}" "${ACTIVE_DIR}" "${VERSION}" "${tx_id}" "${SUPPLIED_TOKEN}"; then
                exec 9>&-
                exit 1
            fi
            ;;
        TX_INITIALIZED|TX_BACKUPS_READY|TX_PROMOTING|TX_VALIDATED|TX_ROLLING_BACK|TX_RECOVERY_REQUIRED)
            if ! reconcile_all_staging_artifacts "${STAGING_DIR}" "${ACTIVE_DIR}" "${tx_id}"; then
                _fail_recover_state "${ACTIVE_DIR}" "${tx_id}"
                exec 9>&-
                exit 1
            fi
            if ! persist_bound_phase_or_halt "${ACTIVE_DIR}/tx_phase" "${tx_id}" "TX_ROLLED_BACK_VERIFIED" "${ACTIVE_DIR}"; then
                _fail_recover_state "${ACTIVE_DIR}" "${tx_id}"
                exec 9>&-
                exit 1
            fi
            if ! finalize_staging_after_verified_rollback "${STAGING_DIR}" "${ACTIVE_DIR}" "${VERSION}" "${tx_id}" "${SUPPLIED_TOKEN}"; then
                exec 9>&-
                exit 1
            fi
            ;;
        *)
            echo "CRITICAL: Unrecognized phase '${phase}'." >&2
            _fail_recover_state "${ACTIVE_DIR}" "${tx_id}"
            exec 9>&-
            exit 1
            ;;
    esac
    exec 9>&-
    echo "RESULT_TOKEN=RECOVERED_SUCCESS"
    exit 0
else
    RET_DIR="${RETIRED_LIST[0]}"
    RET_BN="$(basename "${RET_DIR}")"
    [[ "${RET_BN}" =~ ${RETIRED_RE} ]] || { exec 9>&-; exit 1; }
    ret_tx_id="${BASH_REMATCH[1]}"
    ret_auth_tag="${BASH_REMATCH[2]}"
    cleanup_retired_tx_directory "${STAGING_DIR}" "${RET_DIR}" "${VERSION}" "${ret_tx_id}" "${SUPPLIED_TOKEN}" "${ret_auth_tag}" || { exec 9>&-; exit 1; }
    exec 9>&-
    echo "RESULT_TOKEN=RECOVERED_RETIRED_SUCCESS"
    exit 0
fi
EOF_STAGE_RECOVER
)"

    run_ssh_command_with_locked_anchor "${ssh_user}" "${ssh_host}" "${staging_dir}" ".gra-tx-${version}.flock" \
        "${recover_body}" "/dev/null" "${staging_dir}" "${version}" "${supplied_token}"
}

# CLI Driver for staging_tx.sh
stage_cli_main() {
    local mode_recover=false
    local ver="" arch_dir="" host="app-server" user="ubuntu" port="22" key="" cfg=""
    local rdir="/var/cache/git-repo-analyzer/staging" ow="false" tx_tok=""
    local arch_dir_explicit=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --recover) mode_recover=true; shift ;;
            --tx-token) [ $# -ge 2 ] || return 1; tx_tok="$2"; shift 2 ;;
            -v|--version) [ $# -ge 2 ] || return 1; ver="$2"; shift 2 ;;
            -d|--archive-dir) [ $# -ge 2 ] || return 1; arch_dir="$2"; arch_dir_explicit=true; shift 2 ;;
            -H|--host) [ $# -ge 2 ] || return 1; host="$2"; shift 2 ;;
            -u|--user) [ $# -ge 2 ] || return 1; user="$2"; shift 2 ;;
            -p|--port) [ $# -ge 2 ] || return 1; port="$2"; shift 2 ;;
            -i|--identity) [ $# -ge 2 ] || return 1; key="$2"; shift 2 ;;
            -F|--ssh-config) [ $# -ge 2 ] || return 1; cfg="$2"; shift 2 ;;
            -r|--remote-dir) [ $# -ge 2 ] || return 1; rdir="$2"; shift 2 ;;
            --overwrite) ow="true"; shift ;;
            *) echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    build_ssh_exec_opts "${cfg}" "${key}" "${port}"

    if [ "${mode_recover}" = "true" ]; then
        if [ "${ow}" = "true" ] || [ "${arch_dir_explicit}" = "true" ]; then
            echo "Error: --recover cannot be combined with --overwrite or --archive-dir." >&2
            return 1
        fi
        dispatch_stage_recovery "${user}" "${host}" "${rdir}" "${ver}" "${tx_tok}"
        return $?
    fi

    if [[ ! "${ver}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || [[ "${ver}" == *".."* ]]; then
        echo "Error: Invalid version '${ver}'." >&2
        return 1
    fi
    validate_canonical_path "${rdir}" "-r/--remote-dir" || return 1
    local l_arch="${arch_dir}/${ver}.tar.gz"
    local l_side="${arch_dir}/${ver}.tar.gz.sha256"
    [ -f "${l_arch}" ] && [ ! -L "${l_arch}" ] && [ -s "${l_arch}" ] || return 1
    [ -f "${l_side}" ] && [ ! -L "${l_side}" ] && [ -s "${l_side}" ] || return 1
    (cd "${arch_dir}" && sha256sum -c --strict "${ver}.tar.gz.sha256" >/dev/null) || return 1
    local l_sha=""
    l_sha="$(cut -d ' ' -f 1 "${l_side}")"
    local rand_tok="" rand_id="" ts=""
    rand_tok="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    rand_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local s_tok="${ts}-${rand_tok}"
    local tx_i="${ts}-$$-${rand_id}"

    run_remote_locked_stage_transfer "${user}" "${host}" "${rdir}" "${ver}" "${s_tok}" "${tx_i}" "${ow}" "${l_arch}" "${l_sha}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    stage_cli_main "$@"
    exit $?
fi
