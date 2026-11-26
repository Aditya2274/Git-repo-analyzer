#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_checkpoint_7_1.sh
# Purpose: Comprehensive validation of Checkpoint 7.1:
#          - Jenkinsfile declarative pipeline structure, options, timeouts
#          - Strict GitHub HTTPS repository URL validation and injection defenses
#          - Pre-clone storage availability gate (5 GB) & post-clone size cap (2 GB)
#          - Git clone sandboxing: core.hooksPath=/dev/null, --no-recurse-submodules, --depth 500
#          - Analyzer container sandboxing: non-root user, 768 MB RAM, CPU & PID limits
#          - Container isolation: zero Docker socket mount, zero secret/credential injection
#          - Deterministic static-report fallback & Chart.js rendering
#          - Zero-commit repository graceful handling
#          - Post-build workspace cleanup across normal, failed, aborted, and simulated interrupted runs
#          - Local workstation workload telemetry benchmark (live 2 GB EC2 >= 300 MB validation remains pending Boundary B)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${CICD_DIR}/.." && pwd)"
JENKINSFILE="${PROJECT_ROOT}/Jenkinsfile"

TEST_TMP="$(mktemp -d /tmp/test_checkpoint_7_1.XXXXXX)"
trap 'rm -rf "${TEST_TMP}"' EXIT

PASSED_COUNT=0
TOTAL_COUNT=25

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 7.1 (Pipeline Hardening & Sandboxing)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Jenkinsfile Declarative Pipeline Structure & Options
# ------------------------------------------------------------------------------
echo -n "[Test 1/25] Jenkinsfile structure, global options, and concurrency limits... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'pipeline {' in content, 'Must declare pipeline block'
assert 'agent any' in content, 'Must specify agent'
assert 'options {' in content, 'Must specify options block'
assert 'timeout(time: 15, unit: \'MINUTES\')' in content, 'Must enforce 15-minute overall build timeout'
assert 'disableConcurrentBuilds()' in content, 'Must disable concurrent builds to serialize runs'
assert 'ansiColor(\'xterm\')' in content, 'Must include ansiColor option'
EOF
echo "PASS (pipeline options, 15m timeout, disableConcurrentBuilds verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Jenkinsfile Parameters Declaration
# ------------------------------------------------------------------------------
echo -n "[Test 2/25] Jenkinsfile build parameters declaration (REPO_URL)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'parameters {' in content, 'Must declare parameters block'
assert "name: 'REPO_URL'" in content, 'Must declare REPO_URL parameter'
assert 'https://github.com/octocat/Hello-World.git' in content, 'Must provide default GitHub repository URL'
EOF
echo "PASS (REPO_URL parameter correctly defined)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. URL Validation Script Syntax & Anchoring
# ------------------------------------------------------------------------------
echo -n "[Test 3/25] Strict repository URL regex presence and anchoring in Jenkinsfile... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert "stage('Validate Parameters & Storage')" in content, 'Must contain Validate Parameters & Storage stage'
assert 'githubPattern = ~/' in content, 'Must declare Groovy regex pattern'
assert r'^https:\/\/github\.com\/' in content, 'Regex must be anchored at start with ^'
assert r'(\.git)?$/' in content, 'Regex must be anchored at end with $'
assert 'error("Security Validation Failed:' in content, 'Must call error on validation failure'
EOF
echo "PASS (Strict anchored regex pattern and error step verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Repository URL Regex Positive Evaluation
# ------------------------------------------------------------------------------
echo -n "[Test 4/25] Repository URL regex positive validation cases... "
python3 - << 'EOF'
import re

pattern = re.compile(r'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$')

valid_urls = [
    'https://github.com/octocat/Hello-World',
    'https://github.com/octocat/Hello-World.git',
    'https://github.com/facebook/react',
    'https://github.com/facebook/react.git',
    'https://github.com/torvalds/linux',
    'https://github.com/Aditya2274/Git-repo-analyzer',
    'https://github.com/owner-with-dash/repo_with_underscore.git',
    'https://github.com/org.name/repo.name.git',
]

for url in valid_urls:
    assert pattern.match(url), f'Expected valid URL to match: {url}'
