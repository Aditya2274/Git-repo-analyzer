#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_verify_ssh_keys.sh
# Purpose: Comprehensive validation of verify_ssh_host_keys.sh across:
#          - Immediate fingerprint arrival
#          - Delayed fingerprint arrival within timeout
#          - Timeout expiration on missing fingerprints
#          - Immediate termination on AWS authentication/auth errors
#          - Cryptographic mismatch rejection (MITM defense)
#          - Explicit TOFU opt-in vs default refusal
#          - known_hosts atomic preservation
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_SCRIPT="${ANSIBLE_DIR}/scripts/verify_ssh_host_keys.sh"
TEST_TMP="$(mktemp -d /tmp/test_ssh_verify.XXXXXX)"

trap 'rm -rf "${TEST_TMP}"' EXIT

PASSED_COUNT=0
TOTAL_COUNT=8

echo "=============================================================================="
echo "Running Test Suite: verify_ssh_host_keys.sh (Configurable Polling & Timeout)"
echo "=============================================================================="

# Generate a temporary authentic ED25519 key pair for tests
TEST_KEY_FILE="${TEST_TMP}/id_ed25519"
ssh-keygen -t ed25519 -N "" -f "${TEST_KEY_FILE}" -C "ec2-test-host" >/dev/null 2>&1
TEST_PUB_KEY="$(cat "${TEST_KEY_FILE}.pub")"
TEST_FP="$(ssh-keygen -lf "${TEST_KEY_FILE}.pub" | awk '{print $2}')"

# Valid console output block
MOCK_CONSOLE_MATCH="
[    0.000000] Linux version 6.8.0-1017-aws ...
cloud-init[842]: -----BEGIN SSH HOST KEY FINGERPRINTS-----
cloud-init[842]: 256 ${TEST_FP} root@ip-10-0-0-10 (ED25519)
cloud-init[842]: 3072 SHA256:dummyrsa1234567890 root@ip-10-0-0-10 (RSA)
cloud-init[842]: -----END SSH HOST KEY FINGERPRINTS-----
"

# Mock keyscan output
MOCK_KEYSCAN="test-host ${TEST_PUB_KEY}"

# --- Test 1: Immediate fingerprint arrival before timeout ---
echo -n "[Test 1/8] Immediate fingerprint arrival before timeout... "
set +e
OUT="$(MOCK_AWS_CONSOLE_OUTPUT="${MOCK_CONSOLE_MATCH}" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" test-host 127.0.0.1 i-0123456789abcdef0 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 && "${OUT}" =~ "Cryptographic match" && $(grep -F "test-host,127.0.0.1" "${ANSIBLE_DIR}/known_hosts") ]]; then
    echo "PASS (Match confirmed, recorded into known_hosts)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 2: Delayed fingerprint output succeeds within configured timeout ---
echo -n "[Test 2/8] Delayed fingerprint arrival within timeout... "
# Mock command that returns empty on attempt 1, and valid output on attempt 2
DELAYED_MOCK="${TEST_TMP}/mock_delayed.sh"
cat <<EOF > "${DELAYED_MOCK}"
#!/usr/bin/env bash
attempt="\$1"
if [[ "\${attempt}" -ge 2 ]]; then
    cat <<'OUT'
${MOCK_CONSOLE_MATCH}
OUT
    exit 0
else
    echo "[    0.100000] Booting Linux..."
    exit 0
fi
EOF
chmod +x "${DELAYED_MOCK}"

set +e
OUT="$(MOCK_AWS_CONSOLE_CMD="${DELAYED_MOCK}" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" --timeout 10 --interval 1 delayed-host 127.0.0.2 i-delayed 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 && "${OUT}" =~ "Cryptographic match" && $(grep -F "delayed-host,127.0.0.2" "${ANSIBLE_DIR}/known_hosts") ]]; then
    echo "PASS (Delayed output succeeded on retry within timeout)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 3: Missing fingerprint output times out ---
echo -n "[Test 3/8] Missing fingerprint output fails after timeout... "
NEVER_MOCK="${TEST_TMP}/mock_never.sh"
cat <<'EOF' > "${NEVER_MOCK}"
#!/usr/bin/env bash
echo "[    0.100000] Booting Linux without host keys..."
exit 0
EOF
chmod +x "${NEVER_MOCK}"

set +e
OUT="$(MOCK_AWS_CONSOLE_CMD="${NEVER_MOCK}" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" --timeout 2 --interval 1 timeout-host 127.0.0.3 i-timeout 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -ne 0 && "${OUT}" =~ "Console output timed out after 2s" && ! $(grep -F "timeout-host" "${ANSIBLE_DIR}/known_hosts" || true) ]]; then
    echo "PASS (Correctly timed out after 2s and failed safely)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 4: AWS authentication error terminates immediately ---
