#!/usr/bin/env bash
# Packaging transaction and deliberate recovery prototype.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/design_common.sh"

parse_and_validate_packaging_manifest() {
    local manifest_file="$1"
    local expected_version="$2"
    local expected_tx_id="$3"
    local expected_token="$4"

    if [ ! -f "${manifest_file}" ] || [ -L "${manifest_file}" ] || [ ! -s "${manifest_file}" ]; then
        echo "CRITICAL: Packaging manifest '${manifest_file}' missing, symlink, or empty." >&2
        return 1
    fi

    local last_byte_hex=""
    if ! last_byte_hex="$(tail -c 1 -- "${manifest_file}" | od -An -tx1 | tr -d ' \n')"; then
        return 1
    fi
    if [ "${last_byte_hex}" != "0a" ]; then
        echo "CRITICAL: Packaging manifest '${manifest_file}' missing final newline." >&2
        return 1
    fi

    M_SCHEMA_VERSION=""
    M_TX_ID=""
    M_VERSION=""
    M_SESSION_TOKEN=""
    M_ART_1_NAME=""
    M_ART_1_BASELINE_EXISTS=""
    M_ART_1_BASELINE_SHA=""
    M_ART_1_STAGE_SHA=""
    M_ART_2_NAME=""
    M_ART_2_BASELINE_EXISTS=""
    M_ART_2_BASELINE_SHA=""
    M_ART_2_STAGE_SHA=""
    M_ART_3_NAME=""
    M_ART_3_BASELINE_EXISTS=""
    M_ART_3_BASELINE_SHA=""
    M_ART_3_STAGE_SHA=""
    M_ART_4_NAME=""
    M_ART_4_BASELINE_EXISTS=""
    M_ART_4_BASELINE_SHA=""
    M_ART_4_STAGE_SHA=""

    local s_sch=0 s_tx=0 s_ver=0 s_tok=0
    local s_a1n=0 s_a1e=0 s_a1b=0 s_a1s=0
    local s_a2n=0 s_a2e=0 s_a2b=0 s_a2s=0
    local s_a3n=0 s_a3e=0 s_a3b=0 s_a3s=0
    local s_a4n=0 s_a4e=0 s_a4b=0 s_a4s=0

    local raw_line="" key="" val=""
    while IFS= read -r raw_line; do
        if [[ "${raw_line}" == *$'\r'* ]] || [[ -z "${raw_line}" ]] || [[ "${raw_line}" == \#* ]] || [[ "${raw_line}" != *"="* ]]; then
            echo "CRITICAL: Malformed packaging manifest line." >&2
            return 1
        fi
        key="${raw_line%%=*}"
        val="${raw_line#*=}"
        [ -n "${val}" ] || return 1

        case "${key}" in
            SCHEMA_VERSION)
                [ "${s_sch}" -eq 0 ] || return 1; s_sch=1
                [ "${val}" = "1" ] || return 1
                M_SCHEMA_VERSION="${val}"
                ;;
            TX_ID)
                [ "${s_tx}" -eq 0 ] || return 1; s_tx=1
                [[ "${val}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}$ ]] || return 1
                if [ "${val}" != "${expected_tx_id}" ]; then
                    echo "CRITICAL: Manifest TX_ID '${val}' != expected '${expected_tx_id}'." >&2
                    return 1
                fi
                M_TX_ID="${val}"
                ;;
            VERSION)
                [ "${s_ver}" -eq 0 ] || return 1; s_ver=1
                [[ "${val}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [[ "${val}" != *".."* ]] || return 1
                if [ "${val}" != "${expected_version}" ]; then
                    echo "CRITICAL: Manifest VERSION '${val}' != expected '${expected_version}'." >&2
                    return 1
                fi
                M_VERSION="${val}"
                ;;
            SESSION_TOKEN)
                [ "${s_tok}" -eq 0 ] || return 1; s_tok=1
                [[ "${val}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$ ]] || return 1
                if [ "${val}" != "${expected_token}" ]; then
                    echo "CRITICAL: Manifest SESSION_TOKEN mismatch against expected bearer token." >&2
                    return 1
                fi
                M_SESSION_TOKEN="${val}"
                ;;
            ART_1_NAME)
                [ "${s_a1n}" -eq 0 ] || return 1; s_a1n=1
                [ "${val}" = "git-repo-analyzer-release-${expected_version}.tar.gz" ] || return 1
                M_ART_1_NAME="${val}"
                ;;
            ART_1_BASELINE_EXISTS) [ "${s_a1e}" -eq 0 ] || return 1; s_a1e=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; M_ART_1_BASELINE_EXISTS="${val}" ;;
            ART_1_BASELINE_SHA) [ "${s_a1b}" -eq 0 ] || return 1; s_a1b=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; M_ART_1_BASELINE_SHA="${val}" ;;
            ART_1_STAGE_SHA) [ "${s_a1s}" -eq 0 ] || return 1; s_a1s=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; M_ART_1_STAGE_SHA="${val}" ;;
            ART_2_NAME)
                [ "${s_a2n}" -eq 0 ] || return 1; s_a2n=1
                [ "${val}" = "git-repo-analyzer-release-${expected_version}.tar.gz.sha256" ] || return 1
                M_ART_2_NAME="${val}"
                ;;
            ART_2_BASELINE_EXISTS) [ "${s_a2e}" -eq 0 ] || return 1; s_a2e=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; M_ART_2_BASELINE_EXISTS="${val}" ;;
            ART_2_BASELINE_SHA) [ "${s_a2b}" -eq 0 ] || return 1; s_a2b=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; M_ART_2_BASELINE_SHA="${val}" ;;
            ART_2_STAGE_SHA) [ "${s_a2s}" -eq 0 ] || return 1; s_a2s=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; M_ART_2_STAGE_SHA="${val}" ;;
            ART_3_NAME)
                [ "${s_a3n}" -eq 0 ] || return 1; s_a3n=1
                [ "${val}" = "${expected_version}.tar.gz" ] || return 1
                M_ART_3_NAME="${val}"
                ;;
            ART_3_BASELINE_EXISTS) [ "${s_a3e}" -eq 0 ] || return 1; s_a3e=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; M_ART_3_BASELINE_EXISTS="${val}" ;;
            ART_3_BASELINE_SHA) [ "${s_a3b}" -eq 0 ] || return 1; s_a3b=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; M_ART_3_BASELINE_SHA="${val}" ;;
            ART_3_STAGE_SHA) [ "${s_a3s}" -eq 0 ] || return 1; s_a3s=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; M_ART_3_STAGE_SHA="${val}" ;;
            ART_4_NAME)
                [ "${s_a4n}" -eq 0 ] || return 1; s_a4n=1
                [ "${val}" = "${expected_version}.tar.gz.sha256" ] || return 1
                M_ART_4_NAME="${val}"
                ;;
            ART_4_BASELINE_EXISTS) [ "${s_a4e}" -eq 0 ] || return 1; s_a4e=1; [[ "${val}" =~ ^(0|1)$ ]] || return 1; M_ART_4_BASELINE_EXISTS="${val}" ;;
            ART_4_BASELINE_SHA) [ "${s_a4b}" -eq 0 ] || return 1; s_a4b=1; [[ "${val}" =~ ^([0-9a-f]{64}|NONE)$ ]] || return 1; M_ART_4_BASELINE_SHA="${val}" ;;
            ART_4_STAGE_SHA) [ "${s_a4s}" -eq 0 ] || return 1; s_a4s=1; [[ "${val}" =~ ^[0-9a-f]{64}$ ]] || return 1; M_ART_4_STAGE_SHA="${val}" ;;
            *) return 1 ;;
        esac
    done < "${manifest_file}"

    local total_seen=$((s_sch + s_tx + s_ver + s_tok + s_a1n + s_a1e + s_a1b + s_a1s + s_a2n + s_a2e + s_a2b + s_a2s + s_a3n + s_a3e + s_a3b + s_a3s + s_a4n + s_a4e + s_a4b + s_a4s))
    [ "${total_seen}" -eq 20 ] || return 1

    if [ "${M_ART_1_BASELINE_EXISTS}" = "1" ] && [ "${M_ART_1_BASELINE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${M_ART_1_BASELINE_EXISTS}" = "0" ] && [ "${M_ART_1_BASELINE_SHA}" != "NONE" ]; then return 1; fi
    if [ "${M_ART_2_BASELINE_EXISTS}" = "1" ] && [ "${M_ART_2_BASELINE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${M_ART_2_BASELINE_EXISTS}" = "0" ] && [ "${M_ART_2_BASELINE_SHA}" != "NONE" ]; then return 1; fi
    if [ "${M_ART_3_BASELINE_EXISTS}" = "1" ] && [ "${M_ART_3_BASELINE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${M_ART_3_BASELINE_EXISTS}" = "0" ] && [ "${M_ART_3_BASELINE_SHA}" != "NONE" ]; then return 1; fi
    if [ "${M_ART_4_BASELINE_EXISTS}" = "1" ] && [ "${M_ART_4_BASELINE_SHA}" = "NONE" ]; then return 1; fi
    if [ "${M_ART_4_BASELINE_EXISTS}" = "0" ] && [ "${M_ART_4_BASELINE_SHA}" != "NONE" ]; then return 1; fi

    return 0
}

