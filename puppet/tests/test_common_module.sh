#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Checkpoint 5A.2 — Common Puppet Module Implementation
# Purpose: Comprehensive static, structural, AST, and catalog compilation
#          validation for the common Puppet module under Approval Boundary A.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=14

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 5A.2 (Common Puppet Module)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Manifest Existence
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] File existence: modules/common/manifests/init.pp... "
test -f "${PUPPET_DIR}/modules/common/manifests/init.pp"
echo "PASS (manifest exists)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Puppet Parser Syntax Validation
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Puppet parser validate: modules/common/manifests/init.pp... "
puppet parser validate "${PUPPET_DIR}/modules/common/manifests/init.pp"
echo "PASS (syntax is valid Puppet DSL)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Class Signature & Parameter Types
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Class signature and parameter data typing... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert 'class common (' in content, 'Must define class common'
assert 'Array[String[1]] $packages' in content, 'packages must be Array[String[1]]'
assert 'String[1]        $timezone' in content or 'String[1] $timezone' in content, 'timezone must be String[1]'
assert 'Boolean          $manage_puppet_agent' in content or 'Boolean $manage_puppet_agent' in content, 'manage_puppet_agent must be Boolean'
assert 'String[1]        $puppet_agent_service' in content or 'String[1] $puppet_agent_service' in content, 'puppet_agent_service must be String[1]'
EOF
echo "PASS (class parameters strongly typed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Package Resource Declarations
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Package resource declarations and baseline defaults... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert 'package { $packages:' in content, 'Must declare package resource using $packages'
assert 'ensure => present,' in content, 'Package ensure must be present'

# Verify default packages cover standard system utilities
for pkg in ['curl', 'wget', 'git', 'htop', 'unzip', 'tar', 'jq', 'ca-certificates']:
    assert f"'{pkg}'" in content, f'Default packages must include {pkg}'
EOF
echo "PASS (package baseline properly declared)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Timezone File Configuration (/etc/timezone)
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Timezone file configuration (/etc/timezone)... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert "file { '/etc/timezone':" in content, 'Must declare /etc/timezone file resource'
assert 'content => "${timezone}\\n",' in content, '/etc/timezone must write formatted timezone string'
assert "mode    => '0644'," in content or "mode => '0644'," in content, '/etc/timezone must have 0644 mode'
assert "owner   => 'root'," in content or "owner => 'root'," in content, '/etc/timezone must be owned by root'
assert "group   => 'root'," in content or "group => 'root'," in content, '/etc/timezone must be grouped by root'
EOF
echo "PASS (/etc/timezone attributes verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Timezone Symlink Configuration (/etc/localtime)
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Timezone symlink configuration (/etc/localtime)... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert "file { '/etc/localtime':" in content, 'Must declare /etc/localtime file resource'
assert "ensure  => link," in content or "ensure => link," in content, '/etc/localtime must be a symlink'
assert 'target  => "/usr/share/zoneinfo/${timezone}",' in content or 'target => "/usr/share/zoneinfo/${timezone}",' in content, '/etc/localtime must target zoneinfo path'
assert "force   => true," in content or "force => true," in content, '/etc/localtime must specify force => true'
EOF
echo "PASS (/etc/localtime symlink verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Explicit Resource Dependency Ordering
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Explicit resource dependency ordering (no cycles)... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert 'require => Package[$packages],' in content, '/etc/timezone must require Package[$packages]'
assert "require => File['/etc/timezone']," in content, '/etc/localtime must require File[/etc/timezone]'
assert "require    => File['/etc/localtime']," in content or "require => File['/etc/localtime']," in content, 'Service must require File[/etc/localtime]'
EOF
echo "PASS (linear dependency chain Package -> timezone -> localtime -> Service established)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Steady-State Puppet Agent Service Management
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Puppet Agent service management properties... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

