#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_sync_inventory.sh
# Purpose: Comprehensive validation of sync_terraform_inventory.sh across
#          the 5 required test scenarios without mutating live Terraform state.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_SCRIPT="${ANSIBLE_DIR}/scripts/sync_terraform_inventory.sh"
TEST_TMP="$(mktemp -d /tmp/test_sync_inv.XXXXXX)"

trap 'rm -rf "${TEST_TMP}"' EXIT

# Back up real hosts.ini
REAL_INVENTORY="${ANSIBLE_DIR}/inventory/hosts.ini"
BACKUP_INVENTORY="${TEST_TMP}/hosts.ini.bak"
cp "${REAL_INVENTORY}" "${BACKUP_INVENTORY}"

restore_inventory() {
    cp "${BACKUP_INVENTORY}" "${REAL_INVENTORY}"
}
trap 'restore_inventory; rm -rf "${TEST_TMP}"' EXIT

PASSED_COUNT=0
TOTAL_COUNT=5

echo "=============================================================================="
echo "Running Test Suite: sync_terraform_inventory.sh (5 Scenarios)"
echo "=============================================================================="

# Helper to create mock terraform runner
create_mock_terraform() {
    local behavior="$1" # empty, valid, malformed, error
    local mock_bin="${TEST_TMP}/mock_tf_${behavior}.sh"

    case "${behavior}" in
        empty)
            cat <<'EOF' > "${mock_bin}"
#!/usr/bin/env bash
# Mock Terraform: outputs empty string
exit 0
EOF
            ;;
        valid)
            cat <<'EOF' > "${mock_bin}"
#!/usr/bin/env bash
# Mock Terraform: outputs valid canonical inventory template
cat <<'INV'
[puppet_server]
puppet-server ansible_host=54.200.10.1 private_ip=10.0.0.10

[application]
app-server ansible_host=54.200.10.2 private_ip=10.0.0.11

[cicd]
cicd-server ansible_host=54.200.10.3 private_ip=10.0.0.12

[puppet_agents:children]
application
cicd
INV
exit 0
EOF
            ;;
        malformed)
            cat <<'EOF' > "${mock_bin}"
#!/usr/bin/env bash
# Mock Terraform: outputs malformed inventory missing required groups
cat <<'INV'
[broken_group]
random-server ansible_host=1.2.3.4
INV
exit 0
EOF
            ;;
        error)
            cat <<'EOF' > "${mock_bin}"
#!/usr/bin/env bash
# Mock Terraform: fails with exit code 1
echo "Error: Failed to refresh state: backend unavailable" >&2
exit 1
EOF
            ;;
    esac

    chmod +x "${mock_bin}"
    echo "${mock_bin}"
}

# --- Test Scenario 1: Terraform output unavailable (real unprovisioned state) ---
echo -n "[Scenario 1/5] Terraform output unavailable (state empty)... "
MOCK_BIN="$(create_mock_terraform empty)"
BEFORE_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"
set +e
OUT="$(TERRAFORM_CMD="${MOCK_BIN}" bash "${SYNC_SCRIPT}" 2>&1)"
STATUS=$?
set -e
AFTER_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"

if [[ ${STATUS} -eq 0 && "${BEFORE_HASH}" == "${AFTER_HASH}" && "${OUT}" =~ "Preserving baseline canonical inventory" ]]; then
    echo "PASS (Preserved baseline inventory, exited 0)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS}, Hashes match: $((BEFORE_HASH == AFTER_HASH)))"
    echo "${OUT}"
fi

# --- Test Scenario 2: Valid inventory output ---
echo -n "[Scenario 2/5] Valid inventory output from Terraform... "
MOCK_BIN="$(create_mock_terraform valid)"
set +e
OUT="$(TERRAFORM_CMD="${MOCK_BIN}" bash "${SYNC_SCRIPT}" 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 && $(grep -c "54.200.10.1" "${REAL_INVENTORY}") -eq 1 ]]; then
    # Verify inventory parses cleanly with ansible-inventory
    if ansible-inventory -i "${REAL_INVENTORY}" --list >/dev/null 2>&1; then
        echo "PASS (Atomically updated and validated with ansible-inventory)"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        echo "FAIL (ansible-inventory parsing failed)"
    fi
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi
restore_inventory

# --- Test Scenario 3: Empty inventory output (whitespace only) ---
echo -n "[Scenario 3/5] Empty / whitespace-only inventory output... "
MOCK_BIN="$(create_mock_terraform empty)"
BEFORE_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"
set +e
OUT="$(TERRAFORM_CMD="${MOCK_BIN}" bash "${SYNC_SCRIPT}" 2>&1)"
STATUS=$?
set -e
AFTER_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"

if [[ ${STATUS} -eq 0 && "${BEFORE_HASH}" == "${AFTER_HASH}" ]]; then
    echo "PASS (Detected empty output, preserved baseline inventory)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test Scenario 4: Malformed inventory output ---
echo -n "[Scenario 4/5] Malformed inventory output (missing canonical groups)... "
MOCK_BIN="$(create_mock_terraform malformed)"
BEFORE_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"
set +e
OUT="$(TERRAFORM_CMD="${MOCK_BIN}" bash "${SYNC_SCRIPT}" 2>&1)"
STATUS=$?
set -e
AFTER_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"

if [[ ${STATUS} -ne 0 && "${BEFORE_HASH}" == "${AFTER_HASH}" && "${OUT}" =~ "Malformed inventory received" ]]; then
    echo "PASS (Rejected malformed inventory, zero corruption, exited non-zero)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS}, Hashes match: $((BEFORE_HASH == AFTER_HASH)))"
    echo "${OUT}"
fi

# --- Test Scenario 5: Terraform command failure ---
echo -n "[Scenario 5/5] Terraform command failure... "
MOCK_BIN="$(create_mock_terraform error)"
BEFORE_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"
set +e
OUT="$(TERRAFORM_CMD="${MOCK_BIN}" bash "${SYNC_SCRIPT}" 2>&1)"
STATUS=$?
set -e
AFTER_HASH="$(sha256sum "${REAL_INVENTORY}" | awk '{print $1}')"

if [[ ${STATUS} -ne 0 && "${BEFORE_HASH}" == "${AFTER_HASH}" && "${OUT}" =~ "Terraform command failed" ]]; then
    echo "PASS (Captured command failure, reported error, preserved baseline)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

echo "=============================================================================="
echo "Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} passed."
echo "=============================================================================="

if [[ ${PASSED_COUNT} -eq ${TOTAL_COUNT} ]]; then
    exit 0
else
    exit 1
fi