reconcile_one_pkg_artifact() {
    local output_real="$1"
    local tx_dir="$2"
    local art_name="$3"
    local base_exists="$4"
    local base_sha="$5"
    local stage_sha="$6"
    local j_state="$7"

    local canonical="${output_real}/${art_name}"
    local cur_sha=""

    case "${j_state}" in
        UNINITIALIZED|BASELINE_INSPECTED)
            if [ "${base_exists}" = "1" ]; then
                [ -f "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
                cur_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
                [ "${cur_sha}" = "${base_sha}" ] || return 1
            else
                [ ! -e "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
            fi
            return 0
            ;;
        BACKUP_INTENT|BACKUP_CREATED|BACKUP_DATA_SYNCED|BACKUP_DIR_SYNCED)
            [ "${base_exists}" = "1" ] || return 1
            [ -f "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
            cur_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
            [ "${cur_sha}" = "${base_sha}" ] || return 1
            return 0
            ;;
        PROMOTE_INTENT|CANONICAL_REPLACED)
            restore_artifact_nondestructive \
                "${output_real}" \
                "${art_name}" \
                "${base_exists}" \
                "${base_sha}" \
                "${stage_sha}" \
                "${tx_dir}/backup" \
                "${M_TX_ID}" \
                "NONE" || return 1
            return 0
            ;;
        CANONICAL_DIR_SYNCED|PROMOTED_VERIFIED)
            restore_artifact_nondestructive \
                "${output_real}" \
                "${art_name}" \
                "${base_exists}" \
                "${base_sha}" \
                "${stage_sha}" \
                "${tx_dir}/backup" \
                "${M_TX_ID}" \
                "NONE" || return 1
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

