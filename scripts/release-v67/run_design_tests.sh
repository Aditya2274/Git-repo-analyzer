#!/usr/bin/env bash
# Failure-Injection & Verification Test Suite for v6.7 Release-Management Prototype.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SCRIPT="${SCRIPT_DIR}/packaging_tx.sh"
STG_SCRIPT="${SCRIPT_DIR}/staging_tx.sh"
COMMON_SCRIPT="${SCRIPT_DIR}/design_common.sh"
TEST_SCRIPT="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

chmod +x "${PKG_SCRIPT}" "${STG_SCRIPT}" "${COMMON_SCRIPT}" "${TEST_SCRIPT}"

SANDBOX="$(mktemp -d -t gra-v67-evidence-XXXXXX)"
cleanup_sandbox() {
    rm -rf -- "${SANDBOX}"
}
trap cleanup_sandbox EXIT INT TERM

PASS=0
FAIL=0

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "${actual}" = "${expected}" ]; then
        echo "  [PASS] ${msg}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${msg}: actual='${actual}' expected='${expected}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_nonzero() {
    local rc="$1" msg="$2"
    if [ "${rc}" -ne 0 ]; then
        echo "  [PASS] ${msg} (rc=${rc})"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${msg}: expected nonzero exit, got 0" >&2
        FAIL=$((FAIL + 1))
    fi
}

echo "=== 1. Bash Syntax Validation ==="
for f in "${COMMON_SCRIPT}" "${PKG_SCRIPT}" "${STG_SCRIPT}" "${TEST_SCRIPT}"; do
    bash -n "${f}"
    echo "  [PASS] bash -n $(basename "${f}")"
    PASS=$((PASS + 1))
done

# Setup Mock SSH Binary delegating command cleanly to sandbox local execution while honoring SSH env fault hooks
MOCK_BIN="${SANDBOX}/mock_bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/ssh" << 'EOF_MOCK_SSH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MOCK_SSH_FAIL_255:-0}" = "1" ]; then
    echo "mock-ssh: Network unreachable" >&2
    exit 255
fi
args=("$@")
cmd="${args[${#args[@]}-1]}"
if [ "${MOCK_CORRUPT_B64:-0}" = "1" ]; then
    cmd="$(python3 -c '
import re, sys
s = sys.argv[1]
s2 = re.sub(r"\x27[0-9a-f]{64}\x27", "\x27" + "0"*64 + "\x27", s, count=1)
print(s2)
' "${cmd}")"
fi
if [ "${MOCK_CORRUPT_ARGS:-0}" = "1" ]; then
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
    (cat; printf 'TRAILING_JUNK') | eval "${cmd}"
elif [ "${MOCK_CORRUPT_ARCHIVE:-0}" = "1" ]; then
    python3 -c 'import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(bytes([b^0xff for b in d[:4]]) + d[4:])' | eval "${cmd}"
else
    eval "${cmd}"
fi
EOF_MOCK_SSH
chmod +x "${MOCK_BIN}/ssh"
export PATH="${MOCK_BIN}:${PATH}"

# Enforce deterministic clean permissions (0750) on test staging/dist roots
LOCAL_DIST="${SANDBOX}/local_dist"
REMOTE_STAGING="${SANDBOX}/remote_staging"
mkdir -p "${LOCAL_DIST}" "${REMOTE_STAGING}" "${SANDBOX}/payload_src"
chmod 0750 "${LOCAL_DIST}" "${REMOTE_STAGING}"
printf 'hello $() '\''" ` \x00\x01\x02 binary payload\n' > "${SANDBOX}/payload_src/file.bin"
dd if=/dev/urandom bs=1024 count=4 of="${SANDBOX}/payload_src/rand.bin" 2>/dev/null
tar -czf "${LOCAL_DIST}/1.0.0.tar.gz" -C "${SANDBOX}/payload_src" .
(cd "${LOCAL_DIST}" && sha256sum "1.0.0.tar.gz" > "1.0.0.tar.gz.sha256")
ARCHIVE_SHA="$(cut -d ' ' -f 1 "${LOCAL_DIST}/1.0.0.tar.gz.sha256")"

echo "=== 2. SSH Transport, Safe Argument Serialization, Script Delivery & Stream Boundaries ==="
source "${COMMON_SCRIPT}"
source "${STG_SCRIPT}"
build_ssh_exec_opts "" "" "22"

# 2.0 Safe argument serialization across simulated OpenSSH sh -c boundary (spaces, quotes, $, newlines, backslashes, empty)
PWN_MARKER="${SANDBOX}/should_not_exist"
ARG_TEST_SCRIPT='
set -euo pipefail
exec 9>&-
python3 - "$@" << "EOF_CHK"
import json, sys
print(json.dumps(sys.argv[1:]))
EOF_CHK
'
a_space="hello world"
a_sq="single'quote'here"
a_dq='double"quote"here'
a_meta="; | & > < * ? [ ] { } # ~"
a_dollar="\$HOME \$(touch '${PWN_MARKER}') \`id\`"
a_bs='foo\bar\\baz'
a_nl=$'line1\nline2\nline3'
a_empty=""
out_json=""
out_json="$(run_ssh_command_with_locked_anchor "ubuntu" "app-server" "${REMOTE_STAGING}" ".gra-test-args.flock" \
    "${ARG_TEST_SCRIPT}" "/dev/null" \
    "${a_space}" "${a_sq}" "${a_dq}" "${a_meta}" "${a_dollar}" "${a_bs}" "${a_nl}" "${a_empty}")"
