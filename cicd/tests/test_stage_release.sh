#!/usr/bin/env bash
# ==============================================================================
# Test Suite: cicd/tests/test_stage_release.sh
# Purpose: Comprehensive, hermetic test suite validating scripts/stage_release.sh
#          against the integrated v6.7 transactional staging engine
#          (scripts/release-v67/staging_tx.sh & design_common.sh) using mocked
#          SSH (stream-based stdin transfer + encoded bootstrap execution):
#          1.  Missing arguments & CLI option/mode validation
#          2.  Invalid release version, path traversal & option bounds
#          3.  Missing/empty/symlink local archive rejection
#          4.  Missing/empty/symlink checksum sidecar rejection
#          5.  Invalid local checksum pre-check fail-closed
#          6.  Missing SSH config/key rejection & custom SSH flag forwarding
#          7.  SSH transport & bootstrap integrity failure propagation
#          8.  Remote staging directory & lock-anchor security validation
#          9.  Remote stream size, trailing-byte & checksum failure abort
#          10. Successful end-to-end transactional staging
#          11. Existing release refusal without --overwrite
#          12. Cleanup of temporary transaction & retired artifacts
#          13. Overwrite safety: existing release survives remote verification fail
#          14. Overwrite safety: existing release survives SSH transport failure
#          15. Overwrite safety: corrupted/truncated/trailing streams rejected
#          16. Promotion rollback across all supported failure-injection hooks
#          17. Successful overwrite replaces both files with verified content
#          18. Transaction token uniqueness & multi-version isolation
#          19. Puppet parameter, release_manager.py & documentation contract
#          20. Transaction locking & concurrent/unresolved-TX exclusion
#          21. Deliberate --recover lifecycle & TX_RECOVERY_REQUIRED preservation
#          22. Journal/manifest tamper rejection & retired cleanup resumption
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE_SCRIPT="${PROJECT_ROOT}/scripts/stage_release.sh"
V67_COMMON="${PROJECT_ROOT}/scripts/release-v67/design_common.sh"

PASSED_COUNT=0
TOTAL_COUNT=22

echo "=============================================================================="
echo "Running Test Suite: v6.7 Application Release Staging Validation (Mocked SSH)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 0. Setup Isolated Sandbox & Mock SSH Environment
# ------------------------------------------------------------------------------
TEST_SANDBOX="$(mktemp -d -t gra-test-stage-XXXXXX)"
cleanup_all() {
    rm -rf "${TEST_SANDBOX}"
}
trap cleanup_all EXIT INT TERM

MOCK_BIN="${TEST_SANDBOX}/bin"
MOCK_HOME="${TEST_SANDBOX}/mock_home"
MOCK_REMOTE="${TEST_SANDBOX}/remote_staging"
LOCAL_DIST="${TEST_SANDBOX}/local_dist"
PAYLOAD_SRC="${TEST_SANDBOX}/payload_src"
SSH_CALL_LOG="${TEST_SANDBOX}/ssh_calls.jsonl"

mkdir -p "${MOCK_BIN}" "${MOCK_HOME}/.ssh" "${MOCK_REMOTE}" "${LOCAL_DIST}" "${PAYLOAD_SRC}"
chmod 0700 "${MOCK_HOME}" "${MOCK_HOME}/.ssh"
# Mirror Puppet application::release staging directory policy (0750 owned by user)
chmod 0750 "${MOCK_REMOTE}"

# Guard stub proving the v6.7 engine never invokes scp
cat > "${MOCK_BIN}/scp" << 'EOF'
#!/usr/bin/env bash
echo "mock-scp ERROR: v6.7 staging engine must not invoke scp" >&2
exit 99
EOF
chmod +x "${MOCK_BIN}/scp"

# Mock SSH accurately simulating:
#   ssh [SSH_EXEC_OPTS...] user@host "/usr/bin/python3 -c '...' '<s_b64>' '<s_sha>' '<a_b64>' '<a_sha>'" < stdin_file
# Notes:
# - Never uses real SSH credentials or remote EC2 hosts.
# - Records CLI flags and decoded Base64 JSON args into MOCK_SSH_CAPTURE_FILE when set.
# - Supports stream & bootstrap fault injection without modifying production code.
cat > "${MOCK_BIN}/ssh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
if [ "$#" -lt 2 ]; then
    echo "mock-ssh: expected destination and remote command" >&2
    exit 255
fi

cmd="${args[${#args[@]}-1]}"
ssh_flags=("${args[@]:0:${#args[@]}-1}")

if [ -n "${MOCK_SSH_CAPTURE_FILE:-}" ]; then
    python3 - "${MOCK_SSH_CAPTURE_FILE}" "${cmd}" "${ssh_flags[@]}" << 'PY_LOG'
import base64, json, re, sys
log_path = sys.argv[1]
cmd = sys.argv[2]
ssh_flags = sys.argv[3:]
pairs = re.findall(r"'([A-Za-z0-9+/=]+)'\s+'([0-9a-f]{64})'", cmd)
decoded_args = []
if len(pairs) >= 2:
    try:
        decoded_args = json.loads(base64.b64decode(pairs[1][0]).decode("utf-8"))
    except Exception:
        decoded_args = []
entry = {"ssh_flags": ssh_flags, "decoded_args": decoded_args}
with open(log_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry) + "\n")
PY_LOG
fi

if [ "${MOCK_SSH_FAIL:-0}" = "1" ]; then
    echo "mock-ssh: Connection refused" >&2
    exit 255
fi

if [ "${MOCK_CORRUPT_BOOTSTRAP_SCRIPT:-0}" = "1" ]; then
    cmd="$(python3 -c '
import re, sys
s = sys.argv[1]
print(re.sub(r"\x27[0-9a-f]{64}\x27", "\x27" + "0"*64 + "\x27", s, count=1))
' "${cmd}")"
fi

if [ "${MOCK_CORRUPT_BOOTSTRAP_ARGS:-0}" = "1" ]; then
    cmd="$(python3 -c '