reconcile_all_packaging_artifacts() {
    local output_real="$1"
    local tx_dir="$2"
    local expected_tx_id="$3"

    local allowed_states="^("
    allowed_states+="UNINITIALIZED|BASELINE_INSPECTED|"
    allowed_states+="BACKUP_INTENT|BACKUP_CREATED|BACKUP_DATA_SYNCED|BACKUP_DIR_SYNCED|"
    allowed_states+="PROMOTE_INTENT|CANONICAL_REPLACED|CANONICAL_DIR_SYNCED|PROMOTED_VERIFIED"
    allowed_states+=")$"

    read_bound_state_file "${tx_dir}/journal.ART_1" "${expected_tx_id}" "STATE" "${allowed_states}" || return 1
    local j1="${BOUND_VAL}"
    read_bound_state_file "${tx_dir}/journal.ART_2" "${expected_tx_id}" "STATE" "${allowed_states}" || return 1
    local j2="${BOUND_VAL}"
    read_bound_state_file "${tx_dir}/journal.ART_3" "${expected_tx_id}" "STATE" "${allowed_states}" || return 1
    local j3="${BOUND_VAL}"
    read_bound_state_file "${tx_dir}/journal.ART_4" "${expected_tx_id}" "STATE" "${allowed_states}" || return 1
    local j4="${BOUND_VAL}"

    local ok=1
    if ! reconcile_one_pkg_artifact \
        "${output_real}" \
        "${tx_dir}" \
        "${M_ART_1_NAME}" \
        "${M_ART_1_BASELINE_EXISTS}" \
        "${M_ART_1_BASELINE_SHA}" \
        "${M_ART_1_STAGE_SHA}" \
        "${j1}"; then
        ok=0
    fi
    if ! reconcile_one_pkg_artifact \
        "${output_real}" \
        "${tx_dir}" \
        "${M_ART_2_NAME}" \
        "${M_ART_2_BASELINE_EXISTS}" \
        "${M_ART_2_BASELINE_SHA}" \
        "${M_ART_2_STAGE_SHA}" \
        "${j2}"; then
        ok=0
    fi
    if ! reconcile_one_pkg_artifact \
        "${output_real}" \
        "${tx_dir}" \
        "${M_ART_3_NAME}" \
        "${M_ART_3_BASELINE_EXISTS}" \
        "${M_ART_3_BASELINE_SHA}" \
        "${M_ART_3_STAGE_SHA}" \
        "${j3}"; then
        ok=0
    fi
    if ! reconcile_one_pkg_artifact \
        "${output_real}" \
        "${tx_dir}" \
        "${M_ART_4_NAME}" \
        "${M_ART_4_BASELINE_EXISTS}" \
        "${M_ART_4_BASELINE_SHA}" \
        "${M_ART_4_STAGE_SHA}" \
        "${j4}"; then
        ok=0
    fi

    [ "${ok}" -eq 1 ] || return 1
    return 0
}

verify_one_canonical_baseline_only() {
    local output_real="$1"
    local art_name="$2"
    local base_exists="$3"
    local base_sha="$4"
    local canonical="${output_real}/${art_name}"

    if [ "${base_exists}" = "1" ]; then
        [ -f "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
        local cur_sha=""
        cur_sha="$(sha256sum "${canonical}" | cut -d ' ' -f 1)" || return 1
        [ "${cur_sha}" = "${base_sha}" ] || return 1
        return 0
    else
        [ ! -e "${canonical}" ] && [ ! -L "${canonical}" ] || return 1
        return 0
    fi
}

verify_all_canonical_baseline_only() {
    local output_real="$1"
    local ok=1

    if ! verify_one_canonical_baseline_only \
        "${output_real}" \
        "${M_ART_1_NAME}" \
        "${M_ART_1_BASELINE_EXISTS}" \
        "${M_ART_1_BASELINE_SHA}"; then
        ok=0
    fi
    if ! verify_one_canonical_baseline_only \
        "${output_real}" \
        "${M_ART_2_NAME}" \
        "${M_ART_2_BASELINE_EXISTS}" \
        "${M_ART_2_BASELINE_SHA}"; then
        ok=0
    fi
    if ! verify_one_canonical_baseline_only \
        "${output_real}" \
        "${M_ART_3_NAME}" \
        "${M_ART_3_BASELINE_EXISTS}" \
        "${M_ART_3_BASELINE_SHA}"; then
        ok=0
    fi
    if ! verify_one_canonical_baseline_only \
        "${output_real}" \
        "${M_ART_4_NAME}" \
        "${M_ART_4_BASELINE_EXISTS}" \
        "${M_ART_4_BASELINE_SHA}"; then
        ok=0
    fi

    [ "${ok}" -eq 1 ] || return 1
    return 0
}

finalize_packaging_after_verified_rollback() {
    local output_real="$1"
    local tx_dir="$2"
    local version="$3"
    local tx_id="$4"
    local token="$5"

    local auth_tag=""
    auth_tag="$(compute_auth_tag "${version}" "${tx_id}" "${token}")" || return 1
    local retired_dir="${output_real}/.pkg-tx-retired-${version}-${tx_id}-${auth_tag}"

    if ! verify_all_canonical_baseline_only "${output_real}"; then
        echo "CRITICAL: Canonical verification failed during pruning; halting." >&2
        if ! persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_dir}"; then
            echo "CRITICAL: Failed writing TX_RECOVERY_REQUIRED marker into '${tx_dir}'." >&2
        fi
        return 1
    fi

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_PRUNING_AFTER_ROLLBACK" "${tx_dir}" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_1_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_2_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_3_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_4_NAME}" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/backup" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_1_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_2_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_3_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_4_NAME}" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/stage" || return 1

    if ! sync "${tx_dir}"; then
        return 1
    fi

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_CLEANUP_INIT" "${tx_dir}" || return 1

    if [ -e "${retired_dir}" ] || [ -L "${retired_dir}" ]; then
        echo "CRITICAL: Retired target '${retired_dir}' already exists." >&2
        return 1
    fi
    if ! mv -f -T "${tx_dir}" "${retired_dir}"; then
        return 1
    fi
    if ! sync "${output_real}"; then
        echo "CRITICAL: Post-rename directory sync failed on '${output_real}'; durability unconfirmed." >&2
        return 2
    fi

    cleanup_retired_tx_directory "${output_real}" "${retired_dir}" "${version}" "${tx_id}" "${token}" "${auth_tag}" || return 1
    return 0
}