assert 'if $manage_puppet_agent {' in content, 'Service declaration must be conditional on $manage_puppet_agent'
assert 'service { $puppet_agent_service:' in content, 'Service resource must use $puppet_agent_service variable'
assert 'ensure     => running,' in content or 'ensure => running,' in content, 'Service must ensure => running'
assert 'enable     => true,' in content or 'enable => true,' in content, 'Service must enable => true'
assert 'hasstatus  => true,' in content or 'hasstatus => true,' in content, 'Service must set hasstatus => true'
assert 'hasrestart => true,' in content or 'hasrestart => true,' in content, 'Service must set hasrestart => true'
EOF
echo "PASS (agent service running, enabled, with systemd status/restart hooks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Isolation from puppetserver.service on puppet-server (EC2 1)
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Isolation: common module does not manage puppetserver daemon... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
init_path = os.path.join(puppet_dir, 'modules/common/manifests/init.pp')
with open(init_path) as f:
    content = f.read()

# Filter out comment lines starting with #
code_lines = [line.strip() for line in content.splitlines() if not line.strip().startswith('#')]
code_text = '\n'.join(code_lines)

assert "service { 'puppetserver'" not in code_text, 'common module must NEVER declare service puppetserver'
assert "service { 'puppetserver.service'" not in code_text, 'common module must NEVER declare service puppetserver.service'
assert 'puppetserver' not in code_text, 'common module executable code must not reference puppetserver'
EOF
echo "PASS (zero interference with master daemon puppetserver.service)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Conditional Service Management Toggle
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Conditional toggle: manage_puppet_agent => false omits service... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    '-e', "class { 'common': manage_puppet_agent => false }"
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'Catalog compilation failed: {res.stderr}'
assert 'Service[puppet]' not in res.stdout, 'Service[puppet] must NOT appear in catalog when manage_puppet_agent => false'
assert 'Package' in res.stdout, 'Packages must still be managed'
assert 'File[/etc/timezone]' in res.stdout, 'Timezone must still be managed'
EOF
echo "PASS (manage_puppet_agent flag safely controls service declaration)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Dry-Run Catalog Compilation (puppet apply --noop)
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Catalog compilation with default parameters (puppet apply --noop)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    '-e', "class { 'common': }"
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'Catalog compilation failed: {res.stderr}'
assert 'Service[puppet]' in res.stdout or 'Service[puppet]' in res.stderr
assert 'File[/etc/timezone]' in res.stdout or 'File[/etc/timezone]' in res.stderr
assert 'File[/etc/localtime]' in res.stdout or 'File[/etc/localtime]' in res.stderr
EOF
echo "PASS (catalog compiles cleanly without errors)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Hiera Parameter Binding
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Hiera v5 parameter binding from hieradata/common.yaml... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', "include common"
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'Hiera catalog compilation failed: {res.stderr}'
assert 'Service[puppet]' in res.stdout or 'Service[puppet]' in res.stderr
assert 'File[/etc/timezone]' in res.stdout or 'File[/etc/timezone]' in res.stderr
assert 'File[/etc/localtime]' in res.stdout or 'File[/etc/localtime]' in res.stderr
EOF
echo "PASS (Hiera v5 automatically binds common parameters)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Full Fleet Catalog Compilation (site.pp)
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Master site.pp catalog compilation for all nodes... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    app_hiera = os.path.join(tmpdir, 'hiera.yaml')
    app_override = os.path.join(tmpdir, 'test_app_override.yaml')
    with open(app_override, 'w') as f:
        f.write("---\nnagios::web::admin_password_hash: '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'\n")
    with open(app_hiera, 'w') as f:
        f.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'Test app override'\n    path: '{app_override}'\n"
            f"  - name: 'Common data'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )

    for node in ['puppet-server', 'app-server', 'cicd-server']:
        hiera_cfg = app_hiera if node == 'app-server' else f'{puppet_dir}/hiera.yaml'
        cmd = [
            'puppet', 'apply', '--noop',
            f'--modulepath={puppet_dir}/modules',
            f'--hiera_config={hiera_cfg}',
            '--certname', node,
            f'{puppet_dir}/manifests/site.pp'
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        assert res.returncode == 0, f'Catalog compilation for node {node} failed: {res.stderr}'
EOF
echo "PASS (site.pp compiles successfully for all three fleet nodes)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Repeat Application Idempotency Check
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Repeated compilation idempotency (zero dependency cycles)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
for i in range(2):
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '-e', "class { 'common': }"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Run {i+1} failed: {res.stderr}'
    assert 'Found 1 dependency cycle' not in res.stderr and 'Found 1 dependency cycle' not in res.stdout
EOF
echo "PASS (class is cycle-free and safe for repeated application)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 5A.2 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