import re, sys
s = sys.argv[1]
matches = list(re.finditer(r"\x27[0-9a-f]{64}\x27", s))
if len(matches) >= 2:
    m = matches[1]
    s = s[:m.start()] + "\x27" + "0"*64 + "\x27" + s[m.end():]
print(s)
' "${cmd}")"
fi

if [ "${MOCK_TRUNCATE_STDIN:-0}" = "1" ]; then
    head -c 5 | eval "${cmd}"
elif [ "${MOCK_TRAILING_STDIN:-0}" = "1" ]; then
    (cat; printf 'TRAILING_GARBAGE_BYTES') | eval "${cmd}"
elif [ "${MOCK_CORRUPT_ARCHIVE:-0}" = "1" ]; then
    python3 -c 'import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(bytes([b ^ 0xff for b in d[:4]]) + d[4:])' | eval "${cmd}"
else
    eval "${cmd}"
fi
EOF
chmod +x "${MOCK_BIN}/ssh"

export PATH="${MOCK_BIN}:${PATH}"
export HOME="${MOCK_HOME}"
export PYTHONDONTWRITEBYTECODE=1
export MOCK_REMOTE LOCAL_DIST STAGE_SCRIPT PROJECT_ROOT TEST_SANDBOX V67_COMMON SSH_CALL_LOG

# Helper: build a valid gzipped binary release tarball + GNU coreutils .sha256 sidecar
create_test_release() {
    local ver="$1"
    local dist="$2"
    local label="${3:-release-${ver}}"
    local work="${TEST_SANDBOX}/pkg_build_${RANDOM}_${RANDOM}"
    mkdir -p "${dist}" "${work}"
    printf '%s\n\x00\x01\x02binary-payload\n' "${label}" > "${work}/artifact.bin"
    tar -czf "${dist}/${ver}.tar.gz" -C "${work}" .
    rm -rf "${work}"
    (
        cd "${dist}"
        sha256sum "${ver}.tar.gz" > "${ver}.tar.gz.sha256"
    )
}