finalize_packaging_after_commit() {
    local output_real="$1"
    local tx_dir="$2"
    local version="$3"
    local tx_id="$4"
    local token="$5"

    local auth_tag=""
    auth_tag="$(compute_auth_tag "${version}" "${tx_id}" "${token}")" || return 1
    local retired_dir="${output_real}/.pkg-tx-retired-${version}-${tx_id}-${auth_tag}"

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_PRUNING_AFTER_COMMIT" "${tx_dir}" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_1_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_2_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_3_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/backup/${M_ART_4_NAME}" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/backup" || return 1

    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_1_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_2_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_3_NAME}" || return 1
    safe_unlink_if_present "${tx_dir}" "${tx_dir}/stage/${M_ART_4_NAME}" || return 1
    safe_rmdir_if_present "${tx_dir}" "${tx_dir}/stage" || return 1

    if ! sync "${tx_dir}"; then
        return 1
    fi

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_FINALIZING_CLEANUP_INIT" "${tx_dir}" || return 1

    if [ -e "${retired_dir}" ] || [ -L "${retired_dir}" ]; then
        return 1
    fi
    if ! mv -f -T "${tx_dir}" "${retired_dir}"; then
        return 1
    fi
    if ! sync "${output_real}"; then
        return 2
    fi

    cleanup_retired_tx_directory "${output_real}" "${retired_dir}" "${version}" "${tx_id}" "${token}" "${auth_tag}" || return 1
    return 0
}