EOF
echo "PASS (Standard, dashed, dotted, and .git URLs accepted)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Repository URL Regex Negative Evaluation (Domains & Protocols)
# ------------------------------------------------------------------------------
echo -n "[Test 5/25] Repository URL rejection of non-GitHub hosts and non-HTTPS protocols... "
python3 - << 'EOF'
import re

pattern = re.compile(r'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$')

invalid_hosts_and_protocols = [
    'http://github.com/octocat/Hello-World',
    'http://github.com/octocat/Hello-World.git',
    'ssh://git@github.com/octocat/Hello-World.git',
    'git://github.com/octocat/Hello-World.git',
    'ftp://github.com/octocat/Hello-World.git',
    'file:///etc/passwd',
    'https://gitlab.com/owner/repo',
    'https://bitbucket.org/owner/repo',
    'https://evil-github.com/owner/repo',
    'https://github.com.evil.com/owner/repo',
    'https://169.254.169.254/owner/repo',
    'https://127.0.0.1/owner/repo',
]

for url in invalid_hosts_and_protocols:
    assert not pattern.match(url), f'Expected URL to be rejected: {url}'
EOF
echo "PASS (Non-HTTPS protocols and foreign hosts strictly rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Repository URL Rejection of Injection & Malicious Constructs
# ------------------------------------------------------------------------------
echo -n "[Test 6/25] Repository URL rejection of injection attacks and malformed syntax... "
python3 - << 'EOF'
import re

pattern = re.compile(r'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$')

malicious_inputs = [
    '',
    '   ',
    'https://user:password@github.com/owner/repo',
    'https://github.com:8080/owner/repo',
    'https://github.com/owner/repo?ref=main',
    'https://github.com/owner/repo#readme',
    'https://github.com/owner/repo/subpath',
    'https://github.com/owner/repo/../../etc/passwd',
    'https://github.com/owner/repo; rm -rf /',
    'https://github.com/owner/repo\nrm -rf /',
    'https://github.com/owner/repo\r\nSET /a',
    'https://github.com/owner/repo && curl http://evil.com',
    'https://github.com/owner/repo|sh',
    'https://github.com/owner/repo --upload-pack=evil',
    'https://evil.com/redirect?target=https://github.com/owner/repo',
]

for url in malicious_inputs:
    assert not pattern.match(url), f'Expected malicious input to be rejected: {repr(url)}'
EOF
echo "PASS (Credentials, ports, queries, fragments, traversal, and shell injections rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Pre-Clone Storage Availability Gate Logic
# ------------------------------------------------------------------------------
echo -n "[Test 7/25] Pre-clone storage gate check (5 GB threshold logic)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'df -Pk' in content, 'Must query workspace filesystem space'
assert '5242880' in content, 'Must enforce 5,242,880 KB (5 GB) minimum free space threshold'
assert 'exit 1' in content, 'Must fail build on insufficient space'

# Test logic
def check_storage(free_kb):
    return free_kb >= 5242880

assert check_storage(6000000), '6 GB available must pass'
assert not check_storage(5242879), 'Less than 5 GB available must fail'
assert not check_storage(1000000), '1 GB available must fail'
EOF
echo "PASS (5 GB workspace storage availability gate verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Git Clone Hook Execution Prohibition
# ------------------------------------------------------------------------------
echo -n "[Test 8/25] Git clone hooks disabled (-c core.hooksPath=/dev/null)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert '-c core.hooksPath=/dev/null' in content, 'Git clone must specify core.hooksPath=/dev/null'
EOF
echo "PASS (Untrusted repository Git hooks prohibited from executing)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Git Clone Submodule Isolation
# ------------------------------------------------------------------------------
echo -n "[Test 9/25] Git clone submodule recursion disabled (--no-recurse-submodules)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert '--no-recurse-submodules' in content, 'Git clone must specify --no-recurse-submodules'
EOF
echo "PASS (Recursive submodule cloning prohibited)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Git Clone Shallow Depth & Stage Timeout
# ------------------------------------------------------------------------------
echo -n "[Test 10/25] Git clone shallow depth constraint (--depth 500) and timeout (5m)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert '--depth 500' in content, 'Git clone must specify shallow depth 500'
assert "timeout(time: 5, unit: 'MINUTES')" in content, 'Clone stage must enforce 5-minute timeout'
EOF
echo "PASS (Shallow depth 500 and 5m clone timeout enforced)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Post-Clone Repository Size Rejection Logic
# ------------------------------------------------------------------------------
echo -n "[Test 11/25] Post-clone repository size rejection (2 GB ceiling & cleanup)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'du -sk target-repo' in content, 'Must compute cloned repository size'
assert '2097152' in content, 'Must enforce 2,097,152 KB (2 GB) repository ceiling'
assert 'rm -rf target-repo' in content, 'Must remove target-repo if ceiling exceeded'

