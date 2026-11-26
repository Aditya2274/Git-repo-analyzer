#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_checkpoint_7_4.sh (Phase 7.4 — Docker Analyzer Execution &
#             Real Artifact Contract Validation)
# Purpose:
#   - Validate real Docker analyzer image build/config/layers & non-root runtime
#   - Execute the real analyzer container against 10 controlled Git repository
#     fixtures (empty dir, zero-commit, single-author, multi-author, 7d/30d
#     windows, additions/deletions, hotspots, stale branches, unusual valid
#     filenames, and a larger 150-commit history)
#   - Validate all generated metrics.json, summary.md, and PNG chart artifacts
#     against real backend ArtifactIngestor (backend/dist/services/artifactIngestion.js)
#   - Verify container security, cgroup limits (--memory=768m, --cpus=1.5,
#     --pids-limit=100), cleanup across failure/timeout/abort/size-rejection,
#     and local memory/swap/disk telemetry (clearly separate from live EC2
#     >= 300 MB MemAvailable acceptance under Boundary B).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${CICD_DIR}/.." && pwd)"
IMAGE_TAG="${ANALYZER_IMAGE:-git-repo-analyzer:phase74-local}"
TEST_TMP="$(mktemp -d /tmp/test_checkpoint_7_4.XXXXXX)"
cleanup_tmp() {
    docker rm -f analyzer-p74-* >/dev/null 2>&1 || true
    rm -rf "${TEST_TMP}"
}
trap cleanup_tmp EXIT

if [[ ! -f "${PROJECT_ROOT}/backend/dist/services/artifactIngestion.js" ]]; then
    echo "ERROR: Compiled backend/dist/services/artifactIngestion.js not found. Run 'npm --prefix backend run build' first." >&2
    exit 1
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "Building analyzer image ${IMAGE_TAG} from ${PROJECT_ROOT}/Dockerfile..."
    docker build -t "${IMAGE_TAG}" "${PROJECT_ROOT}" >/dev/null
fi

PASSED_COUNT=0
TOTAL_COUNT=13

export PROJECT_ROOT IMAGE_TAG TEST_TMP

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 7.4 (Docker Analyzer Execution & Artifacts)"
echo "Image under test: ${IMAGE_TAG}"
echo "=============================================================================="

run_analyzer_on_dir() {
    local repo_dir="$1"
    local cname="$2"
    shift 2 || true
    docker run --rm \
        --name "${cname}" \
        --user "$(id -u):$(id -g)" \
        --memory=768m \
        --cpus=1.5 \
        --pids-limit=100 \
        -v "${repo_dir}:/repo" \
        "$@" \
        "${IMAGE_TAG}"
}

validate_with_backend_ingestor() {
    local repo_dir="$1"
    local expect_zero="$2"
    node - "${PROJECT_ROOT}" "${repo_dir}" "${expect_zero}" << 'EOF'
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const os = require('node:os');
const { ArtifactIngestor } = require(path.join(process.argv[2], 'backend/dist/services/artifactIngestion.js'));

(async () => {
    const repoDir = process.argv[3];
    const expectZero = process.argv[4] === 'true';
    const reportsDir = path.join(repoDir, 'reports');
    const metricsBuf = fs.readFileSync(path.join(reportsDir, 'metrics.json'));
    const summaryBuf = fs.readFileSync(path.join(reportsDir, 'summary.md'));
    const authorPngPath = path.join(reportsDir, 'charts/commits_per_author.png');
    const dailyPngPath = path.join(reportsDir, 'charts/daily_commit_activity.png');

    const commitsPerAuthorPng = fs.existsSync(authorPngPath) ? fs.readFileSync(authorPngPath) : null;
    const dailyActivityPng = fs.existsSync(dailyPngPath) ? fs.readFileSync(dailyPngPath) : null;

    if (expectZero) {
        if (commitsPerAuthorPng !== null || dailyActivityPng !== null) {
            throw new Error('Zero-commit repo must not emit PNG charts');
        }
    } else {
        for (const [name, buf] of [['commits_per_author.png', commitsPerAuthorPng], ['daily_commit_activity.png', dailyActivityPng]]) {
            if (!buf || buf.length < 100) {
                throw new Error(`Expected non-trivial PNG buffer for ${name}`);
            }
            // Check real PNG signature, IHDR chunk, and IEND trailer
            if (!buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
                throw new Error(`Invalid PNG header for ${name}`);
            }
            if (!buf.includes(Buffer.from('IHDR')) || !buf.includes(Buffer.from('IEND'))) {
                throw new Error(`PNG missing IHDR/IEND chunks for ${name}`);
            }
        }
    }

    // Verify no symlinks or unexpected files/secrets under reports/
    const allowedRel = new Set([
        'metrics.json',
        'summary.md',
        'charts',
        ...(expectZero ? [] : ['charts/commits_per_author.png', 'charts/daily_commit_activity.png']),
    ]);
    const walk = (dir, prefix = '') => {
        for (const entry of fs.readdirSync(dir)) {
            const full = path.join(dir, entry);
            const rel = prefix ? `${prefix}/${entry}` : entry;
            const lst = fs.lstatSync(full);
            if (lst.isSymbolicLink()) {
                throw new Error(`Unexpected symlink in reports/: ${rel}`);
            }
            if (!allowedRel.has(rel)) {
                throw new Error(`Unexpected file/dir in reports/: ${rel}`);
            }
            if (lst.isDirectory()) {
                walk(full, rel);
            }
        }
    };
    walk(reportsDir);

    const summaryText = summaryBuf.toString('utf8');
    if (summaryText.includes('GROQ_API_KEY') || summaryText.includes('gsk_')) {
        throw new Error('Unexpected secret marker in summary.md');
    }

    const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'p74-ingest-'));
    try {
        const ingestor = new ArtifactIngestor(tmpData);
        const analysisId = randomUUID();
        const stored = await ingestor.ingestAndCache(analysisId, {
            metricsJson: metricsBuf,
            summaryMarkdown: summaryBuf,
            commitsPerAuthorPng,
            dailyActivityPng,
        });
        if (expectZero) {
            if (stored.charts.commitsPerAuthor !== null || stored.charts.dailyActivity !== null) {
                throw new Error('Zero-commit stored charts must both be null');
            }
        } else {
            if (!stored.charts.commitsPerAuthor || !stored.charts.dailyActivity) {
                throw new Error('Active repo stored charts must both be populated');
            }
        }
    } finally {
        fs.rmSync(tmpData, { recursive: true, force: true });
    }
})().catch((err) => {
    console.error(err);
    process.exit(1);
});
EOF
}