exp_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' \
    "${a_space}" "${a_sq}" "${a_dq}" "${a_meta}" "${a_dollar}" "${a_bs}" "${a_nl}" "${a_empty}")"
assert_eq "${out_json}" "${exp_json}" "Remote bash received spaces, single/double quotes, $, newlines, backslashes, metacharacters, empty arg verbatim"
[ ! -e "${PWN_MARKER}" ]
assert_eq "$?" "0" "Command substitution inside SSH arguments did not execute"

rc=0
MOCK_CORRUPT_ARGS=1 run_ssh_command_with_locked_anchor "ubuntu" "app-server" "${REMOTE_STAGING}" ".gra-test-args.flock" \
    "${ARG_TEST_SCRIPT}" "/dev/null" "arg1" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "71" "Corrupted serialized argument digest rejected cleanly (exit 71)"
# 2a. Script delivery corrupt SHA -> propagates exit 71 cleanly (does NOT return 0!)
rc=0
MOCK_CORRUPT_B64=1 "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "71" "Script-delivery corruption propagates remote exit 71 via non-negated ssh check"

# 2b. SSH disconnect (255) propagates 255 cleanly
rc=0
MOCK_SSH_FAIL_255=1 "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "255" "SSH disconnect exit 255 propagates cleanly without inversion"

# 2c. Truncated upload stream fails nonzero and cleans TX_DIR
rc=0
MOCK_TRUNCATE_STDIN=1 "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Truncated archive stream rejected cleanly"
[ ! -e "${REMOTE_STAGING}/1.0.0.tar.gz" ] && [ ! -e "${REMOTE_STAGING}/.tx-1.0.0" ]
assert_eq "$?" "0" "Canonical untouched and TX_DIR cleaned on truncated stream"

# 2d. Extra trailing bytes rejected cleanly
rc=0
MOCK_TRAILING_STDIN=1 "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Extra trailing bytes after archive rejected cleanly"

# 2e. Corrupt binary stream caught cleanly
rc=0
MOCK_CORRUPT_ARCHIVE=1 "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Corrupted archive stream SHA-256 mismatch rejected"

# 2f. End-to-end real binary archive transfer over separate channel (argv script + stdin archive)
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" > "${SANDBOX}/stg_ok.log" 2>&1 || rc=$?
assert_eq "${rc}" "0" "End-to-end binary archive transfer via separated channels succeeds"
remote_sha="$(sha256sum "${REMOTE_STAGING}/1.0.0.tar.gz" | cut -d ' ' -f 1)"
assert_eq "${remote_sha}" "${ARCHIVE_SHA}" "Remote archive matches binary SHA-256 bit-for-bit"
assert_eq "$(stat -c '%a' "${REMOTE_STAGING}/1.0.0.tar.gz")" "640" "Remote archive mode 0640 preserved"
assert_eq "$(stat -c '%a' "${REMOTE_STAGING}/1.0.0.tar.gz.sha256")" "640" "Remote sidecar mode 0640 preserved"

echo "=== 3. Lock Anchor Symlink, Hardlink & Concurrency Tests ==="
# 3a. Symlink attack on .gra-tx-1.0.0.flock rejected with exit 73 (O_NOFOLLOW ELOOP)
rm -f "${REMOTE_STAGING}/.gra-tx-1.0.0.flock"
ln -s "${SANDBOX}/victim_file" "${REMOTE_STAGING}/.gra-tx-1.0.0.flock"
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" --overwrite >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "73" "Lock-anchor symlink rejected by kernel O_NOFOLLOW (exit 73)"
[ ! -e "${SANDBOX}/victim_file" ]
assert_eq "$?" "0" "Symlink target victim untouched"
rm -f "${REMOTE_STAGING}/.gra-tx-1.0.0.flock"

# 3b. Hardlink attack on .gra-tx-1.0.0.flock rejected with exit 74 (st_nlink > 1)
printf 'victim' > "${SANDBOX}/hardlink_victim"
ln "${SANDBOX}/hardlink_victim" "${REMOTE_STAGING}/.gra-tx-1.0.0.flock"
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" --overwrite >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "74" "Lock-anchor hardlink rejected (st_nlink != 1 -> exit 74)"
rm -f "${REMOTE_STAGING}/.gra-tx-1.0.0.flock" "${SANDBOX}/hardlink_victim"

# 3c. Parent directory ownership & permissions checks (reject group-writable 0o020, world-writable 0o002, foreign UID)
DIR_PERM_TEST="${SANDBOX}/dir_perm_test"
mkdir -p "${DIR_PERM_TEST}"
chmod 0770 "${DIR_PERM_TEST}"
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${DIR_PERM_TEST}" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "72" "Group-writable parent directory (0770) rejected (exit 72)"

chmod 0757 "${DIR_PERM_TEST}"
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${DIR_PERM_TEST}" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "72" "World-writable parent directory (0757) rejected (exit 72)"

rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "/etc" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "72" "Parent directory not owned by executing UID (/etc) rejected (exit 72)"
chmod 0750 "${DIR_PERM_TEST}"

# 3d. Concurrent staging & recovery rejected cleanly with exit 75 (MUTEX_BUSY)
touch "${REMOTE_STAGING}/.gra-tx-1.0.0.flock"
python3 -c "import fcntl, os, time; fd=os.open('${REMOTE_STAGING}/.gra-tx-1.0.0.flock', os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(2)" &
holder_pid=$!
sleep 0.3
rc=0
"${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_DIST}" -r "${REMOTE_STAGING}" --overwrite >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "75" "Concurrent staging rejected while lock held (MUTEX_BUSY exit 75)"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "20261127T211500Z-0123456789abcdef0123456789abcdef" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_eq "${rc}" "75" "Concurrent recovery rejected while lock held (MUTEX_BUSY exit 75)"
wait "${holder_pid}"

