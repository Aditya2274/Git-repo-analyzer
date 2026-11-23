#!/usr/bin/env bash
# ==============================================================================
# Script: verify_ssh_host_keys.sh
# Purpose: Deterministically authenticate EC2 SSH host keys against serial
#          console logs before populating project-scoped known_hosts.
# Governance: Strict Host-Key Checking. Never disable host-key verification.
# Notice: Polling timeout is an operational limit to avoid script hangs, not an
#         AWS-guaranteed console delivery time.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="$(cd "${ANSIBLE_DIR}/../terraform" && pwd)"
KNOWN_HOSTS="${ANSIBLE_DIR}/known_hosts"
SSH_CFG="${ANSIBLE_DIR}/ssh.cfg"
SSH_KEY="${HOME}/.ssh/git-repo-analyzer.pem"
TMP_DIR="$(mktemp -d /tmp/ssh_verify.XXXXXX)"

trap 'rm -rf "${TMP_DIR}"' EXIT

# Configurable timeout and polling interval (operational limits)
CONSOLE_TIMEOUT_SECONDS="${CONSOLE_TIMEOUT_SECONDS:-360}"
CONSOLE_POLL_INTERVAL_SECONDS="${CONSOLE_POLL_INTERVAL_SECONDS:-10}"
ALLOW_TOFU=false
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tofu|--insecure-tofu)
            ALLOW_TOFU=true
            shift
            ;;
        --timeout)
            CONSOLE_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --interval)
            CONSOLE_POLL_INTERVAL_SECONDS="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

echo "==> Checking private key prerequisites..."
if [[ ! -f "${SSH_KEY}" ]]; then
    echo "ERROR: Private key not found at ${SSH_KEY}." >&2
    echo "       Expected canonical location: ~/.ssh/git-repo-analyzer.pem" >&2
    exit 1
fi

# Verify strict permissions on private key (0400 or 0600)
PERMS="$(stat -c "%a" "${SSH_KEY}")"
if [[ "${PERMS}" != "400" && "${PERMS}" != "600" ]]; then
    echo "ERROR: Insecure permissions (${PERMS}) on ${SSH_KEY}." >&2
    echo "       Required: chmod 0400 ${SSH_KEY}" >&2
    exit 1
fi
echo "    Verified private key ${SSH_KEY} with mode ${PERMS}."

# Ensure known_hosts exists with mode 0600
touch "${KNOWN_HOSTS}"
chmod 0600 "${KNOWN_HOSTS}"

# Ensure ansible/ssh.cfg references absolute path to known_hosts
cat <<EOF > "${SSH_CFG}"
# OpenSSH Client Configuration for Git Repository Analyzer Fleet
# Strictly enforces SSH host-key verification against project-scoped known_hosts.
# Never disable host-key verification.

Host puppet-server app-server cicd-server 127.0.0.1 10.* *
    User ubuntu
    IdentityFile ~/.ssh/git-repo-analyzer.pem
    StrictHostKeyChecking yes
    UserKnownHostsFile ${KNOWN_HOSTS}
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/ansible-%r@%h:%p
    ControlPersist 60s
EOF
chmod 0644 "${SSH_CFG}"