recover_packaging_locked_worker() {
    local output_real="$1"
    local tx_or_retired="$2"
    local supplied_token="$3"
    local path_kind="$4"
    local ver="$5"
    local tx_id="$6"
    local auth_tag="${7:-NONE}"

    # Under FD 9 flock, reject conflicting or malformed sibling active/retired directories for ver
    local cand="" base=""
    local active_hits=()
    local retired_hits=()
    local pkg_act_re="^\.pkg-tx-${ver}-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}$"
    local pkg_ret_re="^\.pkg-tx-retired-${ver}-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}-[0-9a-f]{32}$"
    shopt -s nullglob dotglob
    for cand in "${output_real}/.pkg-tx-${ver}-"* "${output_real}/.pkg-tx-retired-${ver}-"*; do
        base="$(basename "${cand}")"
        if [[ "${base}" == ".pkg-tx-retired-${ver}-"* ]]; then
            if [[ ! "${base}" =~ ${pkg_ret_re} ]]; then
                echo "CRITICAL: Malformed retired directory '${base}'." >&2
                return 1
            fi
            retired_hits+=("${cand}")
        elif [[ "${base}" == ".pkg-tx-${ver}-"* ]]; then
            if [[ ! "${base}" =~ ${pkg_act_re} ]]; then
                echo "CRITICAL: Malformed active directory '${base}'." >&2
                return 1
            fi
            active_hits+=("${cand}")
        fi
    done
    shopt -u nullglob dotglob

    if [ "${#active_hits[@]}" -gt 0 ] && [ "${#retired_hits[@]}" -gt 0 ]; then
        echo "CRITICAL: Conflicting active and retired packaging directories exist for '${ver}'." >&2
        return 1
    fi
    if [ "${#active_hits[@]}" -gt 1 ] || [ "${#retired_hits[@]}" -gt 1 ]; then
        echo "CRITICAL: Multiple conflicting transaction directories exist for '${ver}'." >&2
        return 1
    fi

    if [ "${path_kind}" = "RETIRED" ]; then
        if [ ! -d "${tx_or_retired}" ] || [ -L "${tx_or_retired}" ]; then
            return 1
        fi
        if [ -e "${tx_or_retired}/token" ] || [ -L "${tx_or_retired}/token" ]; then
            if [ ! -f "${tx_or_retired}/token" ] || [ -L "${tx_or_retired}/token" ]; then
                return 1
            fi
            local ret_tok=""
            if ! IFS= read -r ret_tok < "${tx_or_retired}/token"; then
                return 1
            fi
            if [ "${ret_tok}" != "${supplied_token}" ]; then
                echo "Error: Supplied --tx-token does not match remaining token in '${tx_or_retired}'." >&2
                return 1
            fi
        fi
        cleanup_retired_tx_directory "${output_real}" "${tx_or_retired}" "${ver}" "${tx_id}" "${supplied_token}" "${auth_tag}" || return 1
        return 0
    fi

    # PATH A: Active Packaging TX Recovery
    if [ ! -d "${tx_or_retired}" ] || [ -L "${tx_or_retired}" ]; then
        return 1
    fi
    if [ ! -f "${tx_or_retired}/token" ] || [ -L "${tx_or_retired}/token" ] || [ ! -s "${tx_or_retired}/token" ]; then
        echo "CRITICAL: Active TX '${tx_or_retired}' missing valid token." >&2
        return 1
    fi
    local stored_tok=""
    IFS= read -r stored_tok < "${tx_or_retired}/token" || return 1
    if [ "${stored_tok}" != "${supplied_token}" ]; then
        echo "Error: Supplied --tx-token does not match active TX '${tx_or_retired}'." >&2
        return 1
    fi

    if [ ! -f "${tx_or_retired}/tx_id" ] || [ -L "${tx_or_retired}/tx_id" ]; then
        echo "CRITICAL: Active TX '${tx_or_retired}' missing tx_id marker." >&2
        return 1
    fi
    local stored_tx_id=""
    IFS= read -r stored_tx_id < "${tx_or_retired}/tx_id" || return 1
    if [ "${stored_tx_id}" != "${tx_id}" ]; then
        echo "CRITICAL: Active TX '${tx_or_retired}' mismatched tx_id marker ('${stored_tx_id}' != '${tx_id}')." >&2
        return 1
    fi

    if ! parse_and_validate_packaging_manifest "${tx_or_retired}/manifest.env" "${ver}" "${tx_id}" "${supplied_token}"; then
        echo "CRITICAL: Packaging manifest corrupt or tampered inside '${tx_or_retired}'." >&2
        if ! persist_bound_phase_or_halt "${tx_or_retired}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_or_retired}"; then
            echo "CRITICAL: Failed persisting TX_RECOVERY_REQUIRED marker." >&2
        fi
        return 1
    fi

    local p_regex="^("
    p_regex+="TX_INITIALIZED|TX_BACKUPS_READY|TX_PROMOTING|TX_VALIDATED|"
    p_regex+="TX_COMMITTED|TX_PRUNING_AFTER_COMMIT|TX_ROLLING_BACK|"
    p_regex+="TX_ROLLED_BACK_VERIFIED|TX_PRUNING_AFTER_ROLLBACK|"
    p_regex+="TX_FINALIZING_CLEANUP_INIT|TX_RECOVERY_REQUIRED"
    p_regex+=")$"
    if ! read_bound_state_file "${tx_or_retired}/tx_phase" "${tx_id}" "PHASE" "${p_regex}"; then
        echo "CRITICAL: Invalid or missing bound tx_phase inside '${tx_or_retired}'." >&2
        if ! persist_bound_phase_or_halt "${tx_or_retired}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_or_retired}"; then
            echo "CRITICAL: Failed writing TX_RECOVERY_REQUIRED marker." >&2
        fi
        return 1
    fi
    local phase="${BOUND_VAL}"

    case "${phase}" in
        TX_COMMITTED|TX_PRUNING_AFTER_COMMIT|TX_FINALIZING_CLEANUP_INIT)
            finalize_packaging_after_commit "${output_real}" "${tx_or_retired}" "${ver}" "${tx_id}" "${supplied_token}" || return 1
            return 0
            ;;
        TX_ROLLED_BACK_VERIFIED|TX_PRUNING_AFTER_ROLLBACK)
            finalize_packaging_after_verified_rollback "${output_real}" "${tx_or_retired}" "${ver}" "${tx_id}" "${supplied_token}" || return 1
            return 0
            ;;
        TX_INITIALIZED|TX_BACKUPS_READY|TX_PROMOTING|TX_VALIDATED|TX_ROLLING_BACK|TX_RECOVERY_REQUIRED)
            if ! reconcile_all_packaging_artifacts "${output_real}" "${tx_or_retired}" "${tx_id}"; then
                if ! persist_bound_phase_or_halt "${tx_or_retired}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_or_retired}"; then
                    echo "CRITICAL: Failed writing TX_RECOVERY_REQUIRED marker." >&2
                fi
                return 1
            fi
            if ! persist_bound_phase_or_halt "${tx_or_retired}/tx_phase" "${tx_id}" "TX_ROLLED_BACK_VERIFIED" "${tx_or_retired}"; then
                if ! persist_bound_phase_or_halt "${tx_or_retired}/tx_phase" "${tx_id}" "TX_RECOVERY_REQUIRED" "${tx_or_retired}"; then
                    echo "CRITICAL: Failed writing TX_RECOVERY_REQUIRED marker." >&2
                fi
                return 1
            fi
            finalize_packaging_after_verified_rollback "${output_real}" "${tx_or_retired}" "${ver}" "${tx_id}" "${supplied_token}" || return 1
            return 0
            ;;
    esac
}