assert_no_leaked_tx_artifacts() {
    local remote_dir="$1"
    local leaked=""
    leaked="$(find "${remote_dir}" -maxdepth 2 \( \
        -name ".tx-*" -o \
        -name ".tx-retired-*" -o \
        -name ".tmp*" -o \
        -name ".restore-*" -o \
        -name ".bak-*" \
    \) 2>/dev/null || true)"
    if [[ -n "${leaked}" ]]; then
        echo "FAILED (leaked temporary/transaction artifacts in '${remote_dir}': ${leaked})" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. Missing arguments & CLI mode validation
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Missing arguments & CLI mode validation... "
python3 - << 'EOF'
import os, subprocess
script = os.environ['STAGE_SCRIPT']

for args, label in [
    ([], "No arguments"),
    (["-v"], "Flag -v without value"),
    (["-d"], "Flag -d without value"),
    (["-H"], "Flag -H without value"),
    (["-p"], "Flag -p without value"),
    (["-r"], "Flag -r without value"),
    (["--tx-token"], "Flag --tx-token without value"),
    (["--recover"], "--recover without --version"),
    (["--recover", "-v", "1.0.0"], "--recover without --tx-token"),
    (["--recover", "-v", "1.0.0", "--tx-token", "20261127T211500Z-0123456789abcdef0123456789abcdef", "--overwrite"], "--recover combined with --overwrite"),
    (["-v", "1.0.0", "--tx-token", "20261127T211500Z-0123456789abcdef0123456789abcdef"], "--tx-token without --recover"),
    (["-v", "1.0.0", "extra-arg"], "Unexpected positional argument"),
]:
    res = subprocess.run([script] + args, capture_output=True, text=True)
    assert res.returncode != 0, f"Expected non-zero exit for '{label}', got {res.returncode}"

help_res = subprocess.run([script, "--help"], capture_output=True, text=True)
assert help_res.returncode == 0, f"Expected rc=0 for --help, got {help_res.returncode}"
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Invalid release version, path traversal & option bounds
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Invalid release version & option sanitization... "
python3 - << 'EOF'
import os, subprocess
script = os.environ['STAGE_SCRIPT']

bad_invocations = [
    (["-v", "../1.0.0"], "path traversal version"),
    (["-v", "1.0.0/attack"], "slash in version"),
    (["-v", "1.0.0;rm -rf /"], "shell metacharacters in version"),
    (["-v", "1.0.0..1"], "double dot in version"),
    (["-v", "-1.0.0"], "leading dash in version"),
    (["-v", "1.0.0$PATH"], "dollar sign in version"),
    (["-v", "1.0.0", "-p", "0"], "SSH port 0"),
    (["-v", "1.0.0", "-p", "70000"], "SSH port out of range"),
    (["-v", "1.0.0", "-p", "abc"], "non-numeric SSH port"),
    (["-v", "1.0.0", "-r", "relative/staging"], "relative remote path"),
    (["-v", "1.0.0", "-r", "/var/cache/../etc"], "remote path dot traversal"),
]
for args, label in bad_invocations:
    res = subprocess.run([script] + args, capture_output=True, text=True)
    assert res.returncode != 0, f"Expected non-zero exit for '{label}'"
    assert "Error:" in res.stderr, f"Expected explicit Error message for '{label}', got: {res.stderr}"
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Missing, empty, or symlink local release archive
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Missing, empty, and symlink local archive rejection... "
EMPTY_DIST="${TEST_SANDBOX}/empty_dist"
mkdir -p "${EMPTY_DIST}"
res=0
"${STAGE_SCRIPT}" -v "1.0.0-missing" -d "${EMPTY_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

# Symlink archive must be rejected
printf 'target' > "${TEST_SANDBOX}/symlink_target.tar.gz"
ln -s "${TEST_SANDBOX}/symlink_target.tar.gz" "${EMPTY_DIST}/1.0.0-sym.tar.gz"
(cd "${EMPTY_DIST}" && sha256sum "1.0.0-sym.tar.gz" > "1.0.0-sym.tar.gz.sha256")
res=0
"${STAGE_SCRIPT}" -v "1.0.0-sym" -d "${EMPTY_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

# Empty archive must be rejected
: > "${EMPTY_DIST}/1.0.0-zero.tar.gz"
(cd "${EMPTY_DIST}" && sha256sum "1.0.0-zero.tar.gz" > "1.0.0-zero.tar.gz.sha256")
res=0
"${STAGE_SCRIPT}" -v "1.0.0-zero" -d "${EMPTY_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Missing, empty, or symlink checksum sidecar
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Missing, empty, and symlink checksum sidecar rejection... "
NO_SIDECAR_DIST="${TEST_SANDBOX}/no_sidecar_dist"
mkdir -p "${NO_SIDECAR_DIST}"
echo "sample" > "${NO_SIDECAR_DIST}/2.0.0.tar.gz"
res=0
"${STAGE_SCRIPT}" -v "2.0.0" -d "${NO_SIDECAR_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

# Symlink sidecar must be rejected
create_test_release "2.0.1" "${NO_SIDECAR_DIST}"
mv "${NO_SIDECAR_DIST}/2.0.1.tar.gz.sha256" "${TEST_SANDBOX}/real_201.sha256"
ln -s "${TEST_SANDBOX}/real_201.sha256" "${NO_SIDECAR_DIST}/2.0.1.tar.gz.sha256"
res=0
"${STAGE_SCRIPT}" -v "2.0.1" -d "${NO_SIDECAR_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Invalid local checksum pre-check fail-closed (never calls SSH)
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Invalid local checksum pre-check fail-closed... "
BAD_SUM_DIST="${TEST_SANDBOX}/bad_sum_dist"
mkdir -p "${BAD_SUM_DIST}"
echo "real content" > "${BAD_SUM_DIST}/3.0.0.tar.gz"
echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  3.0.0.tar.gz" > "${BAD_SUM_DIST}/3.0.0.tar.gz.sha256"
: > "${SSH_CALL_LOG}"
res=0
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "3.0.0" -d "${BAD_SUM_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
test ! -s "${SSH_CALL_LOG}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Missing SSH config/identity fail-closed & explicit SSH option forwarding
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Missing SSH config/key fail-closed & flag forwarding... "
create_test_release "4.0.0" "${LOCAL_DIST}"
: > "${SSH_CALL_LOG}"
res=0
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "4.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" -F "/nonexistent/path/ssh.cfg" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
test ! -s "${SSH_CALL_LOG}"

res=0
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "4.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" -i "/nonexistent/path/key.pem" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
test ! -s "${SSH_CALL_LOG}"

# Verify custom -F, -i, -p flags and strict host-key / BatchMode options reach ssh
MOCK_SSH_CFG="${TEST_SANDBOX}/test_ssh.cfg"
MOCK_SSH_KEY="${MOCK_HOME}/.ssh/test_id.pem"
printf 'Host app-server\n  StrictHostKeyChecking yes\n' > "${MOCK_SSH_CFG}"
printf 'MOCK-KEY\n' > "${MOCK_SSH_KEY}"
chmod 0600 "${MOCK_SSH_KEY}"

: > "${SSH_CALL_LOG}"
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "4.0.0" -d "${LOCAL_DIST}" -H "app-server" -p 2222 -F "${MOCK_SSH_CFG}" -i "${MOCK_SSH_KEY}" -r "${MOCK_REMOTE}" >/dev/null 2>&1
python3 - << 'EOF'
import json, os
with open(os.environ['SSH_CALL_LOG'], 'r') as f:
    rec = json.loads(f.readline())
flags = rec['ssh_flags']
assert '-T' in flags, flags
assert 'BatchMode=yes' in flags, flags
assert 'StrictHostKeyChecking=yes' in flags, flags
assert '-p' in flags and '2222' in flags, flags
assert '-F' in flags and '-i' in flags, flags
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. SSH transport & bootstrap integrity failure propagation
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] SSH transport & bootstrap failure propagation... "
create_test_release "5.0.0" "${LOCAL_DIST}"
res=0
MOCK_SSH_FAIL=1 "${STAGE_SCRIPT}" -v "5.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 255

res=0
MOCK_CORRUPT_BOOTSTRAP_SCRIPT=1 "${STAGE_SCRIPT}" -v "5.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 71

res=0
MOCK_CORRUPT_BOOTSTRAP_ARGS=1 "${STAGE_SCRIPT}" -v "5.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 71

test ! -e "${MOCK_REMOTE}/5.0.0.tar.gz"
test ! -e "${MOCK_REMOTE}/5.0.0.tar.gz.sha256"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Remote staging directory & lock-anchor validation failures
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Remote staging directory & lock-anchor validation... "
create_test_release "6.0.0" "${LOCAL_DIST}"

# 8a. Missing remote directory (exit 72)
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${TEST_SANDBOX}/does_not_exist" >/dev/null 2>&1 || res=$?
test "${res}" -eq 72