# Function to extract ED25519 fingerprint from EC2 serial console output
get_console_ed25519_fingerprint() {
    local instance_id="$1"
    local max_attempts=$(( (CONSOLE_TIMEOUT_SECONDS + CONSOLE_POLL_INTERVAL_SECONDS - 1) / CONSOLE_POLL_INTERVAL_SECONDS ))
    if [[ ${max_attempts} -lt 1 ]]; then
        max_attempts=1
    fi
    local attempt=1
    local output=""

    echo "    Polling serial console for ${instance_id} (timeout: ${CONSOLE_TIMEOUT_SECONDS}s, interval: ${CONSOLE_POLL_INTERVAL_SECONDS}s)..." >&2

    while [[ ${attempt} -le ${max_attempts} ]]; do
        local err_file="${TMP_DIR}/aws_err.log"

        if [[ -n "${MOCK_AWS_CONSOLE_CMD:-}" ]]; then
            # Test fixture execution hook
            set +e
            output="$(${MOCK_AWS_CONSOLE_CMD} "${attempt}" 2>"${err_file}")"
            local cmd_status=$?
            set -e

            if [[ ${cmd_status} -ne 0 ]]; then
                local err_msg
                err_msg="$(cat "${err_file}")"
                if echo "${err_msg}" | grep -qiE "AuthFailure|NoCredentialsError|UnauthorizedOperation|InvalidInstanceID"; then
                    echo "    AWS CLI authentication/authorization error: ${err_msg}" >&2
                    return 1
                fi
            fi
        elif [[ -n "${MOCK_AWS_CONSOLE_OUTPUT:-}" ]]; then
            output="${MOCK_AWS_CONSOLE_OUTPUT}"
        else
            if ! command -v aws >/dev/null 2>&1; then
                echo "    AWS CLI not installed; cannot retrieve console output." >&2
                return 1
            fi

            set +e
            output="$(aws ec2 get-console-output --instance-id "${instance_id}" --latest --output text 2>"${err_file}")"
            local aws_status=$?
            set -e

            if [[ ${aws_status} -ne 0 ]]; then
                local err_msg
                err_msg="$(cat "${err_file}")"
                if echo "${err_msg}" | grep -qiE "AuthFailure|NoCredentialsError|UnauthorizedOperation|InvalidInstanceID"; then
                    echo "    AWS CLI authentication/authorization error: ${err_msg}" >&2
                    return 1
                fi
            fi
        fi

        if [[ -n "${output}" ]] && echo "${output}" | grep -q "SSH HOST KEY FINGERPRINTS"; then
            local fp
            fp="$(echo "${output}" | grep -iE "SHA256:[A-Za-z0-9+/=]+.*(ed25519|ssh-ed25519)" | head -n 1 | grep -oE "SHA256:[A-Za-z0-9+/=]+" || true)"
            if [[ -n "${fp}" ]]; then
                echo "${fp}"
                return 0
            fi
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            echo "    Waiting for hypervisor console buffer flush (${attempt}/${max_attempts}, next check in ${CONSOLE_POLL_INTERVAL_SECONDS}s)..." >&2
            sleep "${CONSOLE_POLL_INTERVAL_SECONDS}"
        fi
        ((attempt++))
    done

    echo "    Console output timed out after ${CONSOLE_TIMEOUT_SECONDS}s for ${instance_id}." >&2
    return 1
}

# Function to authenticate and record host key atomically
verify_and_record_host() {
    local alias="$1"
    local host="$2"
    local instance_id="${3:-}"

    echo "--- Verifying ${alias} (${host}) ---"

    # Scan public ED25519 key from host
    local scanned_key_file="${TMP_DIR}/${alias}.key"
    if [[ -n "${MOCK_SSH_KEYSCAN:-}" ]]; then
        echo "${MOCK_SSH_KEYSCAN}" > "${scanned_key_file}"
    else
        if ! ssh-keyscan -t ed25519 -H "${host}" > "${scanned_key_file}" 2>/dev/null; then
            echo "ERROR: Failed to scan host key from ${host}." >&2
            return 1
        fi
    fi

    # Filter out empty or comment lines
    if ! grep -q "ssh-ed25519" "${scanned_key_file}"; then
        echo "ERROR: No valid ssh-ed25519 key scanned from ${host}." >&2
        return 1
    fi

    # Compute SHA256 fingerprint of scanned key
    local scanned_fp
    scanned_fp="$(ssh-keygen -lf "${scanned_key_file}" | awk '{print $2}')"
    echo "    Scanned ED25519 fingerprint : ${scanned_fp}"

    local authentic_fp=""
    if [[ -n "${instance_id}" ]]; then
        authentic_fp="$(get_console_ed25519_fingerprint "${instance_id}" || true)"
    fi

    if [[ -n "${authentic_fp}" ]]; then
        echo "    Console ED25519 fingerprint : ${authentic_fp}"
        if [[ "${scanned_fp}" == "${authentic_fp}" ]]; then
            echo "    [SUCCESS] Cryptographic match! Host key authentic."
        else
            echo "    [FATAL] Fingerprint MISMATCH for ${alias}!" >&2
            echo "            Scanned : ${scanned_fp}" >&2
            echo "            Console : ${authentic_fp}" >&2
            echo "            POSSIBLE MAN-IN-THE-MIDDLE ATTACK OR SPOOFING." >&2
            return 1
        fi
    else
        echo "    Console output unavailable (or instance_id not provided)."
        if [[ "${ALLOW_TOFU}" == "true" ]]; then
            echo "    [WARNING] --tofu specified: Accepting scanned key on Trust-On-First-Use." >&2
            echo "              RESIDUAL RISK: Potential MITM vulnerability on initial connection." >&2
        else
            echo "    [ERROR] Cannot cryptographically authenticate host without console fingerprint." >&2
            echo "            To proceed with Trust-On-First-Use at your own risk, re-run with: $0 --tofu" >&2
            return 1
        fi
    fi

    # Atomic update to known_hosts
    local tmp_kh="${TMP_DIR}/known_hosts.tmp"
    cp "${KNOWN_HOSTS}" "${tmp_kh}"

    # Remove old entries for this host and alias to prevent duplicate conflicts
    ssh-keygen -f "${tmp_kh}" -R "${host}" >/dev/null 2>&1 || true
    ssh-keygen -f "${tmp_kh}" -R "${alias}" >/dev/null 2>&1 || true
    rm -f "${tmp_kh}.old"

    # Append validated key (alias,host and key)
    local raw_key
    raw_key="$(grep "ssh-ed25519" "${scanned_key_file}" | head -n 1 | awk '{print $2, $3}')"
    echo "${alias},${host} ${raw_key}" >> "${tmp_kh}"
    chmod 0600 "${tmp_kh}"

    # Atomic replacement
    mv -f "${tmp_kh}" "${KNOWN_HOSTS}"
    echo "    Recorded ${alias},${host} atomically into ${KNOWN_HOSTS}."
}