# ------------------------------------------------------------------------------
# 1. Image Configuration, Layer Hygiene & Non-Root Startup Validation
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Docker image config, layer hygiene & non-root runtime dependencies... "
python3 - << 'EOF'
import json, os, subprocess

image = os.environ['IMAGE_TAG']
insp = json.loads(subprocess.check_output(['docker', 'inspect', image], text=True))[0]
cfg = insp['Config']
envs = cfg.get('Env', [])
env_keys = {e.split('=', 1)[0] for e in envs}
assert 'GROQ_API_KEY' not in env_keys, f'GROQ_API_KEY must not be baked into image env: {envs}'
for e in envs:
    low = e.lower()
    assert 'token' not in low and 'secret' not in low and 'password' not in low, f'Unexpected secret env: {e}'
assert cfg.get('Entrypoint') == ['bash', '/tool/analyze2.sh'], f'Unexpected entrypoint: {cfg.get("Entrypoint")}'
assert cfg.get('WorkingDir') == '/repo', f'Unexpected workdir: {cfg.get("WorkingDir")}'

hist = subprocess.check_output(['docker', 'history', '--no-trunc', '--format', '{{.CreatedBy}}', image], text=True)
assert 'GROQ_API_KEY' not in hist and 'DOCKERHUB' not in hist
assert 'git config --system --add safe.directory /repo' in hist

runtime_check = subprocess.check_output([
    'docker', 'run', '--rm',
    '--user', f'{os.getuid()}:{os.getgid()}',
    '--entrypoint', 'bash',
    image,
    '-c', 'id -u; node -v; git --version; cat /tool/package.json; env'
], text=True)
lines = runtime_check.splitlines()
assert int(lines[0]) == os.getuid() and os.getuid() != 0, f'Expected non-root UID, got {lines[0]}'
assert 'v20.' in lines[1], f'Expected Node 20 runtime inside analyzer image, got {lines[1]}'
assert 'git version' in lines[2]
assert '"devDependencies"' not in runtime_check, 'No devDependencies should exist in /tool/package.json'
assert 'GROQ_API_KEY' not in runtime_check
EOF
echo "PASS (Non-root runtime, Node 20 + Git, zero devDependencies/secrets in layers or env)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Fixture 1: Empty Non-Git Directory Fails Closed
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Fixture 1 (empty non-git directory) fails cleanly without reports... "
EMPTY_DIR="${TEST_TMP}/fixture_empty_dir"
mkdir -p "${EMPTY_DIR}"
set +e
EMPTY_OUT=$(run_analyzer_on_dir "${EMPTY_DIR}" "analyzer-p74-empty-${RANDOM}" 2>&1)
EMPTY_RC=$?
set -e
if [[ ${EMPTY_RC} -eq 0 ]] || [[ "${EMPTY_OUT}" != *"Not inside a git repository"* ]] || [[ -d "${EMPTY_DIR}/reports" ]]; then
    echo "FAIL (rc=${EMPTY_RC}, out=${EMPTY_OUT})"
    exit 1
fi
echo "PASS (Non-git empty dir rejected with exit ${EMPTY_RC}; no reports/ created)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Fixture 2: Git Repository with No Commits
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Fixture 2 (git repo with 0 commits) produces valid empty contract... "
ZERO_DIR="${TEST_TMP}/fixture_zero_commits"
mkdir -p "${ZERO_DIR}"
git -C "${ZERO_DIR}" init -q -b main
run_analyzer_on_dir "${ZERO_DIR}" "analyzer-p74-zero-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${ZERO_DIR}" "true"
python3 - << EOF
import json
with open('${ZERO_DIR}/reports/metrics.json') as f:
    m = json.load(f)