echo "=== 4. Path Boundary Validation & Manifest Parser Checks ==="
source "${COMMON_SCRIPT}"
source "${PKG_SCRIPT}"
# 4a. Sibling prefix escape attempt must fail containment
mkdir -p "${SANDBOX}/bound_root_evil"
mkdir -p "${SANDBOX}/bound_root"
printf 'x' > "${SANDBOX}/bound_root_evil/target"
rc=0
safe_unlink_if_present "${SANDBOX}/bound_root" "${SANDBOX}/bound_root_evil/target" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "String-prefix sibling escape (/bound_root_evil) rejected by path-boundary check"
[ -f "${SANDBOX}/bound_root_evil/target" ]
assert_eq "$?" "0" "Sibling prefix target file preserved"

# 4b. Manifest parser tests (EOF, final newline, empty, CRLF, duplicate, unknown, wrong TX_ID, wrong token)
M_VER="1.2.0"
M_TX="20261127T211500Z-4120-a1b2c3d4e5f60708"
M_TOK="20261127T211500Z-0123456789abcdef0123456789abcdef"
S_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
write_test_manifest() {
    local out="$1" tx="$2" tok="$3" extra="${4:-}"
    printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=%s\nSESSION_TOKEN=%s\n' "${tx}" "${M_VER}" "${tok}" > "${out}"
    printf 'ART_1_NAME=git-repo-analyzer-release-%s.tar.gz\nART_1_BASELINE_EXISTS=0\nART_1_BASELINE_SHA=NONE\nART_1_STAGE_SHA=%s\n' "${M_VER}" "${S_HASH}" >> "${out}"
    printf 'ART_2_NAME=git-repo-analyzer-release-%s.tar.gz.sha256\nART_2_BASELINE_EXISTS=0\nART_2_BASELINE_SHA=NONE\nART_2_STAGE_SHA=%s\n' "${M_VER}" "${S_HASH}" >> "${out}"
    printf 'ART_3_NAME=%s.tar.gz\nART_3_BASELINE_EXISTS=0\nART_3_BASELINE_SHA=NONE\nART_3_STAGE_SHA=%s\n' "${M_VER}" "${S_HASH}" >> "${out}"
    printf 'ART_4_NAME=%s.tar.gz.sha256\nART_4_BASELINE_EXISTS=0\nART_4_BASELINE_SHA=NONE\nART_4_STAGE_SHA=%s\n' "${M_VER}" "${S_HASH}" >> "${out}"
    [ -n "${extra}" ] && printf '%b' "${extra}" >> "${out}" || true
}

write_test_manifest "${SANDBOX}/m_valid.env" "${M_TX}" "${M_TOK}"
parse_and_validate_packaging_manifest "${SANDBOX}/m_valid.env" "${M_VER}" "${M_TX}" "${M_TOK}"
assert_eq "$?" "0" "Valid manifest with trailing newline accepted"

truncate -s -1 "${SANDBOX}/m_valid.env" # Remove final \n
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_valid.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Manifest missing final newline rejected cleanly"

: > "${SANDBOX}/m_empty.env"
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_empty.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Empty manifest rejected"

write_test_manifest "${SANDBOX}/m_dup.env" "${M_TX}" "${M_TOK}" "VERSION=1.2.0\n"
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_dup.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Duplicate manifest key rejected"

write_test_manifest "${SANDBOX}/m_unk.env" "${M_TX}" "${M_TOK}" "EVIL=1\n"
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_unk.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Unknown manifest key rejected"

write_test_manifest "${SANDBOX}/m_badtx.env" "20261127T211500Z-9999-ffffffffffffffff" "${M_TOK}"
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_badtx.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "TX_ID mismatch between directory identity and manifest rejected"

write_test_manifest "${SANDBOX}/m_badtok.env" "${M_TX}" "20261127T211500Z-ffffffffffffffffffffffffffffffff"
rc=0; parse_and_validate_packaging_manifest "${SANDBOX}/m_badtok.env" "${M_VER}" "${M_TX}" "${M_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Manifest SESSION_TOKEN mismatch against supplied/stored token rejected"

echo "=== 5. Failure-Injection: Non-Destructive Rollback & Packaging Recovery ==="
PKG_OUT="${SANDBOX}/pkg_out"
# Seed baseline release 2.0.0 (last known-good release)
"${PKG_SCRIPT}" --package "${PKG_OUT}" "2.0.0" "${SANDBOX}/payload_src" >/dev/null
GOOD_PRI_SHA="$(sha256sum "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" | cut -d ' ' -f 1)"
GOOD_CMP_SHA="$(sha256sum "${PKG_OUT}/2.0.0.tar.gz" | cut -d ' ' -f 1)"