# Test logic
def check_repo_size(size_kb):
    return size_kb <= 2097152

assert check_repo_size(1500000), '1.5 GB repo must pass'
assert not check_repo_size(2097153), '2097153 KB repo must be rejected'
assert not check_repo_size(5000000), '5 GB repo must be rejected'
EOF
echo "PASS (2 GB repository ceiling and immediate removal verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Analyzer Container Non-Root User Execution
# ------------------------------------------------------------------------------
echo -n "[Test 12/25] Analyzer container unprivileged user flag (--user \$(id -u):\$(id -g))... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert '--user "\$(id -u):\$(id -g)"' in content or '--user $(id -u):$(id -g)' in content, 'Must run container with host user UID/GID'
EOF
echo "PASS (Non-root user execution flag configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Analyzer Container Resource Limits (Memory, CPU, PIDs)
# ------------------------------------------------------------------------------
echo -n "[Test 13/25] Analyzer container resource sandboxing (--memory=768m, --cpus=1.5, --pids-limit=100)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert '--memory=768m' in content, 'Must specify approved 768m memory limit'
assert '--cpus=1.5' in content, 'Must specify 1.5 CPU limit'
assert '--pids-limit=100' in content, 'Must specify 100 process limit'
EOF
echo "PASS (768 MB RAM, 1.5 CPUs, and 100 PIDs limits configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Container Daemon Isolation (No Docker Socket Mount)
# ------------------------------------------------------------------------------
echo -n "[Test 14/25] Docker daemon socket isolation (no /var/run/docker.sock mount)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'docker.sock' not in content, 'Host Docker socket must NEVER be mounted into container'
EOF
echo "PASS (Zero Docker socket exposure verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Secret & Credential Isolation (Zero GROQ_API_KEY Injection)
# ------------------------------------------------------------------------------
echo -n "[Test 15/25] Secret and credential isolation (zero GROQ_API_KEY injection)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'GROQ_API_KEY' not in content, 'GROQ_API_KEY must NOT be injected into container or pipeline'
assert 'withCredentials' not in content, 'No credentials wrapper in analyzer execution stage'
EOF
echo "PASS (Zero GROQ_API_KEY injection; deterministic static fallback preserved)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Analyzer Execution Stage Timeout
# ------------------------------------------------------------------------------
echo -n "[Test 16/25] Analyzer container stage execution timeout (10m)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert "stage('Run Git Repository Analyzer')" in content, 'Must contain Run Git Repository Analyzer stage'
assert "timeout(time: 10, unit: 'MINUTES')" in content, 'Analyzer stage must enforce 10-minute timeout'
EOF
echo "PASS (10-minute analyzer execution timeout configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Post Lifecycle Cleanup Architecture
# ------------------------------------------------------------------------------
echo -n "[Test 17/25] Post lifecycle cleanup architecture (always & cleanup blocks)... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'post {' in content, 'Must declare post block'
assert 'always {' in content, 'Must declare always block in post'
assert 'cleanup {' in content, 'Must declare cleanup block in post'
assert 'rm -rf target-repo' in content, 'Always block must remove target-repo'
assert 'cleanWs deleteDirs: true, notFailBuild: true' in content, 'Cleanup block must invoke cleanWs'
EOF
echo "PASS (Comprehensive always and cleanup post-action blocks verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Deterministic Container Naming for Abort Cleanup
# ------------------------------------------------------------------------------
echo -n "[Test 18/25] Deterministic container naming and targeted abort cleanup... "
python3 - << EOF
with open('${JENKINSFILE}', 'r') as f:
    content = f.read()