recover_packaging_entry() {
    local output_dir="$1"
    local tx_or_retired="$2"
    local supplied_token="$3"

    if [[ ! "${supplied_token}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$ ]]; then
        echo "Error: Invalid --tx-token format." >&2
        return 1
    fi
    if [ ! -d "${output_dir}" ] || [ -L "${output_dir}" ]; then
        echo "Error: OUTPUT_DIR must exist as a physical directory." >&2
        return 1
    fi
    local output_real=""
    output_real="$(cd "${output_dir}" && pwd -P)" || return 1
    validate_canonical_path "${output_real}" "OUTPUT_DIR" || return 1

    local parent_raw="" parent_real="" base=""
    parent_raw="$(dirname "${tx_or_retired}")"
    if [ ! -d "${parent_raw}" ] || [ -L "${parent_raw}" ]; then
        return 1
    fi
    parent_real="$(cd "${parent_raw}" && pwd -P)" || return 1
    if [ "${parent_real}" != "${output_real}" ]; then
        echo "Error: Recovery directory must reside directly inside OUTPUT_DIR." >&2
        return 1
    fi

    base="$(basename "${tx_or_retired}")"
    local path_kind="" lock_version="" lock_tx_id="" lock_auth_tag="NONE"
    if [[ "${base}" =~ ^\.pkg-tx-retired-([A-Za-z0-9][A-Za-z0-9._-]{0,127})-([0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16})-([0-9a-f]{32})$ ]]; then
        path_kind="RETIRED"
        lock_version="${BASH_REMATCH[1]}"
        lock_tx_id="${BASH_REMATCH[2]}"
        lock_auth_tag="${BASH_REMATCH[3]}"
    elif [[ "${base}" =~ ^\.pkg-tx-([A-Za-z0-9][A-Za-z0-9._-]{0,127})-([0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16})$ ]]; then
        path_kind="ACTIVE"
        lock_version="${BASH_REMATCH[1]}"
        lock_tx_id="${BASH_REMATCH[2]}"
    else
        echo "Error: Invalid transaction directory name '${base}'." >&2
        return 1
    fi
    if [[ "${lock_version}" == *".."* ]]; then
        return 1
    fi

    # Acquire lock anchored strictly by CLI-derived lock_version BEFORE reading TX metadata
    exec_with_locked_anchor "${output_real}" ".gra-pkg-${lock_version}.flock" \
        "/bin/bash" "${SCRIPT_SELF}" "--internal-locked-recover" \
        "${output_real}" "${tx_or_retired}" "${supplied_token}" "${path_kind}" "${lock_version}" "${lock_tx_id}" "${lock_auth_tag}"
}

run_locked_packaging_worker() {
    local output_real="$1"
    local ver="$2"
    local bundle_dir="$3"
    local tx_id="$4"
    local token="$5"

    # Refuse if any existing active or retired directory exists for ver
    local cand=""
    shopt -s nullglob dotglob
    for cand in "${output_real}/.pkg-tx-${ver}-"* "${output_real}/.pkg-tx-retired-${ver}-"*; do
        if [ -e "${cand}" ] || [ -L "${cand}" ]; then
            echo "Error: Unresolved transaction '${cand}' exists for version '${ver}'; run --recover first." >&2
            exec 9>&-
            return 1
        fi
    done
    shopt -u nullglob dotglob

    local tx_dir="${output_real}/.pkg-tx-${ver}-${tx_id}"
    mkdir -- "${tx_dir}" && chmod 0700 "${tx_dir}"
    mkdir -- "${tx_dir}/stage" "${tx_dir}/backup"
    write_state_atomic "${tx_dir}/token" "${token}" "${tx_dir}"
    write_state_atomic "${tx_dir}/tx_id" "${tx_id}" "${tx_dir}"

    local p_arch="git-repo-analyzer-release-${ver}.tar.gz"
    local p_side="${p_arch}.sha256"
    local c_arch="${ver}.tar.gz"
    local c_side="${c_arch}.sha256"

    # Populate staged artifacts inside tx_dir/stage
    tar -czf "${tx_dir}/stage/${p_arch}" -C "${bundle_dir}" .
    ln -f "${tx_dir}/stage/${p_arch}" "${tx_dir}/stage/${c_arch}"
    (
        cd "${tx_dir}/stage"
        sha256sum "${p_arch}" > "${p_side}"
        sha256sum "${c_arch}" > "${c_side}"
        sha256sum -c --strict "${p_side}" >/dev/null
        sha256sum -c --strict "${c_side}" >/dev/null
    )

    local s1 s2 s3 s4
    s1="$(sha256sum "${tx_dir}/stage/${p_arch}" | cut -d ' ' -f 1)"
    s2="$(sha256sum "${tx_dir}/stage/${p_side}" | cut -d ' ' -f 1)"
    s3="$(sha256sum "${tx_dir}/stage/${c_arch}" | cut -d ' ' -f 1)"
    s4="$(sha256sum "${tx_dir}/stage/${c_side}" | cut -d ' ' -f 1)"

    local e1=0 b1="NONE" e2=0 b2="NONE" e3=0 b3="NONE" e4=0 b4="NONE"
    [ -f "${output_real}/${p_arch}" ] && { e1=1; b1="$(sha256sum "${output_real}/${p_arch}" | cut -d ' ' -f 1)"; }
    [ -f "${output_real}/${p_side}" ] && { e2=1; b2="$(sha256sum "${output_real}/${p_side}" | cut -d ' ' -f 1)"; }
    [ -f "${output_real}/${c_arch}" ] && { e3=1; b3="$(sha256sum "${output_real}/${c_arch}" | cut -d ' ' -f 1)"; }
    [ -f "${output_real}/${c_side}" ] && { e4=1; b4="$(sha256sum "${output_real}/${c_side}" | cut -d ' ' -f 1)"; }

    local mf_tmp=""
    mf_tmp="$(mktemp "${tx_dir}/.manifest.env.tmp.XXXXXX")"
    printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=%s\nSESSION_TOKEN=%s\n' "${tx_id}" "${ver}" "${token}" > "${mf_tmp}"
    printf 'ART_1_NAME=%s\nART_1_BASELINE_EXISTS=%s\nART_1_BASELINE_SHA=%s\nART_1_STAGE_SHA=%s\n' "${p_arch}" "${e1}" "${b1}" "${s1}" >> "${mf_tmp}"
    printf 'ART_2_NAME=%s\nART_2_BASELINE_EXISTS=%s\nART_2_BASELINE_SHA=%s\nART_2_STAGE_SHA=%s\n' "${p_side}" "${e2}" "${b2}" "${s2}" >> "${mf_tmp}"
    printf 'ART_3_NAME=%s\nART_3_BASELINE_EXISTS=%s\nART_3_BASELINE_SHA=%s\nART_3_STAGE_SHA=%s\n' "${c_arch}" "${e3}" "${b3}" "${s3}" >> "${mf_tmp}"
    printf 'ART_4_NAME=%s\nART_4_BASELINE_EXISTS=%s\nART_4_BASELINE_SHA=%s\nART_4_STAGE_SHA=%s\n' "${c_side}" "${e4}" "${b4}" "${s4}" >> "${mf_tmp}"
    sync "${mf_tmp}"
    mv -f -T "${mf_tmp}" "${tx_dir}/manifest.env"
    sync "${tx_dir}"

    parse_and_validate_packaging_manifest "${tx_dir}/manifest.env" "${ver}" "${tx_id}" "${token}"

    write_bound_state_atomic "${tx_dir}/journal.ART_1" "${tx_id}" "STATE" "BASELINE_INSPECTED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_2" "${tx_id}" "STATE" "BASELINE_INSPECTED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_3" "${tx_id}" "STATE" "BASELINE_INSPECTED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_4" "${tx_id}" "STATE" "BASELINE_INSPECTED" "${tx_dir}"
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_INITIALIZED" "${tx_dir}"

    # Setup automatic rollback trap using explicit global variables (survive function exit under set -u)
    PKG_TRAP_DONE=0
    PKG_ORIG_CODE=0
    PKG_TRAP_OUT="${output_real}"
    PKG_TRAP_TX_DIR="${tx_dir}"
    PKG_TRAP_VER="${ver}"
    PKG_TRAP_TX_ID="${tx_id}"
    PKG_TRAP_TOK="${token}"

    pkg_exit_trap() {
        local rc=$?
        [ "${PKG_TRAP_DONE}" -eq 0 ] || return 0
        PKG_TRAP_DONE=1
        trap '' INT TERM HUP
        [ "${PKG_ORIG_CODE}" -ne 0 ] && rc="${PKG_ORIG_CODE}"
        if [ ! -e "${PKG_TRAP_TX_DIR}" ] && [ ! -L "${PKG_TRAP_TX_DIR}" ]; then
            exec 9>&-
            exit "${rc}"
        fi
        local ph="MISSING"
        if read_bound_state_file "${PKG_TRAP_TX_DIR}/tx_phase" "${PKG_TRAP_TX_ID}" "PHASE" "^[A-Z0-9_]+$" 2>/dev/null; then
            ph="${BOUND_VAL}"
        fi
        case "${ph}" in
            TX_COMMITTED|TX_PRUNING_AFTER_COMMIT|TX_FINALIZING_CLEANUP_INIT)
                finalize_packaging_after_commit "${PKG_TRAP_OUT}" "${PKG_TRAP_TX_DIR}" "${PKG_TRAP_VER}" "${PKG_TRAP_TX_ID}" "${PKG_TRAP_TOK}" || { exec 9>&-; exit 1; }
                exec 9>&-
                exit 0
                ;;
            TX_INITIALIZED|TX_BACKUPS_READY|TX_PROMOTING|TX_VALIDATED)
                if ! reconcile_all_packaging_artifacts "${PKG_TRAP_OUT}" "${PKG_TRAP_TX_DIR}" "${PKG_TRAP_TX_ID}"; then
                    if ! persist_bound_phase_or_halt "${PKG_TRAP_TX_DIR}/tx_phase" "${PKG_TRAP_TX_ID}" "TX_RECOVERY_REQUIRED" "${PKG_TRAP_TX_DIR}"; then
                        echo "CRITICAL: Failed persisting TX_RECOVERY_REQUIRED." >&2
                    fi
                    exec 9>&-
                    exit 1
                fi
                persist_bound_phase_or_halt "${PKG_TRAP_TX_DIR}/tx_phase" "${PKG_TRAP_TX_ID}" "TX_ROLLED_BACK_VERIFIED" "${PKG_TRAP_TX_DIR}" || { exec 9>&-; exit 1; }
                finalize_packaging_after_verified_rollback "${PKG_TRAP_OUT}" "${PKG_TRAP_TX_DIR}" "${PKG_TRAP_VER}" "${PKG_TRAP_TX_ID}" "${PKG_TRAP_TOK}" || { exec 9>&-; exit 1; }
                exec 9>&-
                [ "${rc}" -eq 0 ] && rc=1
                exit "${rc}"
                ;;
            *)
                if ! persist_bound_phase_or_halt "${PKG_TRAP_TX_DIR}/tx_phase" "${PKG_TRAP_TX_ID}" "TX_RECOVERY_REQUIRED" "${PKG_TRAP_TX_DIR}"; then
                    echo "CRITICAL: Failed persisting TX_RECOVERY_REQUIRED." >&2
                fi
                exec 9>&-
                exit 1
                ;;
        esac
    }
    trap 'PKG_ORIG_CODE=130; exit 130' INT
    trap 'PKG_ORIG_CODE=143; exit 143' TERM
    trap 'PKG_ORIG_CODE=129; exit 129' HUP
    trap 'pkg_exit_trap' EXIT

    # Backups
    for idx in 1 2 3 4; do
        local an="${p_arch}" ae="${e1}" bs="${b1}" jf="${tx_dir}/journal.ART_1"
        [ "${idx}" -eq 2 ] && { an="${p_side}"; ae="${e2}"; bs="${b2}"; jf="${tx_dir}/journal.ART_2"; }
        [ "${idx}" -eq 3 ] && { an="${c_arch}"; ae="${e3}"; bs="${b3}"; jf="${tx_dir}/journal.ART_3"; }
        [ "${idx}" -eq 4 ] && { an="${c_side}"; ae="${e4}"; bs="${b4}"; jf="${tx_dir}/journal.ART_4"; }
        if [ "${ae}" -eq 1 ]; then
            write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "BACKUP_INTENT" "${tx_dir}"
            cp -p "${output_real}/${an}" "${tx_dir}/backup/${an}"
            write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "BACKUP_CREATED" "${tx_dir}"
            sync "${tx_dir}/backup/${an}"
            [ "$(sha256sum "${tx_dir}/backup/${an}" | cut -d ' ' -f 1)" = "${bs}" ]
            write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "BACKUP_DATA_SYNCED" "${tx_dir}"
            sync "${tx_dir}/backup"
            write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "BACKUP_DIR_SYNCED" "${tx_dir}"
        fi
    done
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_BACKUPS_READY" "${tx_dir}"
    [ "${PKG_FAIL_AT:-}" = "AFTER_BACKUP" ] && exit 1

    # Promotions
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_PROMOTING" "${tx_dir}"
    for idx in 1 2 3 4; do
        local an="${p_arch}" jf="${tx_dir}/journal.ART_1"
        [ "${idx}" -eq 2 ] && { an="${p_side}"; jf="${tx_dir}/journal.ART_2"; }
        [ "${idx}" -eq 3 ] && { an="${c_arch}"; jf="${tx_dir}/journal.ART_3"; }
        [ "${idx}" -eq 4 ] && { an="${c_side}"; jf="${tx_dir}/journal.ART_4"; }
        write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "PROMOTE_INTENT" "${tx_dir}"
        mv -f -T "${tx_dir}/stage/${an}" "${output_real}/${an}"
        write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "CANONICAL_REPLACED" "${tx_dir}"
        sync "${output_real}/${an}" && sync "${output_real}"
        write_bound_state_atomic "${jf}" "${tx_id}" "STATE" "CANONICAL_DIR_SYNCED" "${tx_dir}"
        [ "${PKG_FAIL_AT:-}" = "AFTER_PROMOTE_${idx}" ] && exit 1
    done

    (
        cd "${output_real}"
        test -f "${p_arch}" && test ! -L "${p_arch}" && test -s "${p_arch}"
        test -f "${c_arch}" && test ! -L "${c_arch}" && test -s "${c_arch}"
        sha256sum -c --strict "${p_side}" >/dev/null
        sha256sum -c --strict "${c_side}" >/dev/null
    )
    write_bound_state_atomic "${tx_dir}/journal.ART_1" "${tx_id}" "STATE" "PROMOTED_VERIFIED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_2" "${tx_id}" "STATE" "PROMOTED_VERIFIED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_3" "${tx_id}" "STATE" "PROMOTED_VERIFIED" "${tx_dir}"
    write_bound_state_atomic "${tx_dir}/journal.ART_4" "${tx_id}" "STATE" "PROMOTED_VERIFIED" "${tx_dir}"
    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_VALIDATED" "${tx_dir}"

    persist_bound_phase_or_halt "${tx_dir}/tx_phase" "${tx_id}" "TX_COMMITTED" "${tx_dir}"
    finalize_packaging_after_commit "${output_real}" "${tx_dir}" "${ver}" "${tx_id}" "${token}"
    echo "PKG_COMMITTED:${ver}"
}

