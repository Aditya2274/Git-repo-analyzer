#!/usr/bin/env bash
# ==============================================================================
# Script: sync_terraform_inventory.sh
# Purpose: Synchronize Ansible inventory from Terraform state outputs.
# Governance: Runs only after Boundary B authorization and terraform apply.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="$(cd "${ANSIBLE_DIR}/../terraform" && pwd)"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts.ini"

# Allow override for testing with mock terraform command
TERRAFORM_CMD="${TERRAFORM_CMD:-terraform -chdir=${TERRAFORM_DIR}}"

echo "==> Synchronizing Ansible inventory from Terraform output..."

# Verify terraform executable exists
TERRAFORM_BIN="$(echo "${TERRAFORM_CMD}" | awk '{print $1}')"
if ! command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    echo "ERROR: '${TERRAFORM_BIN}' executable not found in PATH." >&2
    exit 1
fi

# Query terraform output
# Capture stdout, stderr, and exit code cleanly
OUTPUT_ERR_FILE="$(mktemp /tmp/tf_sync_err.XXXXXX)"
trap 'rm -f "${OUTPUT_ERR_FILE}"' EXIT

set +e
RAW_INVENTORY="$(${TERRAFORM_CMD} output -raw ansible_inventory_template 2>"${OUTPUT_ERR_FILE}")"
TF_EXIT_CODE=$?
set -e

# Handle terraform command failure
if [[ ${TF_EXIT_CODE} -ne 0 ]]; then
    ERR_MSG="$(cat "${OUTPUT_ERR_FILE}")"
    echo "ERROR: Terraform command failed (exit code ${TF_EXIT_CODE}):" >&2
    echo "       ${ERR_MSG}" >&2
    exit 1
fi

# Check for empty output (unprovisioned state)
if [[ -z "${RAW_INVENTORY//[[:space:]]/}" ]]; then
    echo "NOTICE: Terraform state has no outputs (resources not provisioned yet under Boundary B)."
    echo "        Preserving baseline canonical inventory in ${INVENTORY_FILE}."
    exit 0
fi

# Validate required canonical inventory groups and host aliases
REQUIRED_GROUPS=("[puppet_server]" "[application]" "[cicd]" "[puppet_agents:children]")
REQUIRED_HOSTS=("puppet-server" "app-server" "cicd-server")

for group in "${REQUIRED_GROUPS[@]}"; do
    if ! echo "${RAW_INVENTORY}" | grep -Fq "${group}"; then
        echo "ERROR: Malformed inventory received from Terraform: missing required group '${group}'." >&2
        echo "       Preserving baseline canonical inventory in ${INVENTORY_FILE}." >&2
        exit 1
    fi
done

for host in "${REQUIRED_HOSTS[@]}"; do
    if ! echo "${RAW_INVENTORY}" | grep -Fq "${host}"; then
        echo "ERROR: Malformed inventory received from Terraform: missing required host alias '${host}'." >&2
        echo "       Preserving baseline canonical inventory in ${INVENTORY_FILE}." >&2
        exit 1
    fi
done

# Perform atomic write and validation using temporary file
TMP_INVENTORY="$(mktemp "${INVENTORY_FILE}.tmp.XXXXXX")"

cat <<EOF > "${TMP_INVENTORY}"
# Canonical Ansible Inventory for Git Repository Analyzer Fleet
# Generated dynamically from Terraform output: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

${RAW_INVENTORY}
EOF

# Validate syntax with ansible-inventory
if command -v ansible-inventory >/dev/null 2>&1; then
    if ! ansible-inventory -i "${TMP_INVENTORY}" --list >/dev/null 2>&1; then
        echo "ERROR: Inventory validation failed with ansible-inventory." >&2
        rm -f "${TMP_INVENTORY}"
        exit 1
    fi
fi

# Atomic move to destination
mv -f "${TMP_INVENTORY}" "${INVENTORY_FILE}"
chmod 0644 "${INVENTORY_FILE}"

echo "==> Successfully and atomically updated ${INVENTORY_FILE}"
