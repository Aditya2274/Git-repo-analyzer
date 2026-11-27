# Automated Application Release Staging Guide

This document describes the automated application release-transfer and transactional staging mechanism for the **Git Repository Analyzer** platform, implemented in [`scripts/stage_release.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/stage_release.sh) and powered by the v6.7 transactional staging engine ([`scripts/release-v67/staging_tx.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/release-v67/staging_tx.sh) and [`scripts/release-v67/design_common.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/release-v67/design_common.sh)).

---

## 1. Overview and Architecture Context

The release staging workflow transfers a locally packaged, checksum-verified release archive (`<VERSION>.tar.gz`) to the unprivileged landing directory (`/var/cache/git-repo-analyzer/staging`) on `app-server` (EC2 2) and writes a verified `<VERSION>.tar.gz.sha256` sidecar alongside it for consumption by Puppet's release management subsystem ([`puppet/modules/application/files/release_manager.py`](file:///home/aditya-2274/Git-repo-analyzer/puppet/modules/application/files/release_manager.py)).

Instead of SCP file transfers and plaintext shell interpolation, the v6.7 engine transfers archives exclusively over **SSH standard input (`stdin`)**, executes an encoded and SHA-256–verified `/usr/bin/python3` remote bootstrap, holds an exclusive per-version kernel `flock` lock on the remote host, and promotes canonical artifacts under bound transaction manifests and journals.

```text
 [ Operator / CI Environment ]                         [ app-server (EC2 2) ]
 ┌─────────────────────────────────┐                  ┌──────────────────────────────────────────┐
 │ dist-release/                   │                  │ /var/cache/git-repo-analyzer/staging/    │
 │  ├── <VERSION>.tar.gz           │                  │  ├── .gra-tx-<VERSION>.flock (locked fd9)│
 │  └── <VERSION>.tar.gz.sha256    │  SSH stdin pipe  │  ├── .tx-<VERSION>/ (0700 stage/backup/  │
 │        │                        │ + Base64+SHA256  │  │     token, tx_id, tx_phase, journals)  │
 │  Local sha256sum -c --strict    ├─────────────────►│  ├── <VERSION>.tar.gz           (0640)   │
 └─────────────────────────────────┘  encoded Python  │  └── <VERSION>.tar.gz.sha256    (0640)   │
                                      bootstrap (no   └────────────────────┬─────────────────────┘
                                      SCP)                                 │
                                                                 Puppet Release Manager
                                                               (prepare / activate / health)
```

### End-to-End Staging Flow

1. **Local archive validation** (`scripts/stage_release.sh`): validates CLI options, `<VERSION>`, SSH config/key existence, local archive & sidecar regular-file status (`! -L`, non-empty), and runs `sha256sum -c --strict "${VERSION}.tar.gz.sha256"`.
2. **SSH stdin streaming & encoded payload serialization** (`scripts/release-v67/staging_tx.sh`): builds hardened `SSH_EXEC_OPTS`, encodes the remote script body (`script_b64` + `expected_script_sha`) and JSON-serialized arguments (`args_b64` + `expected_args_sha`), and streams `<VERSION>.tar.gz` over SSH `stdin`.
3. **Encoded remote bootstrap verification & locking** (remote `/usr/bin/python3`): validates Base64 (`validate=True`), verifies SHA-256 digests for script and arguments, rejects NUL bytes, validates direct `STAGING_DIR` ownership/permissions (`O_DIRECTORY | O_NOFOLLOW`, `st_uid == euid`, `(st_mode & 0o022) == 0`), opens `.gra-tx-<VERSION>.flock` safely (`O_NOFOLLOW`, `st_nlink == 1`), acquires non-blocking `LOCK_EX | LOCK_NB` on `fd 9`, and `os.execv`s `/bin/bash -c` directly with decoded positional arguments.
4. **Remote byte-count verification**: reads exact `EXP_BYTES` (`head -c "${EXP_BYTES}"`), rejects truncated streams (`GOT_BYTES != EXP_BYTES`) and trailing bytes (`head -c 1 | wc -c != 0`).
5. **SHA-256 verification**: computes uploaded `sha256sum`, compares against `EXP_SHA`, creates canonical `.sha256` sidecar in `stage/`, applies `0640`, and flushes files/directory (`sync`).
6. **Transactional promotion & validation**: atomically writes bound `manifest.env` (`SCHEMA_VERSION=1`, 12 validated fields) and per-artifact journals (`journal.ARCHIVE`, `journal.SIDECAR`), backs up existing canonical targets when `--overwrite` is enabled, advances `tx_phase` through `TX_INITIALIZED` → `TX_BACKUPS_READY` → `TX_PROMOTING`, atomically promotes files via `mv -f -T`, enforces `0640`, and runs post-promotion `sha256sum -c --strict`.
7. **Commit & retired finalization**: writes two-phase commit point `TX_COMMITTED`, prunes `backup/` and `stage/`, renames `.tx-<VERSION>` to `.tx-retired-<VERSION>-<TX_ID>-<AUTH_TAG>`, removes retired metadata files in phase-tracked order (`TX_FINALIZING_CLEANUP_INIT` → `TX_FINALIZING_PRUNING_AUX` → `TX_FINALIZING_PRUNING_TOKEN`), unlinks/syncs the directory, releases `fd 9`, and prints `RESULT_TOKEN=STAGE_COMMITTED`.

---

## 2. CLI Interface and Syntax

### Syntax

```bash
# Stage a new release
scripts/stage_release.sh [OPTIONS] <VERSION>
scripts/stage_release.sh -v <VERSION> [OPTIONS]

# Recover an interrupted transaction explicitly
scripts/stage_release.sh --recover --version <VERSION> --tx-token <TOKEN> [SSH OPTIONS]

# Help
scripts/stage_release.sh --help
```

### Command-Line Arguments

| Option | Argument | Description | Default |
| :--- | :--- | :--- | :--- |
| `-v, --version` | `<VERSION>` | Release version identifier matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` without `..` | *Required* |
| `-d, --archive-dir` | `<DIR>` | Local directory containing `<VERSION>.tar.gz` and `<VERSION>.tar.gz.sha256` (cannot be combined with `--recover`) | `<PROJECT_ROOT>/dist-release` or `$STAGE_ARCHIVE_DIR` |
| `-H, --host` | `<HOST>` | Remote SSH host or hostname alias | `app-server` or `$STAGE_SSH_HOST` |
| `-u, --user` | `<USER>` | Remote SSH username on target host | `ubuntu` or `$STAGE_SSH_USER` |
| `-p, --port` | `<PORT>` | Remote SSH port (`1`–`65535`) | `22` or `$STAGE_SSH_PORT` |
| `-i, --identity` | `<FILE>` | SSH private key identity file | `$STAGE_SSH_KEY` or auto-detected `~/.ssh/git-repo-analyzer.pem` (if present) |
| `-F, --ssh-config` | `<FILE>` | Custom SSH client configuration file | `$STAGE_SSH_CONFIG` or `<PROJECT_ROOT>/ssh.cfg` / `ansible/ssh.cfg` (if present) |
| `-r, --remote-dir` | `<DIR>` | Canonical remote staging directory on EC2 2 (`^/[A-Za-z0-9._/-]+$`, no `.` or `..`) | `/var/cache/git-repo-analyzer/staging` or `$STAGE_REMOTE_DIR` |
| `--overwrite` | *None* | Permit transactional replacement of an existing staged release with backup/rollback protection (invalid with `--recover`) | `false` (fails closed with `RESULT_TOKEN=EXISTS_REFUSED`) |
| `--recover` | *None* | Enter explicit remote recovery mode for an interrupted or `TX_RECOVERY_REQUIRED` transaction | `false` |
| `--tx-token` | `<TOKEN>` | Transaction session bearer token (`^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$`), required with `--recover` and forbidden without `--recover` | *None* |
| `-h, --help` | *None* | Display command usage and exit | |

---

## 3. Environment Variables

| Environment Variable | Equivalent Flag | Description |
| :--- | :--- | :--- |
| `STAGE_ARCHIVE_DIR` | `-d, --archive-dir` | Path to local directory containing `<VERSION>.tar.gz` and `<VERSION>.tar.gz.sha256` |
| `STAGE_SSH_HOST` | `-H, --host` | Target SSH hostname or IP address |
| `STAGE_SSH_USER` | `-u, --user` | Target SSH login user |
| `STAGE_SSH_PORT` | `-p, --port` | Target SSH TCP port |
| `STAGE_SSH_KEY` | `-i, --identity` | Path to SSH private key file |
| `STAGE_SSH_CONFIG` | `-F, --ssh-config` | Path to SSH client configuration file |
| `STAGE_REMOTE_DIR` | `-r, --remote-dir` | Canonical target staging directory on the remote server |

---

## 4. SSH Transport, Locking, and Security Controls

1. **Host-Key Verification & Public-Key Auth**:
   - `staging_tx.sh` always passes `-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3`.
   - `ssh.cfg` enforces project-scoped `UserKnownHostsFile` and `IdentitiesOnly yes`.
2. **Quoting-Safe Encoded Bootstrap**:
   - No untrusted arguments are concatenated or interpolated across OpenSSH remote shell (`$SHELL -c`) parsing.
   - Remote Python verifies `script_b64` and `args_b64` SHA-256 digests (`exit 71` / `RESULT_TOKEN=SCRIPT_DELIVERY_FAILED` on tamper/corruption), rejects NUL bytes, and invokes `os.execv("/bin/bash", ...)`.
3. **Directory Trust & Symlink/Hardlink Rejection**:
   - Both local pre-checks (`stage_release.sh`) and remote staging fail closed on symbolic links.
   - Remote bootstrap rejects non-existent/symlink staging directories (`DIR_INVALID`, `exit 72`) and directories not owned by `euid` or writable by group/others (`(st_mode & 0o022) != 0` → `DIR_UNTRUSTED`, `exit 72`).
   - Lock anchor `.gra-tx-<VERSION>.flock` is opened with `O_CREAT | O_RDWR | O_NOFOLLOW` (rejecting symlinks → `exit 73`) and requires `S_ISREG`, `st_nlink == 1`, `st_uid == euid` (rejecting hardlinks → `exit 74`), plus post-`flock` `lstat` vs `fstat` inode/device identity verification (`exit 76`).
4. **Per-Version Transaction Locking**:
   - Non-blocking `flock(LOCK_EX | LOCK_NB)` on `.gra-tx-<VERSION>.flock` (held on `fd 9`) serializes uploads and recovery operations per version. Competing upload or `--recover` attempts exit immediately with `75` (`RESULT_TOKEN=MUTEX_BUSY`).
5. **Pre-Flight Ownership Isolation**:
   - While pre-flight guards check for an existing active transaction (`.tx-<VERSION>` → `LOCKED_OR_RECOVERY_REQUIRED`), pending retired cleanup (`.tx-retired-<VERSION>-*` → `RETIRED_CLEANUP_PENDING`), or existing canonical files without `--overwrite` (`EXISTS_REFUSED`), `OWNS_TX_DIR=0` prevents the `EXIT` trap from mutating a prior transaction's `tx_phase` or metadata.

---

## 5. Transaction Manifest, Journaling, Rollback, and Recovery

### 5.1 Bound State Files & Manifest Validation

Each staging transaction generates a collision-resistant `SESSION_TOKEN` (`<UTC_TS>-<32-hex>` via `/dev/urandom`) and `TX_ID` (`<UTC_TS>-<PID>-<16-hex>` via `/dev/urandom`), and records:

- `.tx-<VERSION>/token` & `.tx-<VERSION>/tx_id`
- `.tx-<VERSION>/tx_phase` — 2-line `TX_ID`-bound state file (`TX_ID=<tx_id>\nPHASE=<state>\n`), updated via `mktemp` → newline & readback checks → `sync <tmp>` → `mv -f -T` → `sync <parent_dir>` (returning distinct exit code `2` if post-rename directory `sync` fails).
- `.tx-<VERSION>/manifest.env` — 12-field key/value manifest (`SCHEMA_VERSION=1`, `TX_ID`, `VERSION`, `SESSION_TOKEN`, plus `ARCHIVE_*` and `SIDECAR_*` baseline/stage metadata), validated strictly in pure bash without `eval` or `source`.
- `.tx-<VERSION>/journal.ARCHIVE` and `.tx-<VERSION>/journal.SIDECAR` — `TX_ID`-bound per-artifact progress journals tracking:
  - `BASELINE_INSPECTED` → `BACKUP_INTENT` → `BACKUP_CREATED` → `BACKUP_DATA_SYNCED` → `BACKUP_DIR_SYNCED`
  - `PROMOTE_INTENT` → `CANONICAL_REPLACED` → `CANONICAL_DIR_SYNCED` → `PROMOTED_VERIFIED`

### 5.2 Overwrite Behavior (`--overwrite`) & Automatic Rollback

- Without `--overwrite`, existing `<VERSION>.tar.gz` or `<VERSION>.tar.gz.sha256` causes fail-closed abort (`RESULT_TOKEN=EXISTS_REFUSED`).
- With `--overwrite`, existing canonical files (`BASELINE_EXISTS=1`) are copied via `cp -p` into `.tx-<VERSION>/backup/`, data-synced, and SHA-256 verified against `BASELINE_SHA` before `TX_PROMOTING` begins.
- If stream upload aborts before manifest commit (`TX_UPLOAD_IN_PROGRESS`), `remote_exit_trap` cleans `.tx-<VERSION>/stage` cleanly without touching existing canonical files.
- If a failure or signal occurs during `TX_INITIALIZED`, `TX_BACKUPS_READY`, `TX_PROMOTING`, or `TX_VALIDATED`, `remote_exit_trap` validates `manifest.env` & journals and runs non-destructive restoration (`restore_artifact_nondestructive`), restoring backups via temp file + `0640` + `sync` + `mv -f -T` (or removing newly staged `BASELINE_EXISTS=0` files verified against `STAGE_SHA`). Canonical baseline verification must succeed (`TX_ROLLED_BACK_VERIFIED`) before `backup/` entries are ever unlinked.

### 5.3 `TX_RECOVERY_REQUIRED` and Explicit Recovery (`--recover --tx-token`)

If manifest/journal validation fails, an unrecognized phase is encountered, a required backup is missing or checksum-mismatched, or post-rollback verification fails, the engine persists `TX_RECOVERY_REQUIRED` in `tx_phase` and preserves all remaining backup files and transaction artifacts on disk. Subsequent uploads for that version fail closed (`LOCKED_OR_RECOVERY_REQUIRED`) until an operator explicitly runs recovery:

```bash
scripts/stage_release.sh \
  --recover \
  --version <VERSION> \
  --tx-token <SESSION_TOKEN> \
  -H <HOST> -u <USER> -r /var/cache/git-repo-analyzer/staging
```

Under lock, `--recover` requires exact `TX_ID` binding, valid `manifest.env` (unless resuming `TX_UPLOAD_IN_PROGRESS` or a `.tx-retired-*` directory), and bearer `--tx-token` authorization:
- Active `.tx-<VERSION>` in `TX_UPLOAD_IN_PROGRESS` completes upload abort cleanup (`RESULT_TOKEN=RECOVERED_UPLOAD_ABORT`).
- Active `.tx-<VERSION>` in `TX_COMMITTED`, `TX_PRUNING_AFTER_COMMIT`, or `TX_FINALIZING_CLEANUP_INIT` finishes commit cleanup (`RESULT_TOKEN=RECOVERED_SUCCESS`).
- Active `.tx-<VERSION>` in pre-commit, promotion, rollback, or `TX_RECOVERY_REQUIRED` reconciles canonical files from `backup/`, verifies baseline state, and retires `.tx-<VERSION>` (`RESULT_TOKEN=RECOVERED_SUCCESS`).
- Retired `.tx-retired-<VERSION>-<TX_ID>-<AUTH_TAG>` directories authorize `--tx-token` against the 32-hex cryptographic `AUTH_TAG` (`SHA-256(version:tx_id:token)[:32]`) embedded in the directory name — rejecting rogue unexpected files without deleting `tx_phase` and rejecting wrong tokens even after `token` has been unlinked during `TX_FINALIZING_PRUNING_TOKEN` (`RESULT_TOKEN=RECOVERED_RETIRED_SUCCESS`).

---

## 6. Remote Staging Layout and Puppet Handover

Upon `RESULT_TOKEN=STAGE_COMMITTED`, `/var/cache/git-repo-analyzer/staging/` contains:

```text
/var/cache/git-repo-analyzer/staging/
├── .gra-tx-<VERSION>.flock     # Persistent per-version regular flock anchor
├── <VERSION>.tar.gz            # -rw-r----- (0640) ubuntu:ubuntu regular file
└── <VERSION>.tar.gz.sha256     # -rw-r----- (0640) ubuntu:ubuntu regular file
```

### Compatibility with Puppet (`application::release` & `release_manager.py`)

- Staging path and ownership match `$staging_dir = '/var/cache/git-repo-analyzer/staging'`, `owner = 'ubuntu'`, `group = 'ubuntu'`, and `mode = '0750'` in [`puppet/modules/application/manifests/release.pp`](file:///home/aditya-2274/Git-repo-analyzer/puppet/modules/application/manifests/release.pp).
- `release_manager.py` inspects strictly `<VERSION>.tar.gz` and `<VERSION>.tar.gz.sha256` (`os.path.islink(path) == False`), ignoring persistent `.gra-tx-<VERSION>.flock` anchors.

### Puppet Hiera Configuration Contract

`scripts/stage_release.sh` outputs concise transactional status lines (`Starting transactional staging...`, `Target: ...`, `RESULT_TOKEN=STAGE_COMMITTED`) rather than printing Hiera YAML instructions on stdout. When deploying a staged release via Puppet, operators set top-level `class application` Hiera parameters (e.g., in `puppet/hieradata/common.yaml` or node YAML) using the digest from `<VERSION>.tar.gz.sha256`:

```yaml
# Authoritative Hiera parameters for Puppet application deployment
application::release_version: '<VERSION>'
application::expected_sha256: '<SHA256_DIGEST>'
```

> [!WARNING]
> **Strict Namespace Policy**: Do **not** configure parameters under `application::release::*` in Hiera. `class application` (`puppet/modules/application/manifests/init.pp`) binds top-level `application::release_version` and `application::expected_sha256` via Automatic Parameter Lookup and explicitly passes them to `class { 'application::release': ... }`.

---

## 7. Example Invocations

### Standard Invocation (Using Defaults)

```bash
scripts/stage_release.sh 1.0.0
```

### Explicit Target Host, Custom Identity, and Overwrite

```bash
scripts/stage_release.sh \
  --version 1.0.0 \
  --archive-dir ./dist-release \
  --host app-server \
  --user ubuntu \
  --identity ~/.ssh/git-repo-analyzer.pem \
  --ssh-config ./ssh.cfg \
  --remote-dir /var/cache/git-repo-analyzer/staging \
  --overwrite
```

### Recovering an Interrupted Transaction

```bash
scripts/stage_release.sh \
  --recover \
  --version 1.0.0 \
  --tx-token 20261128T010000Z-00112233445566770011223344556677 \
  --host app-server \
  --user ubuntu \
  --remote-dir /var/cache/git-repo-analyzer/staging
```

---

## 8. Test Suite and Validation Scope

The staging test suite is located at [`cicd/tests/test_stage_release.sh`](file:///home/aditya-2274/Git-repo-analyzer/cicd/tests/test_stage_release.sh):

```bash
bash cicd/tests/test_stage_release.sh
```

It executes **22 sandboxed tests** covering:
1. Missing arguments and CLI option/mode mutual-exclusion validation (`--recover`, `--tx-token`, `--overwrite`).
2. Invalid release version strings, path traversal, invalid SSH ports, and invalid remote paths.
3. Missing, empty, and symlinked local archive rejection.
4. Missing, empty, and symlinked local checksum sidecar rejection.
5. Invalid local checksum pre-check fail-closed (verifying mock `ssh` is never invoked).
6. Missing `-F` SSH config or `-i` identity file rejection + forwarding of explicit `-F`, `-i`, `-p`, `-T`, `BatchMode=yes`, `StrictHostKeyChecking=yes`.
7. SSH transport failure propagation (`exit 255`) and bootstrap script/argument digest tampering (`exit 71`).
8. Remote staging directory validation (`0770`, `0757`, missing, symlink, foreign UID → `exit 72`) and lock-anchor symlink (`73`) / hardlink (`74`) rejection.
9. Remote stream byte truncation, trailing garbage bytes, and SHA-256 mismatch abort cleanup (`TX_UPLOAD_IN_PROGRESS`).
10. Successful end-to-end transactional staging (`RESULT_TOKEN=STAGE_COMMITTED`, `0640` regular files, single-link `.flock`, zero `scp` calls).
11. Refusal when release already exists without `--overwrite` (`EXISTS_REFUSED`) and overwrite commit when enabled.
12. Cleanup of temporary `.tx-*` / `.tx-retired-*` / `.tmp*` / `.restore-*` artifacts after failures.
13. Overwrite safety: existing release survives remote stream verification failure.
14. Overwrite safety: existing release survives SSH transport and bootstrap failures.
15. Overwrite safety: corrupted, truncated, and trailing-byte streams rejected before touching existing targets.
16. Promotion rollback across built-in failure hooks (`MOCK_FAIL_AFTER_BACKUP`, `MOCK_FAIL_AFTER_ARCH_PROMOTE`, `MOCK_FAIL_AFTER_SIDE_PROMOTE`), plus clean subsequent retry.
17. Successful `--overwrite` replacing both canonical archive and sidecar with verified `0640` content.
18. Runtime verification of unique `/dev/urandom` `TOKEN` / `TX_ID` generation and multi-version isolation.
19. Puppet parameter (`application::release_version` / `application::expected_sha256`), `release_manager.verify_sidecar_and_checksum` handover, and documentation contract.
20. Transaction locking and concurrent exclusion (`MUTEX_BUSY`, `exit 75`) for both upload and `--recover`.
21. Deliberate `--recover` lifecycle, `LOCKED_OR_RECOVERY_REQUIRED` blocking without overwriting interrupted `TX_ID` bindings, unauthorized token rejection, `TX_RECOVERY_REQUIRED` transition with backup preservation, and full recovery once backups are restored.
22. Tampered journal/phase fail-closed handling and `.tx-retired-*` `AUTH_TAG` / rogue-file recovery resumption.

Engine-level unit and fault-injection checks are additionally provided in [`scripts/release-v67/run_design_tests.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/release-v67/run_design_tests.sh).

### Important Validation Limitations

- `cicd/tests/test_stage_release.sh` executes against a **mocked `ssh` stub** (`eval "${cmd}"`) and a failing `scp` guard stub inside a local `mktemp -d` sandbox.
- Mocked SSH validation is **not equivalent to real OpenSSH or live EC2 deployment validation**: it does not test real `sshd` TCP transport, host-key verification against `ansible/known_hosts`, remote login-shell variations, real network socket termination mid-transfer, or live EC2 Puppet `release_manager.py` extraction and service activation.
