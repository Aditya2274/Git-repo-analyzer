#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_docker_ci_workflow.sh
# Purpose: Static and semantic validation of .github/workflows/docker-ci.yml:
#          - Valid YAML syntax via PyYAML
#          - Trigger preservation (push to main and feat/deterministic-metrics, workflow_dispatch)
#          - Full checkout with fetch-depth: 0
#          - Local image build with versioned and latest tags
#          - Strict ordering: container validation occurs BEFORE Docker Hub login and push
#          - Runtime-only GROQ_API_KEY injection from secrets without build-args
#          - Fail-closed sequential step execution (validation failure aborts push)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${CICD_DIR}/.." && pwd)"
export WORKFLOW_FILE="${PROJECT_ROOT}/.github/workflows/docker-ci.yml"

PASSED_COUNT=0
TOTAL_COUNT=8

echo "=============================================================================="
echo "Running Test Suite: Docker CI/CD Workflow Validation"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. YAML Syntax Validity
# ------------------------------------------------------------------------------
echo -n "[Test 1/8] Workflow YAML syntax validation... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)
assert isinstance(data, dict), 'Workflow root must be a YAML mapping'
assert data.get('name') == 'Docker CI/CD', 'Workflow name must be Docker CI/CD'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Trigger Configuration Preservation
# ------------------------------------------------------------------------------
echo -n "[Test 2/8] Trigger preservation (push branches and workflow_dispatch)... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

triggers = data.get('on') if 'on' in data else data.get(True)
assert 'push' in triggers, 'Must configure push trigger'
branches = triggers['push'].get('branches', [])
assert any('main' in b for b in branches), 'Must trigger on main'
assert any('feat/deterministic-metrics' in b for b in branches), 'Must trigger on feat/deterministic-metrics'
assert 'workflow_dispatch' in triggers, 'Must support workflow_dispatch trigger'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Checkout Configuration
# ------------------------------------------------------------------------------
echo -n "[Test 3/8] Full Git history checkout (fetch-depth: 0)... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
checkout_step = next(s for s in steps if 'actions/checkout' in s.get('uses', ''))
assert checkout_step.get('with', {}).get('fetch-depth') == 0, 'Checkout must specify fetch-depth: 0'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Local Build with Versioned and Latest Tags
# ------------------------------------------------------------------------------
echo -n "[Test 4/8] Local Docker build with versioned and latest tags... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
build_step = next(s for s in steps if s.get('name') == 'Build Docker Image')
run_cmd = build_step.get('run', '')
assert 'docker build -t adityaashok2274/git-repo-analyzer:${{ env.VERSION }}' in run_cmd, 'Must build versioned tag'
assert 'docker tag adityaashok2274/git-repo-analyzer:${{ env.VERSION }} adityaashok2274/git-repo-analyzer:latest' in run_cmd, 'Must tag latest locally'
assert '--build-arg' not in run_cmd, 'Must not pass build arguments'
assert 'GROQ_API_KEY' not in run_cmd, 'GROQ_API_KEY must not be passed during build'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Validation Step Runs Before Docker Hub Login & Push
# ------------------------------------------------------------------------------
echo -n "[Test 5/8] Strict ordering: validation step executes before login and push... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
step_names = [s.get('name', '') for s in steps]

validate_idx = next(i for i, name in enumerate(step_names) if 'Validation' in name or 'Validate' in name or 'Run Analyzer in CI' in name)
login_idx = next(i for i, name in enumerate(step_names) if 'Login' in name or 'docker/login-action' in str(steps[i]))
push_idx = next(i for i, name in enumerate(step_names) if 'Push Docker Image' in name)

assert validate_idx < login_idx, f'Validation step (idx {validate_idx}) must precede login (idx {login_idx})'
assert validate_idx < push_idx, f'Validation step (idx {validate_idx}) must precede push (idx {push_idx})'
assert login_idx < push_idx, f'Login step (idx {login_idx}) must precede push (idx {push_idx})'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Validation Targets Local Image Without Pulling
# ------------------------------------------------------------------------------
echo -n "[Test 6/8] Validation targets locally built image without pulling... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
validate_step = next(s for s in steps if 'Validation' in s.get('name', '') or 'Validate' in s.get('name', '') or 'Run Analyzer in CI' in s.get('name', ''))
run_cmd = validate_step.get('run', '')
assert 'docker pull' not in run_cmd, 'Validation must NOT pull from Docker Hub; it must use locally built image'
assert 'adityaashok2274/git-repo-analyzer:latest' in run_cmd, 'Validation must run the locally built latest image'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Runtime-Only GROQ_API_KEY Injection via Secrets
# ------------------------------------------------------------------------------
echo -n "[Test 7/8] Runtime-only GROQ_API_KEY injection from secrets... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
validate_step = next(s for s in steps if 'Validation' in s.get('name', '') or 'Validate' in s.get('name', '') or 'Run Analyzer in CI' in s.get('name', ''))
env_vars = validate_step.get('env', {})
assert env_vars.get('GROQ_API_KEY') == '${{ secrets.GROQ_API_KEY }}', 'GROQ_API_KEY must be injected from secrets'

run_cmd = validate_step.get('run', '')
assert '-e GROQ_API_KEY="$GROQ_API_KEY"' in run_cmd, 'GROQ_API_KEY must be passed as runtime env flag'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Push Step Targets Both Tags
# ------------------------------------------------------------------------------
echo -n "[Test 8/8] Push step pushes both versioned and latest tags... "
python3 - << 'EOF'
import os, yaml
wf_file = os.environ['WORKFLOW_FILE']
with open(wf_file, 'r') as f:
    data = yaml.safe_load(f)

steps = data['jobs']['build-and-push']['steps']
push_step = next(s for s in steps if s.get('name') == 'Push Docker Image')
run_cmd = push_step.get('run', '')
assert 'docker push adityaashok2274/git-repo-analyzer:${{ env.VERSION }}' in run_cmd, 'Must push versioned tag'
assert 'docker push adityaashok2274/git-repo-analyzer:latest' in run_cmd, 'Must push latest tag'
EOF
echo "PASS"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Result: ${PASSED_COUNT}/${TOTAL_COUNT} checks PASSED (Exit 0)"
echo "=============================================================================="