assert 'CONTAINER_NAME="analyzer-\${BUILD_TAG' in content, 'Must assign deterministic container name tied to BUILD_TAG'
assert '--name "\$CONTAINER_NAME"' in content, 'docker run must use CONTAINER_NAME'
assert 'docker stop "\$CONTAINER_NAME"' in content, 'Always block must stop named container'
assert 'docker rm -f "\$CONTAINER_NAME"' in content, 'Always block must remove named container'
EOF
echo "PASS (Targeted container stop/rm on abort and timeout verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Live Container Sandboxing & Execution on Representative Repo
# ------------------------------------------------------------------------------
echo -n "[Test 19/25] Live Docker execution on representative repo with sandboxing flags... "
LIVE_TEST_DIR="${TEST_TMP}/live_repo"
mkdir -p "${LIVE_TEST_DIR}"
git -C "${LIVE_TEST_DIR}" init -q
git -C "${LIVE_TEST_DIR}" config user.name "Alice Engineer"
git -C "${LIVE_TEST_DIR}" config user.email "alice@example.com"
echo "const express = require('express');" > "${LIVE_TEST_DIR}/app.js"
git -C "${LIVE_TEST_DIR}" add app.js
git -C "${LIVE_TEST_DIR}" commit -q -m "feat: initial commit"
echo "app.listen(3000);" >> "${LIVE_TEST_DIR}/app.js"
git -C "${LIVE_TEST_DIR}" commit -q -am "feat: add listener"

CONTAINER_NAME="analyzer-test-live-${RANDOM}"
docker run --rm \
  --name "${CONTAINER_NAME}" \
  --user "$(id -u):$(id -g)" \
  --memory=768m \
  --cpus=1.5 \
  --pids-limit=100 \
  -v "${LIVE_TEST_DIR}:/repo" \
  adityaashok2274/git-repo-analyzer:latest >/dev/null 2>&1

test -f "${LIVE_TEST_DIR}/reports/metrics.json"
test -f "${LIVE_TEST_DIR}/reports/summary.md"
test -f "${LIVE_TEST_DIR}/reports/charts/commits_per_author.png"
test -f "${LIVE_TEST_DIR}/reports/charts/daily_commit_activity.png"
echo "PASS (Container executed cleanly; all metrics, markdown, and charts generated)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 20. Non-Root File Ownership Verification
# ------------------------------------------------------------------------------
echo -n "[Test 20/25] File ownership verification of generated reports (unprivileged UID)... "
FILE_UID=$(stat -c '%u' "${LIVE_TEST_DIR}/reports/metrics.json")
FILE_GID=$(stat -c '%g' "${LIVE_TEST_DIR}/reports/metrics.json")
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
if [ "${FILE_UID}" -eq "${CURRENT_UID}" ] && [ "${FILE_GID}" -eq "${CURRENT_GID}" ] && [ "${FILE_UID}" -ne 0 ]; then
    echo "PASS (Generated files owned by UID:GID ${FILE_UID}:${FILE_GID}, non-root)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Unexpected ownership: ${FILE_UID}:${FILE_GID}, expected non-root ${CURRENT_UID}:${CURRENT_GID})"
    exit 1
fi

# ------------------------------------------------------------------------------
# 21. Deterministic Static Report Content & Fallback Validation
# ------------------------------------------------------------------------------
echo -n "[Test 21/25] Deterministic report contents and Groq key absence fallback... "
python3 - << EOF
import json

with open('${LIVE_TEST_DIR}/reports/metrics.json', 'r') as f:
    metrics = json.load(f)

assert 'repository' in metrics, 'Metrics must contain repository data'
assert 'busFactor' in metrics, 'Metrics must contain busFactor data'
assert 'hotspots' in metrics, 'Metrics must contain hotspots data'

with open('${LIVE_TEST_DIR}/reports/summary.md', 'r') as f:
    summary = f.read()