# 8b. Symlink remote staging directory (exit 72)
SYM_REMOTE="${TEST_SANDBOX}/sym_remote"
ln -s "${MOCK_REMOTE}" "${SYM_REMOTE}"
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${SYM_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 72

# 8c. Group-writable remote dir 0770 (exit 72) & world-writable 0757 (exit 72)
DIR_UNTRUSTED="${TEST_SANDBOX}/dir_untrusted"
mkdir -p "${DIR_UNTRUSTED}"
chmod 0770 "${DIR_UNTRUSTED}"
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${DIR_UNTRUSTED}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 72

chmod 0757 "${DIR_UNTRUSTED}"
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${DIR_UNTRUSTED}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 72

# 8d. Foreign-UID parent directory (exit 72)
if [[ "$(id -u)" -eq 0 ]]; then
    FOREIGN_DIR="${TEST_SANDBOX}/foreign_dir"
    mkdir -p "${FOREIGN_DIR}"
    chown 65534:65534 "${FOREIGN_DIR}"
    chmod 0750 "${FOREIGN_DIR}"
else
    FOREIGN_DIR="/etc"
fi
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${FOREIGN_DIR}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 72

# 8e. Lock-anchor symlink attack (exit 73) leaves target untouched
rm -f "${MOCK_REMOTE}/.gra-tx-6.0.0.flock"
ln -s "${TEST_SANDBOX}/symlink_lock_victim" "${MOCK_REMOTE}/.gra-tx-6.0.0.flock"
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 73
test ! -e "${TEST_SANDBOX}/symlink_lock_victim"
rm -f "${MOCK_REMOTE}/.gra-tx-6.0.0.flock"

# 8f. Lock-anchor hardlink attack (st_nlink > 1 -> exit 74)
printf 'victim' > "${TEST_SANDBOX}/hardlink_lock_victim"
ln "${TEST_SANDBOX}/hardlink_lock_victim" "${MOCK_REMOTE}/.gra-tx-6.0.0.flock"
res=0
"${STAGE_SCRIPT}" -v "6.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -eq 74
rm -f "${MOCK_REMOTE}/.gra-tx-6.0.0.flock" "${TEST_SANDBOX}/hardlink_lock_victim"

test ! -e "${MOCK_REMOTE}/6.0.0.tar.gz"
test ! -e "${MOCK_REMOTE}/6.0.0.tar.gz.sha256"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Remote stream byte-count, trailing-bytes & SHA-256 verification failures
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Remote stream size & SHA-256 verification failure... "
create_test_release "7.0.0" "${LOCAL_DIST}"

res=0
MOCK_TRUNCATE_STDIN=1 "${STAGE_SCRIPT}" -v "7.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

res=0
MOCK_TRAILING_STDIN=1 "${STAGE_SCRIPT}" -v "7.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

res=0
MOCK_CORRUPT_ARCHIVE=1 "${STAGE_SCRIPT}" -v "7.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

test ! -e "${MOCK_REMOTE}/7.0.0.tar.gz"
test ! -e "${MOCK_REMOTE}/7.0.0.tar.gz.sha256"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Successful end-to-end transactional staging
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Successful end-to-end transactional staging... "
create_test_release "8.0.0" "${LOCAL_DIST}" "release-8.0.0-payload"
: > "${SSH_CALL_LOG}"
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "8.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" > "${TEST_SANDBOX}/success.log" 2>&1

grep -q "RESULT_TOKEN=STAGE_COMMITTED" "${TEST_SANDBOX}/success.log"
test -f "${MOCK_REMOTE}/8.0.0.tar.gz" -a ! -L "${MOCK_REMOTE}/8.0.0.tar.gz"
test -f "${MOCK_REMOTE}/8.0.0.tar.gz.sha256" -a ! -L "${MOCK_REMOTE}/8.0.0.tar.gz.sha256"
cmp -s "${LOCAL_DIST}/8.0.0.tar.gz" "${MOCK_REMOTE}/8.0.0.tar.gz"

PERM_ARCHIVE="$(stat -c "%a" "${MOCK_REMOTE}/8.0.0.tar.gz")"
PERM_SIDECAR="$(stat -c "%a" "${MOCK_REMOTE}/8.0.0.tar.gz.sha256")"
test "${PERM_ARCHIVE}" = "640" -a "${PERM_SIDECAR}" = "640"

(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "8.0.0.tar.gz.sha256" >/dev/null
)

# Verify persistent per-version lock anchor is a regular single-link file and TX dir is cleaned
test -f "${MOCK_REMOTE}/.gra-tx-8.0.0.flock" -a ! -L "${MOCK_REMOTE}/.gra-tx-8.0.0.flock"
test "$(stat -c '%h' "${MOCK_REMOTE}/.gra-tx-8.0.0.flock")" -eq 1
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Existing release refusal without --overwrite (and overwrite success)
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Overwrite protection on existing remote release... "
BEFORE_8_SHA="$(sha256sum "${MOCK_REMOTE}/8.0.0.tar.gz" | cut -d ' ' -f 1)"
create_test_release "8.0.0" "${LOCAL_DIST}" "release-8.0.0-new"

# Without --overwrite, must fail closed and preserve original bytes
res=0
"${STAGE_SCRIPT}" -v "8.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" > "${TEST_SANDBOX}/refuse_8.log" 2>&1 || res=$?
test "${res}" -ne 0
grep -q "RESULT_TOKEN=EXISTS_REFUSED" "${TEST_SANDBOX}/refuse_8.log"
test "$(sha256sum "${MOCK_REMOTE}/8.0.0.tar.gz" | cut -d ' ' -f 1)" = "${BEFORE_8_SHA}"

# With --overwrite, must commit cleanly
"${STAGE_SCRIPT}" -v "8.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite > "${TEST_SANDBOX}/overwrite_8.log" 2>&1
cmp -s "${LOCAL_DIST}/8.0.0.tar.gz" "${MOCK_REMOTE}/8.0.0.tar.gz"
(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "8.0.0.tar.gz.sha256" >/dev/null
)
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Cleanup of temporary transaction artifacts after failure
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Cleanup of transaction & retired artifacts after failure... "
create_test_release "9.0.0" "${LOCAL_DIST}"
MOCK_CORRUPT_ARCHIVE=1 "${STAGE_SCRIPT}" -v "9.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || true
MOCK_TRUNCATE_STDIN=1 "${STAGE_SCRIPT}" -v "9.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || true

test ! -e "${MOCK_REMOTE}/9.0.0.tar.gz"
test ! -e "${MOCK_REMOTE}/9.0.0.tar.gz.sha256"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Overwrite safety: existing release survives remote verification failure
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Overwrite safety: existing release survives remote verification fail... "
create_test_release "10.0.0" "${LOCAL_DIST}" "original-10.0.0"
"${STAGE_SCRIPT}" -v "10.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_10_SHA="$(sha256sum "${MOCK_REMOTE}/10.0.0.tar.gz" | cut -d ' ' -f 1)"

create_test_release "10.0.0" "${LOCAL_DIST}" "candidate-10.0.0"
res=0
MOCK_CORRUPT_ARCHIVE=1 "${STAGE_SCRIPT}" -v "10.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

test "$(sha256sum "${MOCK_REMOTE}/10.0.0.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_10_SHA}"
test "$(stat -c '%a' "${MOCK_REMOTE}/10.0.0.tar.gz")" = "640"
(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "10.0.0.tar.gz.sha256" >/dev/null
)
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Overwrite safety: existing release survives SSH transport failure
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Overwrite safety: existing release survives transport failure... "
create_test_release "11.0.0" "${LOCAL_DIST}" "original-11.0.0"
"${STAGE_SCRIPT}" -v "11.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_11_SHA="$(sha256sum "${MOCK_REMOTE}/11.0.0.tar.gz" | cut -d ' ' -f 1)"

