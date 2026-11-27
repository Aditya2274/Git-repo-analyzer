#!/usr/bin/env bash
# Shared transaction helpers for v6.7 release packaging and staging prototype.

validate_canonical_path() {
    local path="$1"
    local param_name="$2"

    if [[ ! "${path}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        echo "Error: ${param_name} '${path}' must be an absolute path containing only [A-Za-z0-9._/-]." >&2
        return 1
    fi

    local -a segments
    IFS='/' read -ra segments <<< "${path#/}"
    local seg=""
    for seg in "${segments[@]}"; do
        if [[ -z "${seg}" ]]; then
            echo "Error: ${param_name} '${path}' contains empty path components." >&2
            return 1
        fi
        if [[ "${seg}" == "." ]] || [[ "${seg}" == ".." ]]; then
            echo "Error: ${param_name} '${path}' contains dot traversal component '${seg}'." >&2
            return 1
        fi
        if [[ ! "${seg}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "Error: ${param_name} '${path}' invalid component '${seg}'." >&2
            return 1
        fi
    done
    return 0
}

compute_auth_tag() {
    local version="$1"
    local tx_id="$2"
    local token="$3"
    local digest=""
    digest="$(printf '%s:%s:%s' "${version}" "${tx_id}" "${token}" | sha256sum | cut -d ' ' -f 1)" || return 1
    printf '%s' "${digest:0:32}"
}

_cleanup_failed_state_tmp() {
    local tmp_file="$1"
    if [ -e "${tmp_file}" ] || [ -L "${tmp_file}" ]; then
        if ! rm -f -- "${tmp_file}"; then
            echo "CRITICAL: Secondary cleanup error removing temporary state '${tmp_file}'; preserving evidence." >&2
            return 1
        fi
    fi
    return 0
}

write_state_atomic() {
    local target_file="$1"
    local state_val="$2"
    local parent_dir="$3"
    local target_base=""
    local target_parent_actual=""
    local tmp_file=""

    if [ ! -d "${parent_dir}" ] || [ -L "${parent_dir}" ]; then
        echo "CRITICAL: State parent directory '${parent_dir}' missing or symlink." >&2
        return 1
    fi

    target_base="$(basename "${target_file}")"
    target_parent_actual="$(cd "$(dirname "${target_file}")" 2>/dev/null && pwd -P)" || return 1
    if [ "${target_parent_actual}" != "${parent_dir}" ]; then
        echo "CRITICAL: State target '${target_file}' escapes '${parent_dir}'." >&2
        return 1
    fi
    if [ -L "${target_file}" ]; then
        echo "CRITICAL: Existing state path '${target_file}' is a symlink." >&2
        return 1
    fi

    if ! tmp_file="$(mktemp "${parent_dir}/.${target_base}.tmp.XXXXXX")"; then
        echo "CRITICAL: Failed exclusive temp creation for state '${target_base}'." >&2
        return 1
    fi

    if ! printf '%s\n' "${state_val}" > "${tmp_file}"; then
        echo "CRITICAL: Primary error writing temporary state '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    local last_hex=""
    if ! last_hex="$(tail -c 1 -- "${tmp_file}" | od -An -tx1 | tr -d ' \n')"; then
        echo "CRITICAL: Primary error checking trailing newline on '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi
    if [ "${last_hex}" != "0a" ]; then
        echo "CRITICAL: Primary error: missing trailing newline in '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    local readback=""
    local line_count=""
    if ! IFS= read -r readback < "${tmp_file}"; then
        echo "CRITICAL: Primary error reading back temporary state '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi
    if ! line_count="$(wc -l < "${tmp_file}")"; then
        echo "CRITICAL: Primary error counting lines in '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi
    line_count="${line_count//[[:space:]]/}"
    if [ "${readback}" != "${state_val}" ] || [ "${line_count}" != "1" ]; then
        echo "CRITICAL: Primary error: readback verification failed for '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    if ! sync "${tmp_file}"; then
        echo "CRITICAL: Primary error syncing temporary state '${tmp_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    if ! mv -f -T "${tmp_file}" "${target_file}"; then
        echo "CRITICAL: Primary error renaming '${tmp_file}' to '${target_file}'." >&2
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    if ! sync "${parent_dir}"; then
        echo "CRITICAL: Post-rename durability UNCERTAIN: '${target_file}' may already reflect new state, but sync '${parent_dir}' failed." >&2
        return 2
    fi

    return 0
}

write_bound_state_atomic() {
    local target_file="$1"
    local tx_id="$2"
    local key_name="$3"
    local val="$4"
    local parent_dir="$5"
    local target_base=""
    local target_parent_actual=""
    local tmp_file=""

    if [ ! -d "${parent_dir}" ] || [ -L "${parent_dir}" ]; then
        return 1
    fi
    target_base="$(basename "${target_file}")"
    target_parent_actual="$(cd "$(dirname "${target_file}")" 2>/dev/null && pwd -P)" || return 1
    if [ "${target_parent_actual}" != "${parent_dir}" ] || [ -L "${target_file}" ]; then
        return 1
    fi

    if ! tmp_file="$(mktemp "${parent_dir}/.${target_base}.tmp.XXXXXX")"; then
        return 1
    fi

    if ! printf 'TX_ID=%s\n%s=%s\n' "${tx_id}" "${key_name}" "${val}" > "${tmp_file}"; then
        if ! _cleanup_failed_state_tmp "${tmp_file}"; then
            return 1
        fi
        return 1
    fi

    local expected_content=""
    expected_content="$(printf 'TX_ID=%s\n%s=%s' "${tx_id}" "${key_name}" "${val}")"
    local l1="" l2="" lcount="" last_hex=""
    if ! last_hex="$(tail -c 1 -- "${tmp_file}" | od -An -tx1 | tr -d ' \n')"; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi
    if [ "${last_hex}" != "0a" ]; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi
    lcount="$(wc -l < "${tmp_file}")" || { _cleanup_failed_state_tmp "${tmp_file}"; return 1; }
    lcount="${lcount//[[:space:]]/}"
    if [ "${lcount}" != "2" ]; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi
    {
        IFS= read -r l1
        IFS= read -r l2
    } < "${tmp_file}" || { _cleanup_failed_state_tmp "${tmp_file}"; return 1; }
    if [ "${l1}" != "TX_ID=${tx_id}" ] || [ "${l2}" != "${key_name}=${val}" ]; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi

    if ! sync "${tmp_file}"; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi
    if ! mv -f -T "${tmp_file}" "${target_file}"; then
        _cleanup_failed_state_tmp "${tmp_file}"
        return 1
    fi
    if ! sync "${parent_dir}"; then
        echo "CRITICAL: Post-rename durability UNCERTAIN for bound state '${target_file}' (sync '${parent_dir}' failed)." >&2
        return 2
    fi
    return 0
}

read_bound_state_file() {
    local target_file="$1"
    local expected_tx_id="$2"
    local expected_key="$3"
    local allowed_regex="$4"

    BOUND_VAL=""
    if [ ! -f "${target_file}" ] || [ -L "${target_file}" ] || [ ! -s "${target_file}" ]; then
        return 1
    fi
    local last_hex=""
    last_hex="$(tail -c 1 -- "${target_file}" | od -An -tx1 | tr -d ' \n')" || return 1
    if [ "${last_hex}" != "0a" ]; then
        return 1
    fi
    local lcount=""
    lcount="$(wc -l < "${target_file}")" || return 1
    lcount="${lcount//[[:space:]]/}"
    if [ "${lcount}" != "2" ]; then
        return 1
    fi
    local l1="" l2=""
    {
        IFS= read -r l1
        IFS= read -r l2
    } < "${target_file}" || return 1
    if [[ "${l1}" == *$'\r'* ]] || [[ "${l2}" == *$'\r'* ]]; then
        return 1
    fi
    if [ "${l1}" != "TX_ID=${expected_tx_id}" ]; then
        echo "CRITICAL: Transaction ID mismatch in '${target_file}' ('${l1}' != 'TX_ID=${expected_tx_id}')." >&2
        return 1
    fi
    local key_prefix="${expected_key}="
    if [[ "${l2}" != "${key_prefix}"* ]]; then
        return 1
    fi
    local val="${l2#${key_prefix}}"
    if [[ ! "${val}" =~ ${allowed_regex} ]]; then
        return 1
    fi
    BOUND_VAL="${val}"
    return 0
}

persist_bound_phase_or_halt() {
    local target_file="$1"
    local tx_id="$2"
    local next_state="$3"
    local tx_dir="$4"
    local w_rc=0

    if write_bound_state_atomic "${target_file}" "${tx_id}" "PHASE" "${next_state}" "${tx_dir}"; then
        return 0
    else
        w_rc=$?
    fi
    if [ "${w_rc}" -eq 2 ]; then
        echo "CRITICAL: Halting immediately due to unconfirmed directory sync for '${next_state}'." >&2
        return 2
    fi
    echo "CRITICAL: Pre-rename failure persisting '${next_state}' (exit ${w_rc})." >&2
    return 1
}

_is_path_within_root() {
    local root_real="$1"
    local child_parent_real="$2"
    if [ "${root_real}" = "/" ]; then
        return 1
    fi
    if [ "${child_parent_real}" = "${root_real}" ]; then
        return 0
    fi
    if [[ "${child_parent_real}" == "${root_real}/"* ]]; then
        return 0
    fi
    return 1
}

safe_unlink_if_present() {
    local allowed_root="$1"
    local target="$2"
    local allowed_real=""
    local target_parent_real=""
    local target_base=""

    if [ ! -d "${allowed_root}" ] || [ -L "${allowed_root}" ]; then
        echo "CRITICAL: Allowed root '${allowed_root}' invalid." >&2
        return 1
    fi
    allowed_real="$(cd "${allowed_root}" 2>/dev/null && pwd -P)" || return 1
    if [ "${allowed_real}" = "/" ]; then
        echo "CRITICAL: Allowed root cannot be '/'." >&2
        return 1
    fi

    target_base="$(basename "${target}")"
    if [ -z "${target_base}" ] || [ "${target_base}" = "." ] || [ "${target_base}" = ".." ]; then
        echo "CRITICAL: Unsafe basename on unlink '${target}'." >&2
        return 1
    fi
    if [[ "${target}" == *".."* ]]; then
        echo "CRITICAL: Path traversal component rejected in '${target}'." >&2
        return 1
    fi

    if [ ! -e "${target}" ] && [ ! -L "${target}" ]; then
        return 0
    fi

    target_parent_real="$(cd "$(dirname "${target}")" 2>/dev/null && pwd -P)" || return 1
    if ! _is_path_within_root "${allowed_real}" "${target_parent_real}"; then
        echo "CRITICAL: Path boundary violation on unlink '${target}' outside '${allowed_real}'." >&2
        return 1
    fi

    if ! rm -f -- "${target}"; then
        echo "CRITICAL: Failed removing '${target}'." >&2
        return 1
    fi
    return 0
}

safe_rmdir_if_present() {
    local allowed_root="$1"
    local target_dir="$2"
    local allowed_real=""
    local dir_parent_real=""
    local dir_base=""

    if [ ! -d "${allowed_root}" ] || [ -L "${allowed_root}" ]; then
        return 1
    fi
    allowed_real="$(cd "${allowed_root}" 2>/dev/null && pwd -P)" || return 1
    if [ "${allowed_real}" = "/" ]; then
        return 1
    fi

    dir_base="$(basename "${target_dir}")"
    if [ -z "${dir_base}" ] || [ "${dir_base}" = "." ] || [ "${dir_base}" = ".." ] || [[ "${target_dir}" == *".."* ]]; then
        return 1
    fi

    if [ ! -e "${target_dir}" ] && [ ! -L "${target_dir}" ]; then
        return 0
    fi
    if [ ! -d "${target_dir}" ] || [ -L "${target_dir}" ]; then
        echo "CRITICAL: Expected physical directory at '${target_dir}'." >&2
        return 1
    fi

    dir_parent_real="$(cd "$(dirname "${target_dir}")" 2>/dev/null && pwd -P)" || return 1
    if ! _is_path_within_root "${allowed_real}" "${dir_parent_real}"; then
        echo "CRITICAL: Path boundary violation on rmdir '${target_dir}' outside '${allowed_real}'." >&2
        return 1
    fi

    if ! rmdir -- "${target_dir}"; then
        echo "CRITICAL: Failed rmdir '${target_dir}'." >&2
        return 1
    fi
    return 0
}

restore_artifact_nondestructive() {
    local target_dir="$1"
    local art_name="$2"
    local base_exists="$3"
    local base_sha="$4"
    local stage_sha="$5"
    local backup_dir="$6"
    local tx_id="$7"
    local enforce_mode="$8"

    local canonical="${target_dir}/${art_name}"
    local backup="${backup_dir}/${art_name}"
    local restore_tmp=""

    if [ "${base_exists}" = "1" ]; then
        local cur_sha=""
        if [ -f "${canonical}" ] && [ ! -L "${canonical}" ]; then
            cur_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
        fi
        if [ "${cur_sha}" = "${base_sha}" ]; then
            if [ "${enforce_mode}" != "NONE" ]; then
                if ! chmod "${enforce_mode}" "${canonical}"; then
                    return 1
                fi
            fi
            return 0
        fi

        if [ ! -f "${backup}" ] || [ -L "${backup}" ]; then
            echo "CRITICAL: Required backup '${backup}' missing or symlink." >&2
            return 1
        fi
        local bak_sha=""
        bak_sha="$(sha256sum "${backup}" | cut -d ' ' -f 1)" || return 1
        if [ "${bak_sha}" != "${base_sha}" ]; then
            echo "CRITICAL: Backup '${backup}' SHA-256 mismatch." >&2
            return 1
        fi

        restore_tmp="$(mktemp "${target_dir}/.restore-${art_name}-${tx_id}-XXXXXX")" || return 1
        if ! cp -p "${backup}" "${restore_tmp}"; then
            if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                return 1
            fi
            return 1
        fi
        if [ "${enforce_mode}" != "NONE" ]; then
            if ! chmod "${enforce_mode}" "${restore_tmp}"; then
                if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                    return 1
                fi
                return 1
            fi
        fi
        if ! sync "${restore_tmp}"; then
            if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                return 1
            fi
            return 1
        fi
        local tmp_sha=""
        if ! tmp_sha="$(sha256sum "${restore_tmp}" | cut -d ' ' -f 1)"; then
            if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                return 1
            fi
            return 1
        fi
        if [ "${tmp_sha}" != "${base_sha}" ]; then
            if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                return 1
            fi
            return 1
        fi
        if ! mv -f -T "${restore_tmp}" "${canonical}"; then
            if ! _cleanup_failed_state_tmp "${restore_tmp}"; then
                return 1
            fi
            return 1
        fi
        if ! sync "${canonical}"; then
            return 1
        fi
        if ! sync "${target_dir}"; then
            return 1
        fi
        local restored_sha=""
        restored_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
        if [ "${restored_sha}" != "${base_sha}" ]; then
            return 1
        fi
        return 0
    else
        if [ ! -e "${canonical}" ] && [ ! -L "${canonical}" ]; then
            return 0
        fi
        if [ ! -f "${canonical}" ] || [ -L "${canonical}" ]; then
            echo "CRITICAL: Non-regular file at '${canonical}'." >&2
            return 1
        fi
        local cur_sha=""
        cur_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
        if [ "${cur_sha}" = "${stage_sha}" ]; then
            if ! rm -f -- "${canonical}"; then
                return 1
            fi
            if ! sync "${target_dir}"; then
                return 1
            fi
            return 0
        fi
        echo "CRITICAL: Unexpected file at '${canonical}' does not match staged SHA." >&2
        return 1
    fi
}

# Python O_NOFOLLOW + st_nlink==1 + inode persistence pre-exec flock helper
# Opens dir_fd with O_DIRECTORY|O_NOFOLLOW, lock with O_CREAT|O_RDWR|O_NOFOLLOW, checks st_nlink==1, st_uid==euid,
# acquires flock(LOCK_EX|LOCK_NB), confirms lstat matches fstat inode, dup2s to fd 9, and execvs target command.
exec_with_locked_anchor() {
    local root_dir="$1"
    local lock_name="$2"
    shift 2
    /usr/bin/python3 - "${root_dir}" "${lock_name}" "$@" << 'EOF_LOCK_EXEC'
import fcntl, os, stat, sys
root_dir = sys.argv[1]
lock_name = sys.argv[2]
cmd = sys.argv[3:]
euid = os.geteuid()
try:
    dfd = os.open(root_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError as exc:
    sys.stderr.write(f"RESULT_TOKEN=DIR_INVALID\nCannot open dir {root_dir}: {exc}\n")
    sys.exit(72)
dst = os.fstat(dfd)
# Reject directories not owned by executing UID or writable by group (0o020) or others (0o002)
if dst.st_uid != euid or (dst.st_mode & 0o022) != 0:
    os.close(dfd)
    sys.stderr.write(
        f"RESULT_TOKEN=DIR_UNTRUSTED\n"
        f"Directory {root_dir} must be owned by uid {euid} without group/world write bits (mode={oct(dst.st_mode)})\n"
    )
    sys.exit(72)
try:
    lfd = os.open(lock_name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o640, dir_fd=dfd)
except OSError as exc:
    os.close(dfd)
    sys.stderr.write(f"RESULT_TOKEN=LOCK_OPEN_FAILED\nLock open failed: {exc}\n")
    sys.exit(73)
st = os.fstat(lfd)
if not stat.S_ISREG(st.st_mode):
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write("RESULT_TOKEN=LOCK_NOT_REGULAR\n")
    sys.exit(74)
if st.st_nlink != 1 or st.st_uid != euid:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write(f"RESULT_TOKEN=LOCK_HARDLINK_OR_UID_REJECTED\nnlink={st.st_nlink} uid={st.st_uid}\n")
    sys.exit(74)
try:
    fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write("RESULT_TOKEN=MUTEX_BUSY\n")
    sys.exit(75)
try:
    pst = os.lstat(lock_name, dir_fd=dfd)
except OSError:
    os.close(lfd)
    os.close(dfd)
    sys.stderr.write("RESULT_TOKEN=LOCK_UNLINKED_RACE\n")
    sys.exit(76)
os.close(dfd)
if pst.st_dev != st.st_dev or pst.st_ino != st.st_ino or pst.st_nlink != 1 or not stat.S_ISREG(pst.st_mode):
    os.close(lfd)
    sys.stderr.write("RESULT_TOKEN=LOCK_REPLACED_RACE\n")
    sys.exit(76)
os.dup2(lfd, 9)
if lfd != 9:
    os.close(lfd)
os.set_inheritable(9, True)
os.execv(cmd[0], cmd)
EOF_LOCK_EXEC
}

# Recoverable retired directory cleanup: enforces AUTH_TAG in dir name AND phase-tracked deletion milestones!
cleanup_retired_tx_directory() {
    local root_dir="$1"
    local retired_dir="$2"
    local version="$3"
    local tx_id="$4"
    local supplied_token="$5"
    local auth_tag="$6"

    if [ ! -d "${retired_dir}" ] || [ -L "${retired_dir}" ]; then
        echo "CRITICAL: Retired path '${retired_dir}' invalid." >&2
        return 1
    fi

    # Always verify cryptographic AUTH_TAG bound into retired directory name even if token file was deleted!
    local expected_tag=""
    expected_tag="$(compute_auth_tag "${version}" "${tx_id}" "${supplied_token}")" || return 1
    if [ "${auth_tag}" != "${expected_tag}" ]; then
        echo "Error: Supplied --tx-token fails AUTH_TAG authorization for retired directory '${retired_dir}'." >&2
        return 1
    fi

    local entry=""
    local entries=()
    shopt -s nullglob dotglob
    for entry in "${retired_dir}/"*; do
        entries+=("$(basename "${entry}")")
    done
    shopt -u nullglob dotglob

    # Interrupted strictly after deleting tx_phase before rmdir: dir must be 100% empty
    if [ "${#entries[@]}" -eq 0 ]; then
        safe_rmdir_if_present "${root_dir}" "${retired_dir}" || return 1
        if ! sync "${root_dir}"; then
            echo "CRITICAL: Failed syncing '${root_dir}' after rmdir '${retired_dir}'." >&2
            return 1
        fi
        return 0
    fi

    # Non-empty retired dir MUST contain valid bound tx_phase matching tx_id
    local r_phase_regex="^("
    r_phase_regex+="TX_FINALIZING_CLEANUP_INIT|TX_FINALIZING_UPLOAD_ABORT|"
    r_phase_regex+="TX_FINALIZING_PRUNING_AUX|TX_FINALIZING_PRUNING_TOKEN"
    r_phase_regex+=")$"
    if ! read_bound_state_file "${retired_dir}/tx_phase" "${tx_id}" "PHASE" "${r_phase_regex}"; then
        echo "CRITICAL: Retired directory '${retired_dir}' missing valid bound tx_phase." >&2
        return 1
    fi
    local r_phase="${BOUND_VAL}"

    # Verify NO unexpected files exist anywhere inside retired_dir
    local item=""
    for item in "${entries[@]}"; do
        case "${item}" in
            tx_phase|token|tx_id|manifest.env|status|journal.ART_1|journal.ART_2|journal.ART_3|journal.ART_4|journal.ARCHIVE|journal.SIDECAR)
                ;;
            *)
                echo "CRITICAL: Unexpected entry '${item}' inside retired directory '${retired_dir}'." >&2
                return 1
                ;;
        esac
    done

    # Enforce per-milestone file presence invariants (distinguishing intentionally absent vs unexpected missing)
    case "${r_phase}" in
        TX_FINALIZING_CLEANUP_INIT)
            # Just renamed from post-manifest transaction: ALL core files MUST still exist
            if [ ! -f "${retired_dir}/token" ] || [ -L "${retired_dir}/token" ] || [ ! -f "${retired_dir}/tx_id" ] || [ ! -f "${retired_dir}/manifest.env" ]; then
                echo "CRITICAL: Unexpectedly missing core metadata at phase '${r_phase}' in '${retired_dir}'." >&2
                return 1
            fi
            local tok_val=""
            if ! IFS= read -r tok_val < "${retired_dir}/token"; then
                return 1
            fi
            if [ "${tok_val}" != "${supplied_token}" ]; then
                return 1
            fi
            persist_bound_phase_or_halt "${retired_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_PRUNING_AUX" "${retired_dir}" || return 1
            ;&
        TX_FINALIZING_UPLOAD_ABORT)
            if [ "${r_phase}" = "TX_FINALIZING_UPLOAD_ABORT" ]; then
                if [ ! -f "${retired_dir}/token" ] || [ -L "${retired_dir}/token" ] || [ ! -f "${retired_dir}/tx_id" ]; then
                    echo "CRITICAL: Missing token/tx_id at phase '${r_phase}' in '${retired_dir}'." >&2
                    return 1
                fi
                local u_tok_val=""
                if ! IFS= read -r u_tok_val < "${retired_dir}/token"; then
                    return 1
                fi
                if [ "${u_tok_val}" != "${supplied_token}" ]; then
                    return 1
                fi
                persist_bound_phase_or_halt "${retired_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_PRUNING_AUX" "${retired_dir}" || return 1
            fi
            ;&
        TX_FINALIZING_PRUNING_AUX)
            # Token MUST still exist in PRUNING_AUX (has not entered TOKEN_PRUNING yet!)
            if [ ! -f "${retired_dir}/token" ] || [ -L "${retired_dir}/token" ]; then
                echo "CRITICAL: Token unexpectedly missing/symlink in '${r_phase}' inside '${retired_dir}'." >&2
                return 1
            fi
            local aux_tok_val=""
            if ! IFS= read -r aux_tok_val < "${retired_dir}/token"; then
                return 1
            fi
            if [ "${aux_tok_val}" != "${supplied_token}" ]; then
                echo "CRITICAL: Token mismatch in '${r_phase}' inside '${retired_dir}'." >&2
                return 1
            fi
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/manifest.env" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/tx_id" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.ART_1" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.ART_2" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.ART_3" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.ART_4" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.ARCHIVE" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/journal.SIDECAR" || return 1
            safe_unlink_if_present "${retired_dir}" "${retired_dir}/status" || return 1

            # Enumerate expecting ONLY token & tx_phase before advancing
            local post_aux=()
            shopt -s nullglob dotglob
            for entry in "${retired_dir}/"*; do
                post_aux+=("$(basename "${entry}")")
            done
            shopt -u nullglob dotglob
            local aux_ok=1
            for item in "${post_aux[@]}"; do
                if [ "${item}" != "token" ] && [ "${item}" != "tx_phase" ]; then
                    aux_ok=0
                fi
            done
            if [ "${aux_ok}" -eq 0 ] || [ ! -f "${retired_dir}/token" ] || [ ! -f "${retired_dir}/tx_phase" ]; then
                echo "CRITICAL: Invariant failure before TX_FINALIZING_PRUNING_TOKEN in '${retired_dir}'." >&2
                return 1
            fi
            persist_bound_phase_or_halt "${retired_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_PRUNING_TOKEN" "${retired_dir}" || return 1
            ;&
        TX_FINALIZING_PRUNING_TOKEN)
            # Auxiliary files MUST all be absent here
            for must_gone in manifest.env tx_id journal.ART_1 journal.ART_2 journal.ART_3 journal.ART_4 journal.ARCHIVE journal.SIDECAR status; do
                if [ -e "${retired_dir}/${must_gone}" ] || [ -L "${retired_dir}/${must_gone}" ]; then
                    echo "CRITICAL: Unexpected surviving aux file '${must_gone}' in '${r_phase}'." >&2
                    return 1
                fi
            done
            if [ -e "${retired_dir}/token" ] || [ -L "${retired_dir}/token" ]; then
                if [ ! -f "${retired_dir}/token" ] || [ -L "${retired_dir}/token" ]; then
                    return 1
                fi
                local rem_tok=""
                if ! IFS= read -r rem_tok < "${retired_dir}/token"; then
                    return 1
                fi
                if [ "${rem_tok}" != "${supplied_token}" ]; then
                    echo "CRITICAL: Remaining token mismatch in '${retired_dir}'." >&2
                    return 1
                fi
                safe_unlink_if_present "${retired_dir}" "${retired_dir}/token" || return 1
            fi

            # Enumerate complete contents BEFORE deleting tx_phase: ONLY tx_phase may exist!
            local pre_final=()
            shopt -s nullglob dotglob
            for entry in "${retired_dir}/"*; do
                pre_final+=("$(basename "${entry}")")
            done
            shopt -u nullglob dotglob
            if [ "${#pre_final[@]}" -ne 1 ] || [ "${pre_final[0]}" != "tx_phase" ]; then
                echo "CRITICAL: Unexpected entries before removing tx_phase: ${pre_final[*]}" >&2
                return 1
            fi

            safe_unlink_if_present "${retired_dir}" "${retired_dir}/tx_phase" || return 1

            local final_check=()
            shopt -s nullglob dotglob
            for entry in "${retired_dir}/"*; do
                final_check+=("$(basename "${entry}")")
            done
            shopt -u nullglob dotglob
            if [ "${#final_check[@]}" -ne 0 ]; then
                echo "CRITICAL: Directory '${retired_dir}' not empty after removing tx_phase." >&2
                return 1
            fi

            safe_rmdir_if_present "${root_dir}" "${retired_dir}" || return 1
            if ! sync "${root_dir}"; then
                echo "CRITICAL: Failed syncing '${root_dir}' after retired rmdir." >&2
                return 1
            fi
            return 0
            ;;
    esac
}