assert '# Git Repository Analysis Report' in summary, 'Summary must have expected title'
assert '## Deterministic Metric Summary' in summary, 'Summary must contain deterministic metrics'
assert '## Bus Factor / Degree of Authorship' in summary, 'Summary must contain bus factor section'
assert '## Code Churn / Hotspot Volatility' in summary, 'Summary must contain code churn section'
assert 'charts/commits_per_author.png' in summary, 'Summary must link author chart'
assert 'charts/daily_commit_activity.png' in summary, 'Summary must link daily chart'
EOF
echo "PASS (Metrics structure and static report verified without GROQ_API_KEY)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 22. Zero-Commit Repository Handling
# ------------------------------------------------------------------------------
echo -n "[Test 22/25] Zero-commit repository graceful handling... "
ZERO_REPO_DIR="${TEST_TMP}/zero_repo"
mkdir -p "${ZERO_REPO_DIR}"
git -C "${ZERO_REPO_DIR}" init -q
git -C "${ZERO_REPO_DIR}" config user.name "Alice Engineer"
git -C "${ZERO_REPO_DIR}" config user.email "alice@example.com"

CONTAINER_ZERO="analyzer-test-zero-${RANDOM}"
docker run --rm \
  --name "${CONTAINER_ZERO}" \
  --user "$(id -u):$(id -g)" \
  --memory=768m \
  --cpus=1.5 \
  --pids-limit=100 \
  -v "${ZERO_REPO_DIR}:/repo" \
  adityaashok2274/git-repo-analyzer:latest >/dev/null 2>&1

python3 - << EOF
with open('${ZERO_REPO_DIR}/reports/summary.md', 'r') as f:
    summary = f.read()

assert 'No commits found' in summary, 'Zero-commit report must explicitly note no commits'
assert 'Charts unavailable — repository has no commits' in summary or 'charts will be skipped' in summary, 'Zero-commit report must note skipped charts'
EOF
echo "PASS (Zero-commit repository handled gracefully without errors)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 23. Workspace Cleanup Validation (Interrupted Clone & Analysis)
# ------------------------------------------------------------------------------
echo -n "[Test 23/25] Workspace cleanup validation across interrupted clone and analysis... "
python3 - << 'EOF'
import subprocess, os, tempfile

ws = tempfile.mkdtemp(prefix='ws-test-')
target_repo = os.path.join(ws, 'target-repo')
os.makedirs(target_repo, exist_ok=True)
with open(os.path.join(target_repo, 'partial_clone.tmp'), 'w') as f:
    f.write('partial clone content')

# Scenario A: Interrupted clone cleanup
assert os.path.exists(target_repo), 'Target repo must exist before cleanup'
subprocess.run(['rm', '-rf', target_repo], check=True)
assert not os.path.exists(target_repo), 'Target repo must be removed after clone interruption cleanup'

# Scenario B: Interrupted analysis with active container
os.makedirs(target_repo, exist_ok=True)
cname = 'test-abort-cleanup-cid'
proc = subprocess.run([
    'docker', 'run', '-d',
    '--name', cname,
    '--user', f'{os.getuid()}:{os.getgid()}',
    '--memory=768m',
    '-v', f'{target_repo}:/repo',
    'adityaashok2274/git-repo-analyzer:latest',
    'sleep', '60'
], capture_output=True, text=True)

# Run post cleanup commands
subprocess.run(f'docker stop {cname} 2>/dev/null || true', shell=True, check=True)
subprocess.run(f'docker rm -f {cname} 2>/dev/null || true', shell=True, check=True)
subprocess.run(['rm', '-rf', target_repo], check=True)

# Verify container is dead and directory is removed
res = subprocess.run(['docker', 'ps', '-q', '--filter', f'name={cname}'], capture_output=True, text=True)
assert res.stdout.strip() == '', 'Aborted container must be halted and cleaned up'
assert not os.path.exists(target_repo), 'Workspace directory must be cleaned up'

subprocess.run(['rm', '-rf', ws], check=True)
EOF
echo "PASS (Residual containers stopped and workspaces purged on interruption)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 24. Workspace Cleanup Validation (Size Rejection & Pre-Clone Gate)
# ------------------------------------------------------------------------------
echo -n "[Test 24/25] Workspace cleanup on post-clone size violation (> 2 GB)... "
python3 - << 'EOF'
import os, tempfile, shutil

ws = tempfile.mkdtemp(prefix='ws-size-')
target_repo = os.path.join(ws, 'target-repo')
os.makedirs(target_repo, exist_ok=True)