create_test_release "11.0.0" "${LOCAL_DIST}" "candidate-11.0.0"
res=0
MOCK_SSH_FAIL=1 "${STAGE_SCRIPT}" -v "11.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1 || res=$?
test "${res}" -eq 255

res=0
MOCK_CORRUPT_BOOTSTRAP_SCRIPT=1 "${STAGE_SCRIPT}" -v "11.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1 || res=$?
test "${res}" -eq 71

test "$(sha256sum "${MOCK_REMOTE}/11.0.0.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_11_SHA}"
(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "11.0.0.tar.gz.sha256" >/dev/null
)
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Overwrite safety: corrupted/truncated/trailing streams rejected before commit
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] Overwrite safety: corrupt/incomplete streams rejected... "
create_test_release "12.0.0" "${LOCAL_DIST}" "original-12.0.0"
"${STAGE_SCRIPT}" -v "12.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_12_SHA="$(sha256sum "${MOCK_REMOTE}/12.0.0.tar.gz" | cut -d ' ' -f 1)"

create_test_release "12.0.0" "${LOCAL_DIST}" "candidate-12.0.0"
for hook in MOCK_CORRUPT_ARCHIVE MOCK_TRUNCATE_STDIN MOCK_TRAILING_STDIN; do
    res=0
    env "${hook}=1" "${STAGE_SCRIPT}" -v "12.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1 || res=$?
    test "${res}" -ne 0
    test "$(sha256sum "${MOCK_REMOTE}/12.0.0.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_12_SHA}"
    (
        cd "${MOCK_REMOTE}"
        sha256sum -c --strict "12.0.0.tar.gz.sha256" >/dev/null
    )
    assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
done
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Promotion rollback across all supported v6.7 failure-injection hooks
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Promotion rollback across v6.7 failure-injection hooks... "
create_test_release "13.0.0" "${LOCAL_DIST}" "original-13.0.0"
"${STAGE_SCRIPT}" -v "13.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_13_SHA="$(sha256sum "${MOCK_REMOTE}/13.0.0.tar.gz" | cut -d ' ' -f 1)"

create_test_release "13.0.0" "${LOCAL_DIST}" "candidate-13.0.0"
for fault_hook in MOCK_FAIL_AFTER_BACKUP MOCK_FAIL_AFTER_ARCH_PROMOTE MOCK_FAIL_AFTER_SIDE_PROMOTE; do
    res=0
    env "${fault_hook}=1" "${STAGE_SCRIPT}" -v "13.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1 || res=$?
    test "${res}" -ne 0
    test "$(sha256sum "${MOCK_REMOTE}/13.0.0.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_13_SHA}"
    test "$(stat -c '%a' "${MOCK_REMOTE}/13.0.0.tar.gz")" = "640"
    test "$(stat -c '%a' "${MOCK_REMOTE}/13.0.0.tar.gz.sha256")" = "640"
    (
        cd "${MOCK_REMOTE}"
        sha256sum -c --strict "13.0.0.tar.gz.sha256" >/dev/null
    )
    assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
done

# After repeated rollbacks, a healthy retry must still succeed cleanly
"${STAGE_SCRIPT}" -v "13.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite >/dev/null 2>&1
cmp -s "${LOCAL_DIST}/13.0.0.tar.gz" "${MOCK_REMOTE}/13.0.0.tar.gz"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Successful overwrite replaces both files with verified content
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Successful overwrite replaces both files cleanly... "
create_test_release "14.0.0" "${LOCAL_DIST}" "old-14.0.0"
"${STAGE_SCRIPT}" -v "14.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1

create_test_release "14.0.0" "${LOCAL_DIST}" "new-14.0.0-verified"
EXPECTED_NEW_SHA="$(cut -d ' ' -f 1 "${LOCAL_DIST}/14.0.0.tar.gz.sha256")"
export EXPECTED_NEW_SHA

"${STAGE_SCRIPT}" -v "14.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite > "${TEST_SANDBOX}/overwrite_14.log" 2>&1

test -f "${MOCK_REMOTE}/14.0.0.tar.gz" -a ! -L "${MOCK_REMOTE}/14.0.0.tar.gz"
test -f "${MOCK_REMOTE}/14.0.0.tar.gz.sha256" -a ! -L "${MOCK_REMOTE}/14.0.0.tar.gz.sha256"
cmp -s "${LOCAL_DIST}/14.0.0.tar.gz" "${MOCK_REMOTE}/14.0.0.tar.gz"
test "$(cut -d ' ' -f 1 "${MOCK_REMOTE}/14.0.0.tar.gz.sha256")" = "${EXPECTED_NEW_SHA}"
test "$(stat -c '%a' "${MOCK_REMOTE}/14.0.0.tar.gz")" = "640"
test "$(stat -c '%a' "${MOCK_REMOTE}/14.0.0.tar.gz.sha256")" = "640"
(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "14.0.0.tar.gz.sha256" >/dev/null
)
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Transaction token uniqueness & multi-version isolation
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Transaction token uniqueness & version isolation... "
create_test_release "15.0.0" "${LOCAL_DIST}" "ver-15.0.0"
create_test_release "15.1.0" "${LOCAL_DIST}" "ver-15.1.0"