# Build different candidate payload and inject failure at EVERY promotion step (AFTER_BACKUP, AFTER_PROMOTE_1..4)
mkdir -p "${SANDBOX}/payload_new"
printf 'new candidate release' > "${SANDBOX}/payload_new/app.txt"
for pkg_fault in AFTER_BACKUP AFTER_PROMOTE_1 AFTER_PROMOTE_2 AFTER_PROMOTE_3 AFTER_PROMOTE_4; do
    rc=0
    PKG_FAIL_AT="${pkg_fault}" "${PKG_SCRIPT}" --package "${PKG_OUT}" "2.0.0" "${SANDBOX}/payload_new" >/dev/null 2>&1 || rc=$?
    assert_nonzero "${rc}" "Injected packaging failure (${pkg_fault}) fails nonzero"
    assert_eq "$(sha256sum "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" | cut -d ' ' -f 1)" "${GOOD_PRI_SHA}" "After ${pkg_fault}, ART_1 restored to last-known-good SHA"
    assert_eq "$(sha256sum "${PKG_OUT}/2.0.0.tar.gz" | cut -d ' ' -f 1)" "${GOOD_CMP_SHA}" "After ${pkg_fault}, ART_3 restored to last-known-good SHA"
    (cd "${PKG_OUT}" && sha256sum -c --strict "git-repo-analyzer-release-2.0.0.tar.gz.sha256" >/dev/null && sha256sum -c --strict "2.0.0.tar.gz.sha256" >/dev/null)
    assert_eq "$?" "0" "After ${pkg_fault}, both sidecars verify cleanly"
done

# Inject simulated SIGKILL-like interruption leaving TX_DIR half-promoted -> test deliberate --recover + wrong token + missing backup + unexpected file
SIM_TX_ID="20261127T211500Z-5555-0123456789abcdef"
SIM_TOK="20261127T211500Z-0123456789abcdef0123456789abcdef"
SIM_BAD_TOK="20261127T211500Z-fedcba9876543210fedcba9876543210"
SIM_DIR="${PKG_OUT}/.pkg-tx-2.0.0-${SIM_TX_ID}"
mkdir -p "${SIM_DIR}/backup" "${SIM_DIR}/stage"
cp -p "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" "${SIM_DIR}/backup/"
cp -p "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz.sha256" "${SIM_DIR}/backup/"
cp -p "${PKG_OUT}/2.0.0.tar.gz" "${SIM_DIR}/backup/"
cp -p "${PKG_OUT}/2.0.0.tar.gz.sha256" "${SIM_DIR}/backup/"
B1="$(sha256sum "${SIM_DIR}/backup/git-repo-analyzer-release-2.0.0.tar.gz" | cut -d ' ' -f 1)"
B2="$(sha256sum "${SIM_DIR}/backup/git-repo-analyzer-release-2.0.0.tar.gz.sha256" | cut -d ' ' -f 1)"
B3="$(sha256sum "${SIM_DIR}/backup/2.0.0.tar.gz" | cut -d ' ' -f 1)"
B4="$(sha256sum "${SIM_DIR}/backup/2.0.0.tar.gz.sha256" | cut -d ' ' -f 1)"
STG_NEW_SHA="$(printf 'tampered partial' | sha256sum | cut -d ' ' -f 1)"

printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=2.0.0\nSESSION_TOKEN=%s\n' "${SIM_TX_ID}" "${SIM_TOK}" > "${SIM_DIR}/manifest.env"
printf 'ART_1_NAME=git-repo-analyzer-release-2.0.0.tar.gz\nART_1_BASELINE_EXISTS=1\nART_1_BASELINE_SHA=%s\nART_1_STAGE_SHA=%s\n' "${B1}" "${STG_NEW_SHA}" >> "${SIM_DIR}/manifest.env"
printf 'ART_2_NAME=git-repo-analyzer-release-2.0.0.tar.gz.sha256\nART_2_BASELINE_EXISTS=1\nART_2_BASELINE_SHA=%s\nART_2_STAGE_SHA=%s\n' "${B2}" "${STG_NEW_SHA}" >> "${SIM_DIR}/manifest.env"
printf 'ART_3_NAME=2.0.0.tar.gz\nART_3_BASELINE_EXISTS=1\nART_3_BASELINE_SHA=%s\nART_3_STAGE_SHA=%s\n' "${B3}" "${STG_NEW_SHA}" >> "${SIM_DIR}/manifest.env"
printf 'ART_4_NAME=2.0.0.tar.gz.sha256\nART_4_BASELINE_EXISTS=1\nART_4_BASELINE_SHA=%s\nART_4_STAGE_SHA=%s\n' "${B4}" "${STG_NEW_SHA}" >> "${SIM_DIR}/manifest.env"

write_state_atomic "${SIM_DIR}/token" "${SIM_TOK}" "${SIM_DIR}"
write_state_atomic "${SIM_DIR}/tx_id" "${SIM_TX_ID}" "${SIM_DIR}"
write_bound_state_atomic "${SIM_DIR}/tx_phase" "${SIM_TX_ID}" "PHASE" "TX_PROMOTING" "${SIM_DIR}"
write_bound_state_atomic "${SIM_DIR}/journal.ART_1" "${SIM_TX_ID}" "STATE" "CANONICAL_DIR_SYNCED" "${SIM_DIR}"
write_bound_state_atomic "${SIM_DIR}/journal.ART_2" "${SIM_TX_ID}" "STATE" "BACKUP_DIR_SYNCED" "${SIM_DIR}"
write_bound_state_atomic "${SIM_DIR}/journal.ART_3" "${SIM_TX_ID}" "STATE" "BACKUP_DIR_SYNCED" "${SIM_DIR}"
write_bound_state_atomic "${SIM_DIR}/journal.ART_4" "${SIM_TX_ID}" "STATE" "BACKUP_DIR_SYNCED" "${SIM_DIR}"

# Overwrite canonical ART_1 as if killed mid-promotion
printf 'tampered partial' > "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz"