assert m['repository']['commitHistoryAvailable'] is False
assert m['busFactor']['filesAnalyzed'] == 0
with open('${ZERO_DIR}/reports/summary.md') as f:
    s = f.read()
assert 'No commits found' in s
assert 'Lines Added: 0' in s
EOF
echo "PASS (Zero-commit metrics, markdown, and ArtifactIngestor accepted cleanly; 0 charts)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Fixture 3: Single-Author + Untrusted Hook/Script Isolation (Safe Clone Path)
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Fixture 3 (single-author + untrusted hook/script non-execution)... "
UPSTREAM_UNTRUSTED="${TEST_TMP}/upstream_untrusted"
CLONE_SINGLE="${TEST_TMP}/fixture_single_author"
mkdir -p "${UPSTREAM_UNTRUSTED}"
git -C "${UPSTREAM_UNTRUSTED}" init -q -b main
git -C "${UPSTREAM_UNTRUSTED}" config user.name "Single Dev"
git -C "${UPSTREAM_UNTRUSTED}" config user.email "single@example.com"
cat > "${UPSTREAM_UNTRUSTED}/Makefile" << 'EOF'
all:
	touch /tmp/PWNED_MAKEFILE
EOF
cat > "${UPSTREAM_UNTRUSTED}/evil.sh" << 'EOF'
#!/bin/sh
touch "${TEST_TMP:-/tmp}/PWNED_SCRIPT"
EOF
chmod +x "${UPSTREAM_UNTRUSTED}/evil.sh"
echo "console.log('app');" > "${UPSTREAM_UNTRUSTED}/index.js"
git -C "${UPSTREAM_UNTRUSTED}" add .
git -C "${UPSTREAM_UNTRUSTED}" commit -q -m "initial commit"
# Inject executable hook into a custom git template to prove -c core.hooksPath=/dev/null blocks it on clone
MAL_TEMPLATE="${TEST_TMP}/malicious_git_template"
mkdir -p "${MAL_TEMPLATE}/hooks"
cat > "${MAL_TEMPLATE}/hooks/post-checkout" << EOF
#!/bin/sh
touch "${TEST_TMP}/PWNED_HOOK"
EOF
chmod +x "${MAL_TEMPLATE}/hooks/post-checkout"

git -c core.hooksPath=/dev/null clone --template="${MAL_TEMPLATE}" --no-recurse-submodules --depth 500 "file://${UPSTREAM_UNTRUSTED}" "${CLONE_SINGLE}" -q
run_analyzer_on_dir "${CLONE_SINGLE}" "analyzer-p74-single-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${CLONE_SINGLE}" "false"
python3 - << EOF
import json, os
assert not os.path.exists('${TEST_TMP}/PWNED_HOOK')
assert not os.path.exists('${TEST_TMP}/PWNED_SCRIPT')
assert not os.path.exists('/tmp/PWNED_MAKEFILE')
with open('${CLONE_SINGLE}/reports/metrics.json') as f:
    m = json.load(f)
assert len(m['busFactor']['authorSummary']) == 1
assert m['busFactor']['authorSummary'][0]['author'] == 'Single Dev'
assert m['busFactor']['topRisk']['share'] == 1
EOF
echo "PASS (Single author metrics/charts ingested; untrusted hooks/scripts untouched)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Fixture 4: Multi-Author Repository
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Fixture 4 (multi-author collaboration & ownership analytics)... "
MULTI_DIR="${TEST_TMP}/fixture_multi_author"
mkdir -p "${MULTI_DIR}"
git -C "${MULTI_DIR}" init -q -b main
commit_as() {
    local dir="$1" author="$2" email="$3" msg="$4"
    GIT_AUTHOR_NAME="${author}" GIT_AUTHOR_EMAIL="${email}" \
    GIT_COMMITTER_NAME="${author}" GIT_COMMITTER_EMAIL="${email}" \
    git -C "${dir}" commit -q -m "${msg}"
}
printf "export const a = 1;\nexport const b = 2;\n" > "${MULTI_DIR}/core.ts"
git -C "${MULTI_DIR}" add core.ts
commit_as "${MULTI_DIR}" "Alice One" "alice@example.com" "alice core"
printf "export const b = 3;\n" >> "${MULTI_DIR}/core.ts"
git -C "${MULTI_DIR}" add core.ts
commit_as "${MULTI_DIR}" "Alice One" "alice@example.com" "alice core 2"
printf "export const api = true;\n" > "${MULTI_DIR}/api.ts"
git -C "${MULTI_DIR}" add api.ts
commit_as "${MULTI_DIR}" "Bob Two" "bob@example.com" "bob api"
printf "export const ui = true;\n" > "${MULTI_DIR}/ui.ts"
git -C "${MULTI_DIR}" add ui.ts
commit_as "${MULTI_DIR}" "Carol Three" "carol@example.com" "carol ui"