: > "${SSH_CALL_LOG}"
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "15.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_15_SHA="$(sha256sum "${MOCK_REMOTE}/15.0.0.tar.gz" | cut -d ' ' -f 1)"
MOCK_SSH_CAPTURE_FILE="${SSH_CALL_LOG}" "${STAGE_SCRIPT}" -v "15.1.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1

# Staging 15.1.0 must never touch or overwrite 15.0.0
test "$(sha256sum "${MOCK_REMOTE}/15.0.0.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_15_SHA}"
test -f "${MOCK_REMOTE}/15.1.0.tar.gz"

python3 - << 'EOF'
import json, os, re

with open(os.environ['SSH_CALL_LOG'], 'r') as f:
    records = [json.loads(line) for line in f if line.strip()]

assert len(records) == 2, f"Expected 2 SSH calls, got {len(records)}"
tok_re = re.compile(r'^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$')
tx_re = re.compile(r'^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}$')

# decoded_args = [staging_dir, lock_name, STAGING_DIR, VERSION, TOKEN, TX_ID, ...]
tokens = []
tx_ids = []
locks = []
for rec in records:
    d = rec['decoded_args']
    assert len(d) >= 6, d
    locks.append(d[1])
    tokens.append(d[4])
    tx_ids.append(d[5])
    assert tok_re.fullmatch(d[4]), f"Bad session token format: {d[4]}"
    assert tx_re.fullmatch(d[5]), f"Bad TX_ID format: {d[5]}"

assert len(set(tokens)) == 2, f"Session tokens collided: {tokens}"
assert len(set(tx_ids)) == 2, f"TX IDs collided: {tx_ids}"
assert locks == [".gra-tx-15.0.0.flock", ".gra-tx-15.1.0.flock"], locks
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Puppet parameter, release_manager.py handover & documentation contract
# ------------------------------------------------------------------------------
echo -n "[Test 19/${TOTAL_COUNT}] Puppet parameter, release_manager.py & docs contract... "
python3 - << 'EOF'
import os, sys

project_root = os.environ['PROJECT_ROOT']

# 1. Verify staged artifacts from Test 17 are directly accepted by live release_manager.py
sys.path.insert(0, os.path.join(project_root, 'puppet', 'modules', 'application', 'files'))
import release_manager

verified_archive = release_manager.verify_sidecar_and_checksum(
    os.environ['MOCK_REMOTE'],
    '14.0.0',
    os.environ['EXPECTED_NEW_SHA'],
)
assert verified_archive == os.path.join(os.environ['MOCK_REMOTE'], '14.0.0.tar.gz')

# 2. Verify Puppet manifests bind top-level application::release_version and expected_sha256
init_pp = open(os.path.join(project_root, 'puppet', 'modules', 'application', 'manifests', 'init.pp'), 'r', encoding='utf-8').read()
release_pp = open(os.path.join(project_root, 'puppet', 'modules', 'application', 'manifests', 'release.pp'), 'r', encoding='utf-8').read()

assert "$release_version" in init_pp and "$expected_sha256" in init_pp
assert "version               => $release_version" in init_pp
assert "expected_sha256       => $expected_sha256" in init_pp
assert "application::release::expected_sha256" not in init_pp
assert "application::release::expected_sha256" not in release_pp
assert "$staging_dir            = '/var/cache/git-repo-analyzer/staging'" in release_pp
assert "mode    => '0750'" in release_pp

# 3. Verify stage_release.sh log and documentation files avoid deprecated Hiera namespace
log_content = open(os.path.join(os.environ['TEST_SANDBOX'], 'overwrite_14.log'), 'r', encoding='utf-8').read()
assert "RESULT_TOKEN=STAGE_COMMITTED" in log_content
assert "application::release::expected_sha256" not in log_content

staging_doc = open(os.path.join(project_root, 'project_docs', 'RELEASE_STAGING.md'), 'r', encoding='utf-8').read()
assert "application::release_version:" in staging_doc
assert "application::expected_sha256:" in staging_doc
assert "application::release::expected_sha256" not in staging_doc

pkg_doc_path = os.path.join(project_root, 'project_docs', 'RELEASE_PACKAGING.md')
if os.path.exists(pkg_doc_path):
    assert "application::release::expected_sha256" not in open(pkg_doc_path, 'r', encoding='utf-8').read()
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 20. Transaction locking & concurrent/unresolved-TX exclusion
# ------------------------------------------------------------------------------
echo -n "[Test 20/${TOTAL_COUNT}] Transaction locking & concurrent exclusion... "
create_test_release "16.0.0" "${LOCAL_DIST}" "ver-16.0.0"
"${STAGE_SCRIPT}" -v "16.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1

# Hold flock on .gra-tx-16.0.0.flock in a child process
python3 -c "import fcntl, os, time; fd=os.open('${MOCK_REMOTE}/.gra-tx-16.0.0.flock', os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(2)" &
lock_holder_pid=$!
sleep 0.3

res=0
"${STAGE_SCRIPT}" -v "16.0.0" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite > "${TEST_SANDBOX}/busy_stage.log" 2>&1 || res=$?
test "${res}" -eq 75
grep -q "RESULT_TOKEN=MUTEX_BUSY" "${TEST_SANDBOX}/busy_stage.log"

res=0
"${STAGE_SCRIPT}" --recover -v "16.0.0" --tx-token "20261127T211500Z-0123456789abcdef0123456789abcdef" -H "app-server" -r "${MOCK_REMOTE}" > "${TEST_SANDBOX}/busy_recover.log" 2>&1 || res=$?
test "${res}" -eq 75
grep -q "RESULT_TOKEN=MUTEX_BUSY" "${TEST_SANDBOX}/busy_recover.log"