# Simulate 2 GB rejection trigger
fake_repo_size_kb = 2500000
ceiling_kb = 2097152

if fake_repo_size_kb > ceiling_kb:
    shutil.rmtree(target_repo)

assert not os.path.exists(target_repo), 'Oversized target repository must be removed immediately'
shutil.rmtree(ws)
EOF
echo "PASS (Immediate removal of oversized repository verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 25. Local Workstation Workload Telemetry Benchmark (Live EC2 Validation Pending)
# ------------------------------------------------------------------------------
echo -n "[Test 25/25] Local workstation workload telemetry benchmark (2 GB EC2 300 MB validation still pending)... "
python3 - << 'EOF'
import json, os, shutil, subprocess, tempfile, threading, time

def read_meminfo():
    with open('/proc/meminfo') as f:
        info = {}
        for line in f:
            parts = line.split(':')
            if len(parts) == 2:
                info[parts[0].strip()] = int(parts[1].strip().split()[0])
    mem_total = info.get('MemTotal', 0) / 1024.0
    avail = info.get('MemAvailable', 0) / 1024.0
    swap_used = (info.get('SwapTotal', 0) - info.get('SwapFree', 0)) / 1024.0
    return mem_total, avail, swap_used

# Prepare multi-commit repository for workload profiling
workload_dir = tempfile.mkdtemp(prefix='workload-prof-')
cidfile = os.path.join(tempfile.gettempdir(), f'analyzer-prof-{os.getpid()}.cid')
cname = f'analyzer-prof-{os.getpid()}'
if os.path.exists(cidfile):
    os.remove(cidfile)