package_entry() {
    local output_dir="$1"
    local ver="$2"
    local bundle_dir="$3"
    [[ "${ver}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [[ "${ver}" != *".."* ]] || return 1
    if [ ! -e "${output_dir}" ]; then
        (umask 0027 && mkdir -p "${output_dir}") || return 1
    fi
    [ -d "${output_dir}" ] && [ ! -L "${output_dir}" ] || return 1
    local output_real=""
    output_real="$(cd "${output_dir}" && pwd -P)" || return 1
    validate_canonical_path "${output_real}" "OUTPUT_DIR" || return 1
    local ts rand_t rand_id tok tx_i
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    rand_t="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    rand_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    tok="${ts}-${rand_t}"
    tx_i="${ts}-$$-${rand_id}"
    exec_with_locked_anchor "${output_real}" ".gra-pkg-${ver}.flock" \
        "/bin/bash" "${SCRIPT_SELF}" "--internal-locked-package" \
        "${output_real}" "${ver}" "${bundle_dir}" "${tx_i}" "${tok}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "${1:-}" = "--internal-locked-recover" ]; then
        recover_packaging_locked_worker "$2" "$3" "$4" "$5" "$6" "$7" "$8"
        exit $?
    fi

    if [ "${1:-}" = "--internal-locked-package" ]; then
        run_locked_packaging_worker "$2" "$3" "$4" "$5" "$6"
        exit $?
    fi

    if [ "${1:-}" = "--package" ]; then
        # --package <OUTPUT_DIR> <VERSION> <BUNDLE_DIR>
        package_entry "$2" "$3" "$4"
        exit $?
    fi

    if [ "${1:-}" = "--recover" ]; then
        if [ "$#" -ne 5 ] || [ "$4" != "--tx-token" ]; then
            echo "Usage: $0 --recover <OUTPUT_DIR> <TX_OR_RETIRED_DIR> --tx-token <SESSION_TOKEN>" >&2
            exit 1
        fi
        recover_packaging_entry "$2" "$3" "$5"
        exit $?
    fi
fi