wait "${lock_holder_pid}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 21. Deliberate --recover lifecycle & TX_RECOVERY_REQUIRED backup preservation
# ------------------------------------------------------------------------------
echo -n "[Test 21/${TOTAL_COUNT}] Deliberate --recover & TX_RECOVERY_REQUIRED preservation... "
source "${V67_COMMON}"

REC_VER="17.0.0"
create_test_release "${REC_VER}" "${LOCAL_DIST}" "orig-17.0.0"
"${STAGE_SCRIPT}" -v "${REC_VER}" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_17_SHA="$(sha256sum "${MOCK_REMOTE}/${REC_VER}.tar.gz" | cut -d ' ' -f 1)"
ORIG_17_SIDE_SHA="$(sha256sum "${MOCK_REMOTE}/${REC_VER}.tar.gz.sha256" | cut -d ' ' -f 1)"

create_test_release "${REC_VER}" "${LOCAL_DIST}" "partial-17.0.0"
NEW_17_SHA="$(cut -d ' ' -f 1 "${LOCAL_DIST}/${REC_VER}.tar.gz.sha256")"
NEW_17_SIDE_SHA="$(sha256sum "${LOCAL_DIST}/${REC_VER}.tar.gz.sha256" | cut -d ' ' -f 1)"

REC_TX="20261128T010000Z-5555-0011223344556677"
REC_TOK="20261128T010000Z-00112233445566770011223344556677"
BAD_TOK="20261128T010000Z-ffffffffffffffffffffffffffffffff"
REC_TX_DIR="${MOCK_REMOTE}/.tx-${REC_VER}"

mkdir -p "${REC_TX_DIR}/backup" "${REC_TX_DIR}/stage"
chmod 0700 "${REC_TX_DIR}"
cp -p "${MOCK_REMOTE}/${REC_VER}.tar.gz" "${REC_TX_DIR}/backup/${REC_VER}.tar.gz"
cp -p "${MOCK_REMOTE}/${REC_VER}.tar.gz.sha256" "${REC_TX_DIR}/backup/${REC_VER}.tar.gz.sha256"
write_state_atomic "${REC_TX_DIR}/token" "${REC_TOK}" "${REC_TX_DIR}"
write_state_atomic "${REC_TX_DIR}/tx_id" "${REC_TX}" "${REC_TX_DIR}"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=%s\nSESSION_TOKEN=%s\nARCHIVE_NAME=%s.tar.gz\nARCHIVE_BASELINE_EXISTS=1\nARCHIVE_BASELINE_SHA=%s\nARCHIVE_STAGE_SHA=%s\nSIDECAR_NAME=%s.tar.gz.sha256\nSIDECAR_BASELINE_EXISTS=1\nSIDECAR_BASELINE_SHA=%s\nSIDECAR_STAGE_SHA=%s\n' \
    "${REC_TX}" "${REC_VER}" "${REC_TOK}" "${REC_VER}" "${ORIG_17_SHA}" "${NEW_17_SHA}" "${REC_VER}" "${ORIG_17_SIDE_SHA}" "${NEW_17_SIDE_SHA}" > "${REC_TX_DIR}/manifest.env"
write_bound_state_atomic "${REC_TX_DIR}/journal.ARCHIVE" "${REC_TX}" "STATE" "CANONICAL_DIR_SYNCED" "${REC_TX_DIR}"
write_bound_state_atomic "${REC_TX_DIR}/journal.SIDECAR" "${REC_TX}" "STATE" "PROMOTE_INTENT" "${REC_TX_DIR}"
write_bound_state_atomic "${REC_TX_DIR}/tx_phase" "${REC_TX}" "PHASE" "TX_PROMOTING" "${REC_TX_DIR}"

# Simulate half-promoted canonical target + blocked normal transfer
cp -p "${LOCAL_DIST}/${REC_VER}.tar.gz" "${MOCK_REMOTE}/${REC_VER}.tar.gz"

res=0
"${STAGE_SCRIPT}" -v "${REC_VER}" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" --overwrite > "${TEST_SANDBOX}/blocked_tx.log" 2>&1 || res=$?
test "${res}" -ne 0
grep -q "RESULT_TOKEN=LOCKED_OR_RECOVERY_REQUIRED" "${TEST_SANDBOX}/blocked_tx.log"

# Unauthorized --recover (wrong --tx-token) must be rejected without mutating TX state
res=0
"${STAGE_SCRIPT}" --recover -v "${REC_VER}" --tx-token "${BAD_TOK}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0

# Missing archive backup must transition durably to TX_RECOVERY_REQUIRED while keeping sidecar backup intact
mv "${REC_TX_DIR}/backup/${REC_VER}.tar.gz" "${TEST_SANDBOX}/saved_17_bak"
res=0
"${STAGE_SCRIPT}" --recover -v "${REC_VER}" --tx-token "${REC_TOK}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
read_bound_state_file "${REC_TX_DIR}/tx_phase" "${REC_TX}" "PHASE" "^TX_RECOVERY_REQUIRED$"
test -f "${REC_TX_DIR}/backup/${REC_VER}.tar.gz.sha256"