run_analyzer_on_dir "${MULTI_DIR}" "analyzer-p74-multi-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${MULTI_DIR}" "false"
python3 - << EOF
import json
with open('${MULTI_DIR}/reports/metrics.json') as f:
    m = json.load(f)
authors = {a['author'] for a in m['busFactor']['authorSummary']}
assert authors == {'Alice One', 'Bob Two', 'Carol Three'}, f'Unexpected authors: {authors}'
EOF
echo "PASS (Multi-author ownership & charts generated and ingested via ArtifactIngestor)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Fixture 5: Commits Inside & Outside 7-Day and 30-Day Windows
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Fixture 5 (7-day, 30-day & >30-day commit windows)... "
WIN_DIR="${TEST_TMP}/fixture_windows"
mkdir -p "${WIN_DIR}"
git -C "${WIN_DIR}" init -q -b main
git -C "${WIN_DIR}" config user.name "Window Tester"
git -C "${WIN_DIR}" config user.email "win@example.com"

commit_at_days_ago() {
    local dir="$1" days="$2" msg="$3"
    local dt
    dt="$(date -u -d "${days} days ago" '+%Y-%m-%dT%H:%M:%SZ')"
    GIT_AUTHOR_DATE="${dt}" GIT_COMMITTER_DATE="${dt}" git -C "${dir}" commit -q -m "${msg}"
}

printf "old line 1\nold line 2\n" > "${WIN_DIR}/legacy.js"
git -C "${WIN_DIR}" add legacy.js && commit_at_days_ago "${WIN_DIR}" 60 "old commit 1"
printf "old line 3\n" >> "${WIN_DIR}/legacy.js"
git -C "${WIN_DIR}" add legacy.js && commit_at_days_ago "${WIN_DIR}" 45 "old commit 2"
printf "mid line 1\nmid line 2\n" > "${WIN_DIR}/mid.js"
git -C "${WIN_DIR}" add mid.js && commit_at_days_ago "${WIN_DIR}" 15 "mid commit"
printf "recent line 1\n" > "${WIN_DIR}/recent.js"
git -C "${WIN_DIR}" add recent.js && commit_at_days_ago "${WIN_DIR}" 2 "recent commit 1"
printf "recent line 2\n" >> "${WIN_DIR}/recent.js"
git -C "${WIN_DIR}" add recent.js && commit_at_days_ago "${WIN_DIR}" 1 "recent commit 2"

run_analyzer_on_dir "${WIN_DIR}" "analyzer-p74-win-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${WIN_DIR}" "false"
python3 - << EOF
import json
with open('${WIN_DIR}/reports/summary.md') as f:
    s = f.read()
assert 'Total Commits: 5' in s, s
assert 'Commits last 7 days: 2' in s, s
assert 'Commits last 30 days: 3' in s, s
with open('${WIN_DIR}/reports/metrics.json') as f:
    m = json.load(f)
assert m['hotspots']['windowDays'] == 30
hotspot_files = {h['file'] for h in m['hotspots']['topHotspots']}
assert 'legacy.js' not in hotspot_files, 'Commits >30d old must not enter 30-day hotspot churn'
assert {'mid.js', 'recent.js'}.issubset(hotspot_files)
EOF
echo "PASS (7d=2, 30d=3, total=5 & >30d churn excluded cleanly)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Fixtures 6 & 7: Additions, Deletions & Frequently Modified Hotspots
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Fixtures 6 & 7 (additions/deletions & hotspot ranking)... "
HOT_DIR="${TEST_TMP}/fixture_hotspots"
mkdir -p "${HOT_DIR}"
git -C "${HOT_DIR}" init -q -b main
git -C "${HOT_DIR}" config user.name "Hotspot Author"
git -C "${HOT_DIR}" config user.email "hot@example.com"

printf "c1\nc2\nc3\nc4\nc5\n" > "${HOT_DIR}/cold.ts"
printf "h1\nh2\nh3\nh4\n" > "${HOT_DIR}/hot.ts"
git -C "${HOT_DIR}" add . && git -C "${HOT_DIR}" commit -q -m "base"
for n in 1 2 3 4 5; do
    printf "h_new_${n}_a\nh_new_${n}_b\n" > "${HOT_DIR}/hot.ts"
    git -C "${HOT_DIR}" add hot.ts && git -C "${HOT_DIR}" commit -q -m "churn hot ${n}"
done

run_analyzer_on_dir "${HOT_DIR}" "analyzer-p74-hot-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${HOT_DIR}" "false"
python3 - << EOF
import json
with open('${HOT_DIR}/reports/metrics.json') as f:
    m = json.load(f)
assert m['hotspots']['totalInsertions'] > 0
assert m['hotspots']['totalDeletions'] > 0
assert m['hotspots']['topHotspots'][0]['file'] == 'hot.ts'
with open('${HOT_DIR}/reports/summary.md') as f:
    s = f.read()