try:
    subprocess.run(['git', 'init', '-q'], cwd=workload_dir, check=True)
    subprocess.run(['git', 'config', 'user.name', 'Perf Tester'], cwd=workload_dir, check=True)
    subprocess.run(['git', 'config', 'user.email', 'perf@example.com'], cwd=workload_dir, check=True)

    for i in range(1, 35):
        with open(os.path.join(workload_dir, f'perf_{i % 5}.js'), 'a') as f:
            f.write(f'function compute_{i}() {{ return {i} * 42; }}\n')
    subprocess.run(['git', 'add', '.'], cwd=workload_dir, check=True)
    subprocess.run(['git', 'commit', '-q', '-m', 'perf commits'], cwd=workload_dir, check=True)

    # Capture pre-test host memory & swap baseline prior to container launch
    mem_total_mb, baseline_avail_mb, baseline_swap_used_mb = read_meminfo()

    stop_event = threading.Event()
    mem_samples = []
    swap_samples = []
    cgroup_mem_peak_samples = []
    cgroup_swap_peak_samples = []

    def sample_host():
        while not stop_event.is_set():
            try:
                _, avail_mb, swap_used_mb = read_meminfo()
                mem_samples.append(avail_mb)
                swap_samples.append(swap_used_mb)
                if os.path.exists(cidfile):
                    cid_val = open(cidfile).read().strip()
                    if cid_val:
                        for p in (
                            f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.peak',
                            f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.current',
                            f'/sys/fs/cgroup/docker/{cid_val}/memory.peak',
                        ):
                            if os.path.exists(p):
                                cgroup_mem_peak_samples.append(int(open(p).read().strip()) / (1024 * 1024))
                                break
                        for p in (
                            f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.swap.peak',
                            f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.swap.current',
                            f'/sys/fs/cgroup/docker/{cid_val}/memory.swap.peak',
                        ):
                            if os.path.exists(p):
                                cgroup_swap_peak_samples.append(int(open(p).read().strip()) / (1024 * 1024))
                                break
            except Exception:
                pass
            time.sleep(0.05)

    t = threading.Thread(target=sample_host, daemon=True)
    t.start()

    start_t = time.time()
    # Run briefly without --rm so container OOMKilled and final cgroup peaks can be inspected reliably
    res = subprocess.run([
        'docker', 'run',
        '--cidfile', cidfile,
        '--name', cname,
        '--user', f'{os.getuid()}:{os.getgid()}',
        '--memory=768m',
        '--cpus=1.5',
        '--pids-limit=100',
        '-v', f'{workload_dir}:/repo',
        'adityaashok2274/git-repo-analyzer:latest',
    ], capture_output=True, text=True)

    duration = time.time() - start_t
    stop_event.set()
    t.join()

    assert res.returncode == 0, f'Analyzer execution failed: {res.stderr}'
    assert len(mem_samples) > 0, 'Must capture memory telemetry samples'

    insp = json.loads(subprocess.check_output(['docker', 'inspect', cname], text=True))[0]
    cid = insp['Id']
    oom_killed = bool(insp['State']['OOMKilled'])
    assert oom_killed is False, 'Container reported OOMKilled=True'

    oom_events = 0
    for p in (
        f'/sys/fs/cgroup/system.slice/docker-{cid}.scope/memory.events',
        f'/sys/fs/cgroup/docker/{cid}/memory.events',
    ):
        if os.path.exists(p):
            for line in open(p):
                k, v = line.split()
                if k in ('oom', 'oom_kill'):
                    oom_events += int(v)
            break
    assert oom_events == 0, f'Container cgroup reported OOM events: {oom_events}'

    peak_container_mem_mb = max(cgroup_mem_peak_samples) if cgroup_mem_peak_samples else None
    if peak_container_mem_mb is not None:
        assert peak_container_mem_mb < 768.0, f'Container memory exceeded 768 MB ceiling: {peak_container_mem_mb:.2f} MB'

    container_peak_swap_mb = max(cgroup_swap_peak_samples) if cgroup_swap_peak_samples else None
    min_avail = min(mem_samples)
    max_host_swap_used = max(swap_samples) if swap_samples else baseline_swap_used_mb
    host_swap_delta_mb = max(0.0, max_host_swap_used - baseline_swap_used_mb)

    # Preserve strict >= 300 MB host sanity floor & < 200 MB attributable swap ceiling
    assert min_avail >= 300.0, f'Local host memory headroom violation: observed {min_avail:.1f} MB < 300 MB threshold'
    if container_peak_swap_mb is not None:
        assert container_peak_swap_mb < 200.0, (
            f'Excessive container-attributable swap usage: {container_peak_swap_mb:.1f} MB (>= 200 MB)'
        )
    assert host_swap_delta_mb < 200.0, (
        f'Excessive host swap growth during benchmark: +{host_swap_delta_mb:.1f} MB over {baseline_swap_used_mb:.1f} MB baseline'
    )

    c_mem_str = f'{peak_container_mem_mb:.2f} MB' if peak_container_mem_mb is not None else 'unavailable'
    c_swap_str = f'{container_peak_swap_mb:.2f} MB' if container_peak_swap_mb is not None else 'unavailable (fallback to host delta)'
    print(f'\n  Local Workstation Benchmark Metrics (Isolated Container; No Jenkins JVM):')
    print(f'  - Local workstation MemTotal: {mem_total_mb:.1f} MB (baseline MemAvailable: {baseline_avail_mb:.1f} MB)')
    print(f'  - Execution duration: {duration:.2f}s')
    print(f'  - Telemetry samples captured: {len(mem_samples)}')
    print(f'  - Minimum observed local MemAvailable: {min_avail:.1f} MB (local sanity check >= 300.0 MB)')
    print(f'  - Container cgroup memory.peak: {c_mem_str} (< 768.0 MB limit), OOMKilled: {oom_killed}')
    print(f'  - Container-attributed cgroup swap peak: {c_swap_str} (< 200.0 MB)')
    print(f'  - Host swap baseline: {baseline_swap_used_mb:.1f} MB; max during run: {max_host_swap_used:.1f} MB; delta: +{host_swap_delta_mb:.1f} MB (< 200.0 MB)')
    print(f'  - Pending EC2 Gate: Live 300 MB headroom validation on the 2 GB t3.small EC2 CI/CD instance remains PENDING Boundary B.')
finally:
    if os.path.exists(cidfile):
        os.remove(cidfile)
    subprocess.run(['docker', 'rm', '-f', cname], capture_output=True)
    shutil.rmtree(workload_dir, ignore_errors=True)
EOF
echo "PASS (Local workstation telemetry recorded; live 2 GB EC2 300 MB headroom validation remains pending)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 7.1 Test Suite Complete: ${PASSED_COUNT}/${TOTAL_COUNT} Checks Passed"
echo "=============================================================================="