# Restore backup and run authorized --recover out of TX_RECOVERY_REQUIRED
mv "${TEST_SANDBOX}/saved_17_bak" "${REC_TX_DIR}/backup/${REC_VER}.tar.gz"
"${STAGE_SCRIPT}" --recover -v "${REC_VER}" --tx-token "${REC_TOK}" -H "app-server" -r "${MOCK_REMOTE}" > "${TEST_SANDBOX}/recover_17_ok.log" 2>&1
grep -q "RESULT_TOKEN=RECOVERED_SUCCESS" "${TEST_SANDBOX}/recover_17_ok.log"
test "$(sha256sum "${MOCK_REMOTE}/${REC_VER}.tar.gz" | cut -d ' ' -f 1)" = "${ORIG_17_SHA}"
test "$(stat -c '%a' "${MOCK_REMOTE}/${REC_VER}.tar.gz")" = "640"
(
    cd "${MOCK_REMOTE}"
    sha256sum -c --strict "${REC_VER}.tar.gz.sha256" >/dev/null
)
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 22. Journal/manifest tamper fail-closed & retired cleanup resumption
# ------------------------------------------------------------------------------
echo -n "[Test 22/${TOTAL_COUNT}] Journal tamper fail-closed & retired cleanup resumption... "
# 22a. Invalid journal state must transition into TX_RECOVERY_REQUIRED without deleting backup
TAM_VER="18.0.0"
create_test_release "${TAM_VER}" "${LOCAL_DIST}" "orig-18.0.0"
"${STAGE_SCRIPT}" -v "${TAM_VER}" -d "${LOCAL_DIST}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1
ORIG_18_SHA="$(sha256sum "${MOCK_REMOTE}/${TAM_VER}.tar.gz" | cut -d ' ' -f 1)"
ORIG_18_SIDE_SHA="$(sha256sum "${MOCK_REMOTE}/${TAM_VER}.tar.gz.sha256" | cut -d ' ' -f 1)"
TAM_TX="20261128T010000Z-7777-8899aabbccddeeff"
TAM_TOK="20261128T010000Z-8899aabbccddeeff8899aabbccddeeff"
TAM_DIR="${MOCK_REMOTE}/.tx-${TAM_VER}"

mkdir -p "${TAM_DIR}/backup" "${TAM_DIR}/stage"
chmod 0700 "${TAM_DIR}"
cp -p "${MOCK_REMOTE}/${TAM_VER}.tar.gz" "${TAM_DIR}/backup/${TAM_VER}.tar.gz"
cp -p "${MOCK_REMOTE}/${TAM_VER}.tar.gz.sha256" "${TAM_DIR}/backup/${TAM_VER}.tar.gz.sha256"
write_state_atomic "${TAM_DIR}/token" "${TAM_TOK}" "${TAM_DIR}"
write_state_atomic "${TAM_DIR}/tx_id" "${TAM_TX}" "${TAM_DIR}"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=%s\nSESSION_TOKEN=%s\nARCHIVE_NAME=%s.tar.gz\nARCHIVE_BASELINE_EXISTS=1\nARCHIVE_BASELINE_SHA=%s\nARCHIVE_STAGE_SHA=%s\nSIDECAR_NAME=%s.tar.gz.sha256\nSIDECAR_BASELINE_EXISTS=1\nSIDECAR_BASELINE_SHA=%s\nSIDECAR_STAGE_SHA=%s\n' \
    "${TAM_TX}" "${TAM_VER}" "${TAM_TOK}" "${TAM_VER}" "${ORIG_18_SHA}" "${ORIG_18_SHA}" "${TAM_VER}" "${ORIG_18_SIDE_SHA}" "${ORIG_18_SIDE_SHA}" > "${TAM_DIR}/manifest.env"
write_bound_state_atomic "${TAM_DIR}/journal.ARCHIVE" "${TAM_TX}" "STATE" "TAMPERED_UNKNOWN_STATE" "${TAM_DIR}"
write_bound_state_atomic "${TAM_DIR}/journal.SIDECAR" "${TAM_TX}" "STATE" "BACKUP_DIR_SYNCED" "${TAM_DIR}"
write_bound_state_atomic "${TAM_DIR}/tx_phase" "${TAM_TX}" "PHASE" "TX_PROMOTING" "${TAM_DIR}"

res=0
"${STAGE_SCRIPT}" --recover -v "${TAM_VER}" --tx-token "${TAM_TOK}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
read_bound_state_file "${TAM_DIR}/tx_phase" "${TAM_TX}" "PHASE" "^TX_RECOVERY_REQUIRED$"
test -f "${TAM_DIR}/backup/${TAM_VER}.tar.gz"
rm -rf "${TAM_DIR}"

# 22b. Retired cleanup: rogue file blocked, AUTH_TAG checked after token unlink, valid token finishes cleanly
RET_TAG="$(compute_auth_tag "${TAM_VER}" "${TAM_TX}" "${TAM_TOK}")"
RET_DIR="${MOCK_REMOTE}/.tx-retired-${TAM_VER}-${TAM_TX}-${RET_TAG}"
mkdir -p "${RET_DIR}"
chmod 0700 "${RET_DIR}"
write_bound_state_atomic "${RET_DIR}/tx_phase" "${TAM_TX}" "PHASE" "TX_FINALIZING_PRUNING_AUX" "${RET_DIR}"
write_state_atomic "${RET_DIR}/token" "${TAM_TOK}" "${RET_DIR}"
printf 'rogue' > "${RET_DIR}/unexpected_artifact"

res=0
"${STAGE_SCRIPT}" --recover -v "${TAM_VER}" --tx-token "${TAM_TOK}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
test -f "${RET_DIR}/tx_phase"

rm -f "${RET_DIR}/unexpected_artifact" "${RET_DIR}/token"
write_bound_state_atomic "${RET_DIR}/tx_phase" "${TAM_TX}" "PHASE" "TX_FINALIZING_PRUNING_TOKEN" "${RET_DIR}"

# Wrong token rejected even with token file already unlinked (via AUTH_TAG binding)
res=0
"${STAGE_SCRIPT}" --recover -v "${TAM_VER}" --tx-token "${BAD_TOK}" -H "app-server" -r "${MOCK_REMOTE}" >/dev/null 2>&1 || res=$?
test "${res}" -ne 0
test -f "${RET_DIR}/tx_phase"

# Authorized recovery completes retired cleanup
"${STAGE_SCRIPT}" --recover -v "${TAM_VER}" --tx-token "${TAM_TOK}" -H "app-server" -r "${MOCK_REMOTE}" > "${TEST_SANDBOX}/recover_retired.log" 2>&1
grep -q "RESULT_TOKEN=RECOVERED_RETIRED_SUCCESS" "${TEST_SANDBOX}/recover_retired.log"
assert_no_leaked_tx_artifacts "${MOCK_REMOTE}"
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "All ${PASSED_COUNT}/${TOTAL_COUNT} v6.7 Application Release Staging Tests PASSED"
echo "=============================================================================="