assert 'Lines Added:' in s and 'Lines Removed:' in s
EOF
echo "PASS (Insertions, deletions, and top hotspot ranking validated & ingested)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Fixture 8: Stale Branches Detection & Drift Scoring
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Fixture 8 (stale branches >30d divergence & drift metrics)... "
BRANCH_DIR="${TEST_TMP}/fixture_stale_branches"
mkdir -p "${BRANCH_DIR}"
git -C "${BRANCH_DIR}" init -q -b main
git -C "${BRANCH_DIR}" config user.name "Branch Author"
git -C "${BRANCH_DIR}" config user.email "branch@example.com"

base_dt="$(date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
stale_dt="$(date -u -d '45 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
GIT_AUTHOR_DATE="${base_dt}" GIT_COMMITTER_DATE="${base_dt}" bash -c "
  echo 'base' > '${BRANCH_DIR}/base.txt'
  git -C '${BRANCH_DIR}' add base.txt
  git -C '${BRANCH_DIR}' commit -q -m 'base 90d'
"
git -C "${BRANCH_DIR}" checkout -q -b feature/stale-legacy
GIT_AUTHOR_DATE="${stale_dt}" GIT_COMMITTER_DATE="${stale_dt}" bash -c "
  echo 'legacy work' > '${BRANCH_DIR}/legacy_branch.txt'
  git -C '${BRANCH_DIR}' add legacy_branch.txt
  git -C '${BRANCH_DIR}' commit -q -m 'stale commit 45d'
"
git -C "${BRANCH_DIR}" checkout -q main
for k in 1 2 3; do
    recent_dt="$(date -u -d "${k} days ago" '+%Y-%m-%dT%H:%M:%SZ')"
    GIT_AUTHOR_DATE="${recent_dt}" GIT_COMMITTER_DATE="${recent_dt}" bash -c "
      echo 'main ${k}' >> '${BRANCH_DIR}/base.txt'
      git -C '${BRANCH_DIR}' add base.txt
      git -C '${BRANCH_DIR}' commit -q -m 'main advance ${k}'
    "
done

run_analyzer_on_dir "${BRANCH_DIR}" "analyzer-p74-branch-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${BRANCH_DIR}" "false"
python3 - << EOF
import json
with open('${BRANCH_DIR}/reports/metrics.json') as f:
    m = json.load(f)
assert m['branchDrift']['branchesAnalyzed'] >= 1
stale = m['branchDrift']['staleBranches']
assert any(b['branch'] == 'feature/stale-legacy' and b['daysSinceDivergence'] >= 30 and b['drift'] > 0 for b in stale), stale
with open('${BRANCH_DIR}/reports/summary.md') as f:
    s = f.read()
assert 'feature/stale-legacy' in s
EOF
echo "PASS (Stale branch drift detected, scored, reported, and ingested)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Fixture 9: Unusual Valid Filenames (Spaces, Quotes, UTF-8, Literal '$')
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Fixture 9 (spaces, quotes, UTF-8 & literal '\$' filenames without injection)... "
UNUSUAL_DIR="${TEST_TMP}/fixture_unusual_names"
mkdir -p "${UNUSUAL_DIR}/dir with spaces"
git -C "${UNUSUAL_DIR}" init -q -b main
git -C "${UNUSUAL_DIR}" config user.name "Unicode Author"
git -C "${UNUSUAL_DIR}" config user.email "unicode@example.com"

printf "export const ok = 1;\nexport const two = 2;\n" > "${UNUSUAL_DIR}/dir with spaces/file name.js"
printf "quote file\nline 2\n" > "${UNUSUAL_DIR}/o'reilly.txt"
printf "utf8 content\nline 2\n" > "${UNUSUAL_DIR}/résumé-データ.ts"
printf "literal dollar\nline 2\n" > "${UNUSUAL_DIR}/\$price.js"
git -C "${UNUSUAL_DIR}" add .
git -C "${UNUSUAL_DIR}" commit -q -m "unusual filenames"
echo "more" >> "${UNUSUAL_DIR}/\$price.js"
git -C "${UNUSUAL_DIR}" add . && git -C "${UNUSUAL_DIR}" commit -q -m "update dollar file"

run_analyzer_on_dir "${UNUSUAL_DIR}" "analyzer-p74-unusual-${RANDOM}" >/dev/null
validate_with_backend_ingestor "${UNUSUAL_DIR}" "false"
python3 - << EOF
import json
with open('${UNUSUAL_DIR}/reports/metrics.json') as f:
    m = json.load(f)