echo -n "[Test 4/8] AWS auth error terminates immediately without retrying... "
AUTH_ERR_MOCK="${TEST_TMP}/mock_auth_err.sh"
cat <<'EOF' > "${AUTH_ERR_MOCK}"
#!/usr/bin/env bash
echo "An error occurred (AuthFailure) when calling the GetConsoleOutput operation: AWS was not able to validate the provided access credentials" >&2
exit 255
EOF
chmod +x "${AUTH_ERR_MOCK}"

set +e
OUT="$(MOCK_AWS_CONSOLE_CMD="${AUTH_ERR_MOCK}" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" --timeout 60 --interval 5 autherr-host 127.0.0.4 i-autherr 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -ne 0 && "${OUT}" =~ "AWS CLI authentication/authorization error" && ! "${OUT}" =~ "Waiting for hypervisor console buffer flush" ]]; then
    echo "PASS (Terminated immediately on attempt 1 without hanging)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 5: Cryptographic mismatch rejection ---
echo -n "[Test 5/8] Cryptographic mismatch rejection (MITM defense)... "
MOCK_CONSOLE_MISMATCH="
cloud-init[842]: -----BEGIN SSH HOST KEY FINGERPRINTS-----
cloud-init[842]: 256 SHA256:ATTACKER_FAKE_FINGERPRINT_123456789012345 root@ip (ED25519)
cloud-init[842]: -----END SSH HOST KEY FINGERPRINTS-----
"
set +e
OUT="$(MOCK_AWS_CONSOLE_OUTPUT="${MOCK_CONSOLE_MISMATCH}" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" spoofed-host 127.0.0.5 i-spoofed 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -ne 0 && "${OUT}" =~ "Fingerprint MISMATCH" && ! $(grep -F "spoofed-host" "${ANSIBLE_DIR}/known_hosts" || true) ]]; then
    echo "PASS (Rejected mismatch with code 1, blocked key recording)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 6: TOFU refusal without explicit flag ---
echo -n "[Test 6/8] TOFU refusal when console output unavailable... "
set +e
OUT="$(MOCK_AWS_CONSOLE_OUTPUT="" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" unverified-host 127.0.0.6 i-unverified 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -ne 0 && "${OUT}" =~ "Cannot cryptographically authenticate host without console fingerprint" ]]; then
    echo "PASS (Refused to record unverified host without --tofu)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 7: Explicit TOFU opt-in with security warning ---
echo -n "[Test 7/8] Explicit TOFU opt-in (--tofu) with security warning... "
set +e
OUT="$(MOCK_AWS_CONSOLE_OUTPUT="" MOCK_SSH_KEYSCAN="${MOCK_KEYSCAN}" bash "${VERIFY_SCRIPT}" --tofu tofu-host 127.0.0.7 i-tofu 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 && "${OUT}" =~ "RESIDUAL RISK: Potential MITM vulnerability" && $(grep -F "tofu-host" "${ANSIBLE_DIR}/known_hosts") ]]; then
    echo "PASS (Accepted with explicit warning and recorded key)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

# --- Test 8: Auto-discovery on unprovisioned Terraform state ---
echo -n "[Test 8/8] Auto-discovery on unprovisioned Terraform state... "
set +e
OUT="$(bash "${VERIFY_SCRIPT}" 2>&1)"
STATUS=$?
set -e

if [[ ${STATUS} -eq 0 && "${OUT}" =~ "Terraform infrastructure not provisioned yet" ]]; then
    echo "PASS (Gracefully detected unprovisioned state, exited 0)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Status: ${STATUS})"
    echo "${OUT}"
fi

echo "=============================================================================="
echo "Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} passed."
echo "=============================================================================="

# Clean up test entries in known_hosts
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "test-host" >/dev/null 2>&1 || true
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "delayed-host" >/dev/null 2>&1 || true
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "tofu-host" >/dev/null 2>&1 || true
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "127.0.0.1" >/dev/null 2>&1 || true
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "127.0.0.2" >/dev/null 2>&1 || true
ssh-keygen -f "${ANSIBLE_DIR}/known_hosts" -R "127.0.0.7" >/dev/null 2>&1 || true
rm -f "${ANSIBLE_DIR}/known_hosts.old"
chmod 0600 "${ANSIBLE_DIR}/known_hosts"

if [[ ${PASSED_COUNT} -eq ${TOTAL_COUNT} ]]; then
    exit 0
else
    exit 1
fi