# Main execution: explicit positional args or auto-discovery from Terraform
if [[ ${#POSITIONAL_ARGS[@]} -ge 2 ]]; then
    ALIAS="${POSITIONAL_ARGS[0]}"
    HOST="${POSITIONAL_ARGS[1]}"
    INSTANCE_ID="${POSITIONAL_ARGS[2]:-}"
    verify_and_record_host "${ALIAS}" "${HOST}" "${INSTANCE_ID}"
    exit 0
fi

# Auto-discovery mode via Terraform outputs
echo "==> Auto-discovering fleet hosts from Terraform outputs..."
if ! command -v terraform >/dev/null 2>&1; then
    echo "NOTICE: 'terraform' executable not found in PATH."
    exit 0
fi

set +e
TF_JSON="$(terraform -chdir="${TERRAFORM_DIR}" output -json 2>/dev/null)"
TF_JSON_STATUS=$?
set -e

if [[ ${TF_JSON_STATUS} -ne 0 || -z "${TF_JSON//[[:space:]]/}" || "${TF_JSON}" == "{}" ]]; then
    echo "NOTICE: Terraform infrastructure not provisioned yet (Boundary B pending)."
    echo "        Zero EC2 instances discovered. Preserving existing ${KNOWN_HOSTS}."
    exit 0
fi

# Parse hosts from JSON if present
PUPPET_IP="$(echo "${TF_JSON}" | jq -r '.puppet_server_public_ip.value // empty')"
PUPPET_ID="$(echo "${TF_JSON}" | jq -r '.puppet_server_id.value // empty')"

APP_IP="$(echo "${TF_JSON}" | jq -r '.app_server_public_ip.value // empty')"
APP_ID="$(echo "${TF_JSON}" | jq -r '.app_server_id.value // empty')"

CICD_IP="$(echo "${TF_JSON}" | jq -r '.cicd_server_public_ip.value // empty')"
CICD_ID="$(echo "${TF_JSON}" | jq -r '.cicd_server_id.value // empty')"

if [[ -n "${PUPPET_IP}" ]]; then
    verify_and_record_host "puppet-server" "${PUPPET_IP}" "${PUPPET_ID}"
fi
if [[ -n "${APP_IP}" ]]; then
    verify_and_record_host "app-server" "${APP_IP}" "${APP_ID}"
fi
if [[ -n "${CICD_IP}" ]]; then
    verify_and_record_host "cicd-server" "${CICD_IP}" "${CICD_ID}"
fi

echo "==> SSH host key verification completed."