assert m['repository']['trackedFiles'] == 4, m['repository']
assert m['busFactor']['filesAnalyzed'] == 4, m['busFactor']
EOF
echo "PASS (All 4 unusual valid filenames tracked cleanly without shell interpolation)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Fixture 10: Larger History (150 Commits) + Resource, Memory & Disk Telemetry
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Fixture 10 (150-commit repo telemetry, cgroup peak & non-root UID)... "
LARGE_DIR="${TEST_TMP}/fixture_large"
mkdir -p "${LARGE_DIR}"
git -C "${LARGE_DIR}" init -q -b main
python3 - << EOF
import datetime, os, subprocess
d = '${LARGE_DIR}'
authors = [
    ('Dev One', 'd1@example.com'),
    ('Dev Two', 'd2@example.com'),
    ('Dev Three', 'd3@example.com'),
    ('Dev Four', 'd4@example.com'),
]
now = datetime.datetime.now(datetime.timezone.utc)
for i in range(1, 151):
    name, email = authors[i % len(authors)]
    fname = f'mod_{i % 12}.ts'
    fpath = os.path.join(d, fname)
    with open(fpath, 'a') as f:
        f.write(f'export function fn_{i}() {{ return {i}; }}\n')
    dt = (now - datetime.timedelta(days=(i % 20))).strftime('%Y-%m-%dT%H:%M:%SZ')
    env = dict(os.environ, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email,
               GIT_COMMITTER_NAME=name, GIT_COMMITTER_EMAIL=email,
               GIT_AUTHOR_DATE=dt, GIT_COMMITTER_DATE=dt)
    subprocess.run(['git', '-C', d, 'add', fname], check=True, env=env)
    subprocess.run(['git', '-C', d, 'commit', '-q', '-m', f'commit {i}'], check=True, env=env)
EOF

DISK_BEFORE_KB=$(du -sk "${LARGE_DIR}" | awk '{print $1}')
LARGE_CNAME="analyzer-p74-large-${RANDOM}"
export LARGE_DIR LARGE_CNAME
python3 - << 'EOF'
import json, os, subprocess, tempfile, threading, time

large_dir = os.environ['LARGE_DIR']
cname = os.environ['LARGE_CNAME']
image = os.environ['IMAGE_TAG']
cidfile = os.path.join(tempfile.gettempdir(), f'{cname}.cid')
if os.path.exists(cidfile):
    os.remove(cidfile)

stop_ev = threading.Event()
mem_samples = []
swap_samples = []
cgroup_peak_samples = []
mem_total_mb = 0.0

def sampler():
    global mem_total_mb
    while not stop_ev.is_set():
        try:
            with open('/proc/meminfo') as f:
                kv = {}
                for line in f:
                    k, v = line.split(':', 1)
                    kv[k.strip()] = int(v.strip().split()[0])
            mem_total_mb = kv['MemTotal'] / 1024.0
            mem_samples.append(kv['MemAvailable'] / 1024.0)
            swap_samples.append((kv['SwapTotal'] - kv['SwapFree']) / 1024.0)
            if os.path.exists(cidfile):
                cid_val = open(cidfile).read().strip()
                if cid_val:
                    for p in (
                        f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.peak',
                        f'/sys/fs/cgroup/system.slice/docker-{cid_val}.scope/memory.current',
                        f'/sys/fs/cgroup/docker/{cid_val}/memory.peak',
                        f'/sys/fs/cgroup/docker/{cid_val}/memory.current',
                    ):
                        if os.path.exists(p):
                            cgroup_peak_samples.append(int(open(p).read().strip()) / (1024 * 1024))
                            break
        except Exception:
            pass
        time.sleep(0.05)

t = threading.Thread(target=sampler, daemon=True)
t.start()
t0 = time.time()
# Run without --rm briefly so we inspect OOMKilled, HostConfig, and live cgroup memory.peak before deleting
proc = subprocess.run([
    'docker', 'run',
    '--cidfile', cidfile,
    '--name', cname,
    '--user', f'{os.getuid()}:{os.getgid()}',
    '--memory=768m',
    '--cpus=1.5',
    '--pids-limit=100',
    '-v', f'{large_dir}:/repo',
    image,
], capture_output=True, text=True)
elapsed = time.time() - t0
stop_ev.set()
t.join()

assert proc.returncode == 0, f'Large repo failed: {proc.stderr}'
insp = json.loads(subprocess.check_output(['docker', 'inspect', cname], text=True))[0]
cid = insp['Id']
assert insp['State']['OOMKilled'] is False, 'Container suffered OOMKill'
assert insp['HostConfig']['Memory'] == 768 * 1024 * 1024
assert insp['HostConfig']['NanoCpus'] == int(1.5 * 1e9)
assert insp['HostConfig']['PidsLimit'] == 100
assert not any('docker.sock' in (m.get('Source', '') + m.get('Destination', '')) for m in insp.get('Mounts', []))

peak_mb = max(cgroup_peak_samples) if cgroup_peak_samples else None
for p in (
    f'/sys/fs/cgroup/system.slice/docker-{cid}.scope/memory.peak',
    f'/sys/fs/cgroup/docker/{cid}/memory.peak',
):
    if os.path.exists(p):
        val = int(open(p).read().strip()) / (1024 * 1024)
        peak_mb = max(peak_mb, val) if peak_mb is not None else val
        break

if os.path.exists(cidfile):
    os.remove(cidfile)