# 5a. Normal packaging blocked while unresolved TX exists
rc=0
"${PKG_SCRIPT}" --package "${PKG_OUT}" "2.0.0" "${SANDBOX}/payload_new" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Normal packaging refuses to run while unresolved TX exists"

# 5b. Wrong --tx-token rejected on active --recover
rc=0
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${SIM_DIR}" --tx-token "${SIM_BAD_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Unauthorized active --recover (wrong --tx-token) rejected"

# 5c. Missing backup (remove backup 3 while journal fails recovery if ART_3 needed restore -> simulate missing backup + PROMOTE_INTENT)
mv "${SIM_DIR}/backup/2.0.0.tar.gz" "${SANDBOX}/saved_bak_3"
write_bound_state_atomic "${SIM_DIR}/journal.ART_3" "${SIM_TX_ID}" "STATE" "PROMOTE_INTENT" "${SIM_DIR}"
printf 'corrupt3' > "${PKG_OUT}/2.0.0.tar.gz"
rc=0
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${SIM_DIR}" --tx-token "${SIM_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Missing backup during restoration transitions cleanly to TX_RECOVERY_REQUIRED"
read_bound_state_file "${SIM_DIR}/tx_phase" "${SIM_TX_ID}" "PHASE" "^TX_RECOVERY_REQUIRED$"
assert_eq "$?" "0" "tx_phase transitioned durably to TX_RECOVERY_REQUIRED while keeping remaining backups"
[ -f "${SIM_DIR}/backup/git-repo-analyzer-release-2.0.0.tar.gz" ]
assert_eq "$?" "0" "Non-destructive rollback kept ART_1 backup preserved on disk after ART_3 failure"

# Restore saved backup (operator fix) and deliberately recover out of TX_RECOVERY_REQUIRED
mv "${SANDBOX}/saved_bak_3" "${SIM_DIR}/backup/2.0.0.tar.gz"
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${SIM_DIR}" --tx-token "${SIM_TOK}" >/dev/null
assert_eq "$?" "0" "Deliberate authorized --recover succeeds cleanly from TX_RECOVERY_REQUIRED"
assert_eq "$(sha256sum "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" | cut -d ' ' -f 1)" "${GOOD_PRI_SHA}" "Restored canonical ART_1 verified equal to baseline SHA"
assert_eq "$(sha256sum "${PKG_OUT}/2.0.0.tar.gz" | cut -d ' ' -f 1)" "${GOOD_CMP_SHA}" "Restored canonical ART_3 verified equal to baseline SHA"
[ ! -e "${SIM_DIR}" ]
assert_eq "$?" "0" "Packaging TX directory cleanly retired and deleted after verified recovery"

echo "=== 6. Retired Cleanup Interruption, Missing Metadata & Unexpected Files ==="
R_TX="20261127T211500Z-7777-abcdef0123456789"
R_TOK="20261127T211500Z-abcdef0123456789abcdef0123456789"
R_BAD_TOK="20261127T211500Z-11111111111111111111111111111111"
R_TAG="$(compute_auth_tag "1.0.0" "${R_TX}" "${R_TOK}")"
R_DIR="${REMOTE_STAGING}/.tx-retired-1.0.0-${R_TX}-${R_TAG}"

# 6a. Interruption during TX_FINALIZING_PRUNING_AUX with missing token -> MUST FAIL CLOSED
mkdir -p "${R_DIR}"
write_bound_state_atomic "${R_DIR}/tx_phase" "${R_TX}" "PHASE" "TX_FINALIZING_PRUNING_AUX" "${R_DIR}"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Retired PRUNING_AUX with unexpectedly missing token rejected"

# 6b. Put valid token + unexpected rogue file inside RETIRED_DIR -> MUST FAIL CLOSED without removing tx_phase
write_state_atomic "${R_DIR}/token" "${R_TOK}" "${R_DIR}"
printf 'rogue' > "${R_DIR}/unexpected_file"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Unexpected file inside RETIRED_DIR halts cleanup without deleting tx_phase"
[ -f "${R_DIR}/tx_phase" ]
assert_eq "$?" "0" "tx_phase preserved when unexpected file blocked cleanup"
rm -f "${R_DIR}/unexpected_file"

# 6c. Simulate interruption AFTER token deletion (TX_FINALIZING_PRUNING_TOKEN)
rm -f "${R_DIR}/token"
write_bound_state_atomic "${R_DIR}/tx_phase" "${R_TX}" "PHASE" "TX_FINALIZING_PRUNING_TOKEN" "${R_DIR}"

# Wrong token MUST STILL BE REJECTED even when token file was already deleted!
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_BAD_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Unauthorized retired recovery rejected after token deletion via AUTH_TAG binding"
[ -f "${R_DIR}/tx_phase" ]
assert_eq "$?" "0" "tx_phase preserved after unauthorized attempt"

# Valid token resumes cleanly and removes RETIRED_DIR
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_TOK}" -r "${REMOTE_STAGING}" >/dev/null
assert_eq "$?" "0" "Authorized retired recovery completes after token deletion"
[ ! -e "${R_DIR}" ]
assert_eq "$?" "0" "RETIRED_DIR cleanly removed"

# 6d. Interruption strictly after deleting tx_phase (empty RETIRED_DIR): wrong token STILL blocked, valid token finishes rmdir
mkdir -p "${R_DIR}"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_BAD_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Empty RETIRED_DIR still rejects wrong --tx-token via AUTH_TAG"
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${R_TOK}" -r "${REMOTE_STAGING}" >/dev/null
assert_eq "$?" "0" "Empty RETIRED_DIR cleanly finalized with valid --tx-token"
[ ! -e "${R_DIR}" ]
assert_eq "$?" "0" "Empty RETIRED_DIR unlinked and synced"

echo "=== 7. Staging Fault Injection, Broken CLI Args, write_state_atomic Code 1/2 & Pruning Drift ==="
# Prepare new candidate version 1.0.0 locally to test overwrite faults preserving ARCHIVE_SHA
LOCAL_NEW="${SANDBOX}/local_new"
mkdir -p "${LOCAL_NEW}"
tar -czf "${LOCAL_NEW}/1.0.0.tar.gz" -C "${SANDBOX}/payload_new" .
(cd "${LOCAL_NEW}" && sha256sum "1.0.0.tar.gz" > "1.0.0.tar.gz.sha256")

for fault_hook in MOCK_FAIL_AFTER_BACKUP MOCK_FAIL_AFTER_ARCH_PROMOTE MOCK_FAIL_AFTER_SIDE_PROMOTE; do
    rc=0
    env "${fault_hook}=1" "${STG_SCRIPT}" -v 1.0.0 -d "${LOCAL_NEW}" -r "${REMOTE_STAGING}" --overwrite >/dev/null 2>&1 || rc=$?
    assert_nonzero "${rc}" "Staging failure injection (${fault_hook}) returns nonzero cleanly"
    assert_eq "$(sha256sum "${REMOTE_STAGING}/1.0.0.tar.gz" | cut -d ' ' -f 1)" "${ARCHIVE_SHA}" "After ${fault_hook}, last known-good archive restored verbatim"
    assert_eq "$(stat -c '%a' "${REMOTE_STAGING}/1.0.0.tar.gz")" "640" "After ${fault_hook}, 0640 mode restored on archive"
    (cd "${REMOTE_STAGING}" && sha256sum -c --strict "1.0.0.tar.gz.sha256" >/dev/null)
    assert_eq "$?" "0" "After ${fault_hook}, last known-good sidecar verifies cleanly"
done

# Broken CLI arguments rejected cleanly
rc=0; "${PKG_SCRIPT}" --recover "${PKG_OUT}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Broken packaging --recover missing args rejected"
rc=0; "${STG_SCRIPT}" --recover -v 1.0.0 --overwrite -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Staging --recover mixed with --overwrite rejected"

# write_state_atomic return code 1 (pre-rename read-only dir) & 2 (post-rename sync dir failed)
ST_TEST_DIR="${SANDBOX}/st_test_dir"
mkdir -p "${ST_TEST_DIR}"
write_state_atomic "${ST_TEST_DIR}/state" "GOOD_OLD" "${ST_TEST_DIR}"
chmod 0555 "${ST_TEST_DIR}"
rc=0; write_state_atomic "${ST_TEST_DIR}/state" "BAD_NEW" "${ST_TEST_DIR}" >/dev/null 2>&1 || rc=$?
chmod 0755 "${ST_TEST_DIR}"
assert_eq "${rc}" "1" "write_state_atomic pre-rename failure returns 1"
assert_eq "$(cat "${ST_TEST_DIR}/state")" "GOOD_OLD" "Pre-rename failure preserves previous valid state intact"

# Simulate post-rename parent sync failure returning exit code 2 via shadowed sync function
sync() {
    if [ "${1:-}" = "${ST_TEST_DIR}" ]; then
        return 1
    fi
    command sync "$@"
}
rc=0; write_state_atomic "${ST_TEST_DIR}/state" "RENAMED_UNSYNCED" "${ST_TEST_DIR}" >/dev/null 2>&1 || rc=$?
unset -f sync
assert_eq "${rc}" "2" "write_state_atomic post-rename sync failure returns distinct code 2"
assert_eq "$(cat "${ST_TEST_DIR}/state")" "RENAMED_UNSYNCED" "Code 2 leaves renamed state visible rather than falsely pretending rollback"

# TX_PRUNING_AFTER_ROLLBACK interruption resumption & canonical drift protection
PR_TX="20261127T211500Z-8888-1122334455667788"
PR_TOK="20261127T211500Z-11223344556677881122334455667788"
PR_DIR="${PKG_OUT}/.pkg-tx-2.0.0-${PR_TX}"
mkdir -p "${PR_DIR}/backup" "${PR_DIR}/stage"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=2.0.0\nSESSION_TOKEN=%s\n' "${PR_TX}" "${PR_TOK}" > "${PR_DIR}/manifest.env"
printf 'ART_1_NAME=git-repo-analyzer-release-2.0.0.tar.gz\nART_1_BASELINE_EXISTS=1\nART_1_BASELINE_SHA=%s\nART_1_STAGE_SHA=%s\n' "${B1}" "${STG_NEW_SHA}" >> "${PR_DIR}/manifest.env"
printf 'ART_2_NAME=git-repo-analyzer-release-2.0.0.tar.gz.sha256\nART_2_BASELINE_EXISTS=1\nART_2_BASELINE_SHA=%s\nART_2_STAGE_SHA=%s\n' "${B2}" "${STG_NEW_SHA}" >> "${PR_DIR}/manifest.env"
printf 'ART_3_NAME=2.0.0.tar.gz\nART_3_BASELINE_EXISTS=1\nART_3_BASELINE_SHA=%s\nART_3_STAGE_SHA=%s\n' "${B3}" "${STG_NEW_SHA}" >> "${PR_DIR}/manifest.env"
printf 'ART_4_NAME=2.0.0.tar.gz.sha256\nART_4_BASELINE_EXISTS=1\nART_4_BASELINE_SHA=%s\nART_4_STAGE_SHA=%s\n' "${B4}" "${STG_NEW_SHA}" >> "${PR_DIR}/manifest.env"
write_state_atomic "${PR_DIR}/token" "${PR_TOK}" "${PR_DIR}"
write_state_atomic "${PR_DIR}/tx_id" "${PR_TX}" "${PR_DIR}"
write_bound_state_atomic "${PR_DIR}/tx_phase" "${PR_TX}" "PHASE" "TX_PRUNING_AFTER_ROLLBACK" "${PR_DIR}"
# Backups 1..3 already intentionally pruned; only backup 4 left; test canonical drift FIRST
cp -p "${PKG_OUT}/2.0.0.tar.gz.sha256" "${PR_DIR}/backup/"
mv "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" "${SANDBOX}/drift_saved_1"
printf 'drifted' > "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz"
rc=0
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${PR_DIR}" --tx-token "${PR_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Canonical drift during TX_PRUNING_AFTER_ROLLBACK halts cleanly into TX_RECOVERY_REQUIRED"
[ -f "${PR_DIR}/backup/2.0.0.tar.gz.sha256" ]
assert_eq "$?" "0" "Canonical drift preserved remaining backup 4 without deleting it"

# Now restore baseline canonical 1 and transition back to TX_PRUNING_AFTER_ROLLBACK; recovery resumes with missing backups 1..3!
mv "${SANDBOX}/drift_saved_1" "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz"
write_bound_state_atomic "${PR_DIR}/tx_phase" "${PR_TX}" "PHASE" "TX_PRUNING_AFTER_ROLLBACK" "${PR_DIR}"
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${PR_DIR}" --tx-token "${PR_TOK}" >/dev/null
assert_eq "$?" "0" "Interrupted TX_PRUNING_AFTER_ROLLBACK resumes cleanly without backups 1..3 when canonical matches baseline"
[ ! -e "${PR_DIR}" ]
assert_eq "$?" "0" "TX_PRUNING_AFTER_ROLLBACK completed cleanly"

echo "=== 8. Additional v6.7 Closure Checks: Invalid Phase, Staging Recovery Out of RECOVERY_REQUIRED, Pruning Retries & Sibling Preservation ==="
# 8a. Reject unknown/invalid phase token cleanly
INV_TX="20261127T211500Z-9999-aabbccddeeff0011"
INV_TOK="20261127T211500Z-aabbccddeeff0011aabbccddeeff0011"
INV_DIR="${PKG_OUT}/.pkg-tx-2.0.0-${INV_TX}"
mkdir -p "${INV_DIR}"
write_state_atomic "${INV_DIR}/token" "${INV_TOK}" "${INV_DIR}"
write_state_atomic "${INV_DIR}/tx_id" "${INV_TX}" "${INV_DIR}"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=2.0.0\nSESSION_TOKEN=%s\n' "${INV_TX}" "${INV_TOK}" > "${INV_DIR}/manifest.env"
printf 'ART_1_NAME=git-repo-analyzer-release-2.0.0.tar.gz\nART_1_BASELINE_EXISTS=1\nART_1_BASELINE_SHA=%s\nART_1_STAGE_SHA=%s\n' "${B1}" "${STG_NEW_SHA}" >> "${INV_DIR}/manifest.env"
printf 'ART_2_NAME=git-repo-analyzer-release-2.0.0.tar.gz.sha256\nART_2_BASELINE_EXISTS=1\nART_2_BASELINE_SHA=%s\nART_2_STAGE_SHA=%s\n' "${B2}" "${STG_NEW_SHA}" >> "${INV_DIR}/manifest.env"
printf 'ART_3_NAME=2.0.0.tar.gz\nART_3_BASELINE_EXISTS=1\nART_3_BASELINE_SHA=%s\nART_3_STAGE_SHA=%s\n' "${B3}" "${STG_NEW_SHA}" >> "${INV_DIR}/manifest.env"
printf 'ART_4_NAME=2.0.0.tar.gz.sha256\nART_4_BASELINE_EXISTS=1\nART_4_BASELINE_SHA=%s\nART_4_STAGE_SHA=%s\n' "${B4}" "${STG_NEW_SHA}" >> "${INV_DIR}/manifest.env"
write_bound_state_atomic "${INV_DIR}/tx_phase" "${INV_TX}" "PHASE" "TX_UNKNOWN_CORRUPT_PHASE" "${INV_DIR}"
rc=0
"${PKG_SCRIPT}" --recover "${PKG_OUT}" "${INV_DIR}" --tx-token "${INV_TOK}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Invalid phase token TX_UNKNOWN_CORRUPT_PHASE rejected fail-closed"
read_bound_state_file "${INV_DIR}/tx_phase" "${INV_TX}" "PHASE" "^TX_RECOVERY_REQUIRED$"
assert_eq "$?" "0" "Invalid phase transitioned cleanly to TX_RECOVERY_REQUIRED without clearing evidence"
rm -rf "${INV_DIR}"

# 8b. Staging failure during rollback (corrupt backup -> TX_RECOVERY_REQUIRED), followed by operator fix + deliberate staging --recover
STG_REC_TX="20261127T211500Z-6666-0011223344556677"
STG_REC_TOK="20261127T211500Z-00112233445566770011223344556677"
STG_REC_DIR="${REMOTE_STAGING}/.tx-1.0.0"
STG_NEW_SHA="$(cut -d ' ' -f 1 "${LOCAL_NEW}/1.0.0.tar.gz.sha256")"
STG_OLD_SIDE_SHA="$(sha256sum "${REMOTE_STAGING}/1.0.0.tar.gz.sha256" | cut -d ' ' -f 1)"
STG_NEW_SIDE_SHA="$(sha256sum "${LOCAL_NEW}/1.0.0.tar.gz.sha256" | cut -d ' ' -f 1)"
mkdir -p "${STG_REC_DIR}/backup" "${STG_REC_DIR}/stage"
cp -p "${REMOTE_STAGING}/1.0.0.tar.gz" "${STG_REC_DIR}/backup/1.0.0.tar.gz"
cp -p "${REMOTE_STAGING}/1.0.0.tar.gz.sha256" "${STG_REC_DIR}/backup/1.0.0.tar.gz.sha256"
write_state_atomic "${STG_REC_DIR}/token" "${STG_REC_TOK}" "${STG_REC_DIR}"
write_state_atomic "${STG_REC_DIR}/tx_id" "${STG_REC_TX}" "${STG_REC_DIR}"
printf 'SCHEMA_VERSION=1\nTX_ID=%s\nVERSION=1.0.0\nSESSION_TOKEN=%s\nARCHIVE_NAME=1.0.0.tar.gz\nARCHIVE_BASELINE_EXISTS=1\nARCHIVE_BASELINE_SHA=%s\nARCHIVE_STAGE_SHA=%s\nSIDECAR_NAME=1.0.0.tar.gz.sha256\nSIDECAR_BASELINE_EXISTS=1\nSIDECAR_BASELINE_SHA=%s\nSIDECAR_STAGE_SHA=%s\n' \
    "${STG_REC_TX}" "${STG_REC_TOK}" "${ARCHIVE_SHA}" "${STG_NEW_SHA}" "${STG_OLD_SIDE_SHA}" "${STG_NEW_SIDE_SHA}" > "${STG_REC_DIR}/manifest.env"
write_bound_state_atomic "${STG_REC_DIR}/journal.ARCHIVE" "${STG_REC_TX}" "STATE" "CANONICAL_DIR_SYNCED" "${STG_REC_DIR}"
write_bound_state_atomic "${STG_REC_DIR}/journal.SIDECAR" "${STG_REC_TX}" "STATE" "PROMOTE_INTENT" "${STG_REC_DIR}"
write_bound_state_atomic "${STG_REC_DIR}/tx_phase" "${STG_REC_TX}" "PHASE" "TX_PROMOTING" "${STG_REC_DIR}"

# Replace canonical with partial new and corrupt backup temporarily
cp -p "${LOCAL_NEW}/1.0.0.tar.gz" "${REMOTE_STAGING}/1.0.0.tar.gz"
mv "${STG_REC_DIR}/backup/1.0.0.tar.gz" "${SANDBOX}/stg_saved_bak"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${STG_REC_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Staging recovery with missing backup fails and transitions to TX_RECOVERY_REQUIRED"
read_bound_state_file "${STG_REC_DIR}/tx_phase" "${STG_REC_TX}" "PHASE" "^TX_RECOVERY_REQUIRED$"
assert_eq "$?" "0" "Staging entered TX_RECOVERY_REQUIRED keeping sidecar backup intact"
[ -f "${STG_REC_DIR}/backup/1.0.0.tar.gz.sha256" ]
assert_eq "$?" "0" "Sidecar backup retained inside TX_RECOVERY_REQUIRED"

# Simulate pruning failure (non-writable backup dir during finalize) & retry!
mv "${SANDBOX}/stg_saved_bak" "${STG_REC_DIR}/backup/1.0.0.tar.gz"
chmod 0500 "${STG_REC_DIR}/backup"
rc=0
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${STG_REC_TOK}" -r "${REMOTE_STAGING}" >/dev/null 2>&1 || rc=$?
assert_nonzero "${rc}" "Staging pruning failure (0500 backup dir) propagates nonzero cleanly"
[ -f "${STG_REC_DIR}/tx_phase" ]
assert_eq "$?" "0" "Metadata preserved on pruning failure so retry succeeds"

chmod 0700 "${STG_REC_DIR}/backup"
"${STG_SCRIPT}" --recover -v 1.0.0 --tx-token "${STG_REC_TOK}" -r "${REMOTE_STAGING}" >/dev/null
assert_eq "$?" "0" "Retry of staging --recover after fixing backup permissions completes cleanly"
assert_eq "$(sha256sum "${REMOTE_STAGING}/1.0.0.tar.gz" | cut -d ' ' -f 1)" "${ARCHIVE_SHA}" "Remote 1.0.0.tar.gz restored bit-for-bit after recovery retry"
[ ! -e "${STG_REC_DIR}" ]
assert_eq "$?" "0" "Staging TX_DIR cleanly retired and removed"

# 8c. Sibling release retention sanity check (operating on 2.0.0 preserves unrelated 1.0.0 / vice versa)
"${PKG_SCRIPT}" --package "${PKG_OUT}" "2.1.0" "${SANDBOX}/payload_src" >/dev/null
[ -f "${PKG_OUT}/git-repo-analyzer-release-2.0.0.tar.gz" ] && [ -f "${PKG_OUT}/git-repo-analyzer-release-2.1.0.tar.gz" ]
assert_eq "$?" "0" "Unrelated packaged version artifacts preserved intact across versioned packaging runs"

echo "========================================="
echo "RESULTS: PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