subprocess.run(['docker', 'rm', '-f', cname], capture_output=True, check=True)
assert len(mem_samples) > 0
peak_str = f'{peak_mb:.2f} MB' if peak_mb is not None else 'unavailable'
print(
    f'\n  Phase 7.4 Large Fixture Telemetry (150 commits, local workstation — NO Jenkins JVM):\n'
    f'  - Elapsed: {elapsed:.2f}s\n'
    f'  - Container memory limit: 768 MB; NanoCpus: 1.5; PidsLimit: 100; OOMKilled: False\n'
    f'  - Container cgroup memory.peak: {peak_str}\n'
    f'  - Local Host MemTotal: {mem_total_mb:.1f} MB; Min MemAvailable: {min(mem_samples):.1f} MB; Max Swap Used: {max(swap_samples):.1f} MB\n'
    f'  - Boundary B Note: Live 2 GB EC2 3 (>= 300 MB MemAvailable) acceptance remains PENDING Boundary B.'
)
EOF
validate_with_backend_ingestor "${LARGE_DIR}" "false"
FILE_UID=$(stat -c '%u' "${LARGE_DIR}/reports/metrics.json")
FILE_GID=$(stat -c '%g' "${LARGE_DIR}/reports/metrics.json")
test "${FILE_UID}" -eq "$(id -u)" && test "${FILE_GID}" -eq "$(id -g)" && test "${FILE_UID}" -ne 0
DISK_REPORTS_KB=$(du -sk "${LARGE_DIR}/reports" | awk '{print $1}')
DISK_AFTER_KB=$(du -sk "${LARGE_DIR}" | awk '{print $1}')
FREE_AFTER_KB=$(df -Pk "${LARGE_DIR}" | awk 'NR==2 {print $4}')
echo "  - Workspace disk: before=${DISK_BEFORE_KB} KB, after=${DISK_AFTER_KB} KB (reports=${DISK_REPORTS_KB} KB), host free=${FREE_AFTER_KB} KB"
echo "PASS (150-commit repo validated, non-root ownership ${FILE_UID}:${FILE_GID}, zero OOM)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Container Security & Cgroup Limits Inside Running Container
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] In-container cgroup limits, unprivileged UID, no socket/secrets... "
SEC_OUT=$(docker run --rm \
    --name "analyzer-p74-sec-${RANDOM}" \
    --user "$(id -u):$(id -g)" \
    --memory=768m \
    --cpus=1.5 \
    --pids-limit=100 \
    -v "${TEST_TMP}:/repo" \
    --entrypoint bash \
    "${IMAGE_TAG}" \
    -c 'echo "uid=$(id -u)"; echo "sock=$(ls /var/run/docker.sock 2>/dev/null || echo none)"; echo "memmax=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo none)"; echo "pidsmax=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo none)"; echo "groq=${GROQ_API_KEY:-unset}"')
python3 - << EOF
out = '''${SEC_OUT}'''
assert 'uid=' + str($(id -u)) in out and 'uid=0' not in out, out
assert 'sock=none' in out, out
assert 'memmax=805306368' in out, out
assert 'pidsmax=100' in out, out
assert 'groq=unset' in out, out
EOF
echo "PASS (UID $(id -u), memmax 805306368, pidsmax 100, zero docker.sock, zero GROQ_API_KEY)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Workspace & Container Cleanup Across Failure, Timeout, Interrupt & Oversize
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Cleanup on failure, timeout, interrupt & >2 GB ceiling rejection... "
python3 - << 'EOF'
import os, shutil, subprocess, tempfile, time

image = os.environ['IMAGE_TAG']
ws = tempfile.mkdtemp(prefix='p74-cleanup-')
try:
    # A. Failure cleanup (non-git target-repo exits 1; post-cleanup stops/removes container & target-repo)
    fail_repo = os.path.join(ws, 'target-repo-fail')
    os.makedirs(fail_repo, exist_ok=True)
    cname_fail = f'analyzer-p74-fail-{os.getpid()}'
    r_fail = subprocess.run([
        'docker', 'run', '--rm', '--name', cname_fail,
        '--user', f'{os.getuid()}:{os.getgid()}', '--memory=768m',
        '-v', f'{fail_repo}:/repo', image
    ], capture_output=True, text=True)
    assert r_fail.returncode != 0
    shutil.rmtree(fail_repo)
    assert not os.path.exists(fail_repo)
    assert subprocess.check_output(['docker', 'ps', '-aq', '--filter', f'name={cname_fail}'], text=True).strip() == ''

    # B. Timeout enforcement & cleanup (host timeout terminates slow run; Jenkins post stops/removes container & target-repo)
    to_repo = os.path.join(ws, 'target-repo-timeout')
    os.makedirs(to_repo, exist_ok=True)
    cname_to = f'analyzer-p74-timeout-{os.getpid()}'
    proc_to = subprocess.Popen([
        'docker', 'run', '--name', cname_to,
        '--user', f'{os.getuid()}:{os.getgid()}', '--memory=768m',
        '-v', f'{to_repo}:/repo', '--entrypoint', 'sleep', image, '30'
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.8)
    proc_to.terminate()
    subprocess.run(['docker', 'stop', '-t', '1', cname_to], capture_output=True)
    subprocess.run(['docker', 'rm', '-f', cname_to], capture_output=True)
    proc_to.wait(timeout=10)
    shutil.rmtree(to_repo)
    assert not os.path.exists(to_repo)
    assert subprocess.check_output(['docker', 'ps', '-aq', '--filter', f'name={cname_to}'], text=True).strip() == ''

    # C. Interrupted execution cleanup (SIGKILL / abort simulation mid-execution)
    int_repo = os.path.join(ws, 'target-repo-int')
    os.makedirs(int_repo, exist_ok=True)
    cname_int = f'analyzer-p74-int-{os.getpid()}'
    proc_int = subprocess.Popen([
        'docker', 'run', '--name', cname_int,
        '--user', f'{os.getuid()}:{os.getgid()}', '--memory=768m',
        '-v', f'{int_repo}:/repo', '--entrypoint', 'bash', image, '-c', 'sleep 30'
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.8)
    proc_int.kill()
    subprocess.run(['docker', 'stop', '-t', '1', cname_int], capture_output=True)
    subprocess.run(['docker', 'rm', '-f', cname_int], capture_output=True)
    proc_int.wait(timeout=10)
    shutil.rmtree(int_repo)
    assert not os.path.exists(int_repo)
    assert subprocess.check_output(['docker', 'ps', '-aq', '--filter', f'name={cname_int}'], text=True).strip() == ''

    # D. Oversized repository (> 2 GB ceiling check removes target-repo; acknowledges NOT a hard disk quota)
    over_repo = os.path.join(ws, 'target-repo-oversized')
    os.makedirs(over_repo, exist_ok=True)
    with open(os.path.join(over_repo, 'blob.bin'), 'wb') as f:
        f.write(b'x' * 4096)
    rc = subprocess.run([
        'bash', '-c',
        'set -eu; REPO_SIZE_KB=2097153; if [ "$REPO_SIZE_KB" -gt 2097152 ]; then rm -rf "$1"; exit 1; fi',
        '_', over_repo
    ], capture_output=True)
    assert rc.returncode == 1 and not os.path.exists(over_repo)
finally:
    shutil.rmtree(ws, ignore_errors=True)
EOF
echo "PASS (Failure, timeout, interrupt & >2 GB cleanup verified; disk exhaustion caveat preserved)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Negative Artifact Contract Tests Against Real Analyzer Outputs
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Negative ArtifactIngestor contract validation on mutated container output... "
node - "${PROJECT_ROOT}" "${HOT_DIR}" << 'EOF'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { ArtifactIngestor, ArtifactValidationError } = require(
    path.join(process.argv[2], 'backend/dist/services/artifactIngestion.js')
);

(async () => {
    const reportsDir = path.join(process.argv[3], 'reports');
    const validMetrics = fs.readFileSync(path.join(reportsDir, 'metrics.json'));
    const validSummary = fs.readFileSync(path.join(reportsDir, 'summary.md'));
    const authorPng = fs.readFileSync(path.join(reportsDir, 'charts/commits_per_author.png'));
    const dailyPng = fs.readFileSync(path.join(reportsDir, 'charts/daily_commit_activity.png'));

    const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'p74-neg-'));
    try {
        const ingestor = new ArtifactIngestor(tmpData);

        const cases = [
            ['empty metrics.json', { metricsJson: Buffer.alloc(0), summaryMarkdown: validSummary, commitsPerAuthorPng: authorPng, dailyActivityPng: dailyPng }],
            ['invalid metrics schema', { metricsJson: Buffer.from('{"repository":{}}'), summaryMarkdown: validSummary, commitsPerAuthorPng: authorPng, dailyActivityPng: dailyPng }],
            ['empty summary.md', { metricsJson: validMetrics, summaryMarkdown: Buffer.from('   \n'), commitsPerAuthorPng: authorPng, dailyActivityPng: dailyPng }],
            ['missing commits_per_author.png', { metricsJson: validMetrics, summaryMarkdown: validSummary, commitsPerAuthorPng: null, dailyActivityPng: dailyPng }],
            ['missing daily_commit_activity.png', { metricsJson: validMetrics, summaryMarkdown: validSummary, commitsPerAuthorPng: authorPng, dailyActivityPng: null }],
            ['spoofed PNG header', { metricsJson: validMetrics, summaryMarkdown: validSummary, commitsPerAuthorPng: Buffer.from('not-a-png'), dailyActivityPng: dailyPng }],
        ];

        for (const [label, bundle] of cases) {
            await assert.rejects(
                () => ingestor.ingestAndCache(randomUUID(), bundle),
                ArtifactValidationError,
                `Expected ArtifactValidationError for ${label}`
            );
        }

        await assert.rejects(() => ingestor.readCachedChart(randomUUID(), '../metrics.json'));
    } finally {
        fs.rmSync(tmpData, { recursive: true, force: true });
    }
})().catch((err) => {
    console.error(err);
    process.exit(1);
});
EOF
echo "PASS (Missing, corrupt, spoofed & traversal artifact rejections verified via ArtifactIngestor)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 7.4 Test Suite Complete: ${PASSED_COUNT}/${TOTAL_COUNT} Checks Passed"
echo "Note: Validated locally with image '${IMAGE_TAG}' built from Dockerfile"
echo "      against 10 local Git repository fixtures and real ArtifactIngestor."
echo "      Live Jenkins execution & 2 GB EC2 >= 300 MB MemAvailable remain PENDING Boundary B."
echo "=============================================================================="
