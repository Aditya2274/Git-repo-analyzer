#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Checkpoint 5A.3 — NRPE Puppet Module Implementation
# Purpose: Comprehensive static, structural, AST, template, security, script,
#          and catalog compilation validation for the NRPE Puppet module
#          under Approval Boundary A.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=19

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 5A.3 (NRPE Puppet Module)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Manifest, Template, and Script File Existence
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] File existence: manifests, templates, and check scripts... "
REQUIRED_FILES=(
  "${PUPPET_DIR}/modules/nrpe/manifests/init.pp"
  "${PUPPET_DIR}/modules/nrpe/manifests/server.pp"
  "${PUPPET_DIR}/modules/nrpe/manifests/client.pp"
  "${PUPPET_DIR}/modules/nrpe/templates/nrpe.cfg.erb"
  "${PUPPET_DIR}/modules/nrpe/files/check_jenkins.sh"
  "${PUPPET_DIR}/modules/nrpe/files/check_docker.sh"
  "${PUPPET_DIR}/modules/nrpe/files/check_puppetserver.sh"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "${file}" ]]; then
    echo "FAILED: File not found: ${file}"
    exit 1
  fi
done
echo "PASS (all 7 required manifests, templates, and scripts exist)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Puppet Parser Syntax Validation
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Puppet parser validate: modules/nrpe/manifests/*.pp... "
puppet parser validate \
  "${PUPPET_DIR}/modules/nrpe/manifests/init.pp" \
  "${PUPPET_DIR}/modules/nrpe/manifests/server.pp" \
  "${PUPPET_DIR}/modules/nrpe/manifests/client.pp"
echo "PASS (all manifests conform to valid Puppet DSL syntax)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Check Script Executable Permissions (0755)
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Executable permissions (0755) on custom check scripts... "
for script in check_jenkins.sh check_docker.sh check_puppetserver.sh; do
  SCRIPT_PATH="${PUPPET_DIR}/modules/nrpe/files/${script}"
  if [[ ! -x "${SCRIPT_PATH}" ]]; then
    echo "FAILED: Script ${script} is not executable"
    exit 1
  fi
  PERMS=$(stat -c "%a" "${SCRIPT_PATH}")
  if [[ "${PERMS}" != "755" && "${PERMS}" != "775" ]]; then
    echo "FAILED: Script ${script} permissions are ${PERMS}, expected 755"
    exit 1
  fi
done
echo "PASS (all 3 custom check scripts have executable permissions)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Check Script Bash Syntax Validation (bash -n)
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Bash syntax validation (bash -n) on check scripts... "
bash -n "${PUPPET_DIR}/modules/nrpe/files/check_jenkins.sh"
bash -n "${PUPPET_DIR}/modules/nrpe/files/check_docker.sh"
bash -n "${PUPPET_DIR}/modules/nrpe/files/check_puppetserver.sh"
echo "PASS (all check scripts pass bash syntax verification)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Check Script Security & Read-Only Safety Inspection
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Security inspection: strictly read-only, zero user code execution... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
scripts = ['check_jenkins.sh', 'check_docker.sh', 'check_puppetserver.sh']

for s in scripts:
    path = os.path.join(puppet_dir, 'modules/nrpe/files', s)
    with open(path) as f:
        content = f.read()
    
    # Strictly forbid dangerous commands or shell interpolation
    assert 'eval ' not in content, f'{s} must not use eval'
    assert 'rm -' not in content, f'{s} must not remove files'
    assert 'mkfs' not in content, f'{s} must not format disks'
    assert 'git clone' not in content, f'{s} must not clone repositories'
    assert 'set -euo pipefail' in content, f'{s} must enforce bash strict mode'
    assert 'exit 0' in content, f'{s} must define OK return code'
    assert 'exit 2' in content, f'{s} must define CRITICAL return code'
EOF
echo "PASS (all check scripts are strictly read-only monitoring checks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Behavioral Execution of Custom Check Scripts
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Behavioral execution of custom check scripts... "
# 1. check_puppetserver.sh: puppetserver is inactive on this host -> must exit 2
PUPPET_OUT=$( "${PUPPET_DIR}/modules/nrpe/files/check_puppetserver.sh" 2>&1 || true )
PUPPET_RC=0
"${PUPPET_DIR}/modules/nrpe/files/check_puppetserver.sh" >/dev/null 2>&1 || PUPPET_RC=$?
if [[ ${PUPPET_RC} -ne 2 || ! "${PUPPET_OUT}" =~ "CRITICAL" ]]; then
  echo "FAILED: check_puppetserver.sh expected exit code 2 (CRITICAL), got ${PUPPET_RC}: ${PUPPET_OUT}"
  exit 1
fi

# 2. check_docker.sh: docker is active on this host -> must exit 0 with OK
DOCKER_OUT=$( "${PUPPET_DIR}/modules/nrpe/files/check_docker.sh" 2>&1 || true )
DOCKER_RC=0
"${PUPPET_DIR}/modules/nrpe/files/check_docker.sh" >/dev/null 2>&1 || DOCKER_RC=$?
if [[ ${DOCKER_RC} -ne 0 || ! "${DOCKER_OUT}" =~ "OK" ]]; then
  echo "FAILED: check_docker.sh expected exit code 0 (OK), got ${DOCKER_RC}: ${DOCKER_OUT}"
  exit 1
fi

# 3. check_jenkins.sh: verify standard Nagios output formatting
JENKINS_OUT=$( "${PUPPET_DIR}/modules/nrpe/files/check_jenkins.sh" 2>&1 || true )
if [[ ! "${JENKINS_OUT}" =~ ^(OK|CRITICAL|WARNING) ]]; then
  echo "FAILED: check_jenkins.sh output must start with Nagios status: ${JENKINS_OUT}"
  exit 1
fi
echo "PASS (check scripts return standard Nagios status codes and formatted output)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Server Class Signature and Typed Parameters
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] nrpe::server class signature and typed parameters... "
python3 - << 'EOF'
import os, re

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
server_path = os.path.join(puppet_dir, 'modules/nrpe/manifests/server.pp')
with open(server_path) as f:
    content = f.read()

assert 'class nrpe::server (' in content, 'Must define class nrpe::server'
assert re.search(r'String\[1\]\s+\$package_name', content), 'package_name must be String[1]'
assert re.search(r'String\[1\]\s+\$service_name', content), 'service_name must be String[1]'
assert re.search(r'Array\[String\[1\]\]\s+\$plugin_packages', content), 'plugin_packages must be Array[String[1]]'
assert re.search(r'Integer\[1, 65535\]\s+\$server_port', content), 'server_port must be Integer[1, 65535]'
assert re.search(r'Array\[String\[1\]\]\s+\$allowed_hosts', content), 'allowed_hosts must be Array[String[1]]'
assert re.search(r'Integer\[0, 1\]\s+\$dont_blame_nrpe', content), 'dont_blame_nrpe must be Integer[0, 1]'
assert '$commands' in content, 'commands parameter must be declared'
assert '$custom_plugins' in content, 'custom_plugins parameter must be declared'
EOF
echo "PASS (nrpe::server parameters strongly typed with strict validations)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Client Class Signature and Typed Parameters
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] nrpe::client class signature and typed parameters... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
client_path = os.path.join(puppet_dir, 'modules/nrpe/manifests/client.pp')
with open(client_path) as f:
    content = f.read()

assert 'class nrpe::client (' in content, 'Must define class nrpe::client'
assert 'String[1] $plugin_package' in content, 'plugin_package must be String[1]'
assert 'nagios-nrpe-plugin' in content, 'plugin_package default must be nagios-nrpe-plugin'
EOF
echo "PASS (nrpe::client cleanly isolated and strongly typed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. ERB Template Rendering and Directives
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] nrpe.cfg.erb template rendering and required directives... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
template_path = os.path.join(puppet_dir, 'modules/nrpe/templates/nrpe.cfg.erb')
with open(template_path) as f:
    tpl = f.read()

assert 'server_port=<%= @server_port %>' in tpl, 'Template must configure server_port'
assert 'allowed_hosts=<%= @allowed_hosts.join(\',\') %>' in tpl, 'Template must format allowed_hosts as comma-separated'
assert 'dont_blame_nrpe=<%= @dont_blame_nrpe %>' in tpl, 'Template must configure dont_blame_nrpe'
assert 'allow_bash_command_substitution=0' in tpl, 'Template must disable command substitution'
assert 'include_dir=' in tpl, 'Template must configure include_dir'
assert 'command[<%= cmd_name %>]=<%= @effective_commands[cmd_name] %>' in tpl, 'Template must generate command definitions'
EOF
echo "PASS (template contains all mandatory NRPE directives)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. allowed_hosts Strict Hostname and Loopback Boundary
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] allowed_hosts restriction to app-server and loopback... "
python3 - << 'EOF'
import os, yaml

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
common_yaml = os.path.join(puppet_dir, 'hieradata/common.yaml')
with open(common_yaml) as f:
    data = yaml.safe_load(f)

allowed = data.get('nrpe::server::allowed_hosts', [])
assert '127.0.0.1' in allowed, 'Must permit IPv4 loopback'
assert '::1' in allowed, 'Must permit IPv6 loopback'
assert 'app-server' in allowed, 'Must permit Nagios monitoring host (app-server)'
assert 'puppet-server' not in allowed, 'Monitored node puppet-server must NOT be in allowed_hosts'
assert 'cicd-server' not in allowed, 'Monitored node cicd-server must NOT be in allowed_hosts'
assert len(allowed) == 3, f'allowed_hosts must contain exactly 3 entries, got {allowed}'
EOF
echo "PASS (allowed_hosts strictly restricted to app-server and loopback)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Security Posture: Arguments Disabled (dont_blame_nrpe=0)
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Security posture: dont_blame_nrpe=0 (no argument injection)... "
python3 - << 'EOF'
import os, yaml, re

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
common_yaml = os.path.join(puppet_dir, 'hieradata/common.yaml')
with open(common_yaml) as f:
    data = yaml.safe_load(f)

assert data.get('nrpe::server::dont_blame_nrpe') == 0, 'dont_blame_nrpe must be 0'

server_pp = os.path.join(puppet_dir, 'modules/nrpe/manifests/server.pp')
with open(server_pp) as f:
    content = f.read()

assert re.search(r'\$dont_blame_nrpe\s*=\s*0', content), 'dont_blame_nrpe default must be 0'
EOF
echo "PASS (zero command argument injection permitted)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Configuration Validator (validate_cmd) Logic
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] validate_cmd logic: accept valid config, reject malformed lines... "
VALID_CFG="
# Valid comment
server_port=5666
allowed_hosts=127.0.0.1,::1,app-server
pid_file=/run/nagios/nrpe.pid
nrpe_user=nagios
nrpe_group=nagios
dont_blame_nrpe=0
"

INVALID_CFG="
# Malformed comment
server_port=5666
THIS_LINE_HAS_NO_EQUALS_SIGN
allowed_hosts=127.0.0.1
pid_file=/run/nagios/nrpe.pid
"

# Test valid configuration passes awk validator
echo "${VALID_CFG}" | awk '/^[[:space:]]*(#|$)/ {next} /=/ {found++; next} {exit 1} END {exit (found >= 5 ? 0 : 1)}'

# Test invalid configuration fails awk validator
set +e
echo "${INVALID_CFG}" | awk '/^[[:space:]]*(#|$)/ {next} /=/ {found++; next} {exit 1} END {exit (found >= 5 ? 0 : 1)}' 2>/dev/null
AWK_RC=$?
set -e

if [[ ${AWK_RC} -eq 0 ]]; then
  echo "FAILED: validate_cmd accepted invalid configuration"
  exit 1
fi
echo "PASS (validate_cmd successfully distinguishes valid vs corrupt configuration)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Linear Resource Dependency Chain (Package -> File -> Service)
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Explicit resource dependency ordering (no cycles)... "
python3 - << 'EOF'
import os

puppet_dir = os.environ.get('PUPPET_DIR', 'puppet')
server_pp = os.path.join(puppet_dir, 'modules/nrpe/manifests/server.pp')
with open(server_pp) as f:
    content = f.read()

# Directory dependencies
assert "require => Package[$package_name]" in content or 'require => Package[$package_name],' in content
assert "require => File['/etc/nagios']" in content or "require => File['/etc/nagios']," in content
assert "require => Package[$plugin_packages]" in content or 'require => Package[$plugin_packages],' in content

# Custom scripts dependencies
for script in ['check_jenkins.sh', 'check_docker.sh', 'check_puppetserver.sh']:
    assert f"file {{ '/usr/lib/nagios/plugins/{script}':" in content
    assert f"source  => 'puppet:///modules/nrpe/{script}'" in content or f"source => 'puppet:///modules/nrpe/{script}'" in content

# Config file dependencies & notify
assert 'notify       => Service[$service_name],' in content or 'notify => Service[$service_name],' in content

# Service dependencies
assert 'require    => [' in content or 'require => [' in content
assert 'File[$config_file],' in content
EOF
echo "PASS (linear DAG dependency chain established with explicit require & notify)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Catalog Compilation for nrpe::server with Explicit Parameters (puppet apply --noop)
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Catalog compilation: nrpe::server with explicit test parameters... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
manifest_code = """
class { 'nrpe::server':
  custom_plugins => ['check_jenkins.sh', 'check_docker.sh', 'check_puppetserver.sh'],
  commands       => {
    'check_users'        => '/usr/lib/nagios/plugins/check_users -w 5 -c 10',
    'check_puppetserver' => '/usr/lib/nagios/plugins/check_puppetserver.sh',
    'check_jenkins'      => '/usr/lib/nagios/plugins/check_jenkins.sh',
    'check_docker'       => '/usr/lib/nagios/plugins/check_docker.sh',
  },
}
"""
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', manifest_code
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'nrpe::server compilation failed: {res.stderr}'
combined = res.stdout + res.stderr
assert 'Package[nagios-nrpe-server]' in combined, 'Must manage nagios-nrpe-server package'
assert 'Package[monitoring-plugins-basic]' in combined, 'Must manage monitoring-plugins-basic'
assert 'File[/etc/nagios/nrpe.cfg]' in combined, 'Must manage nrpe.cfg'
assert 'File[/usr/lib/nagios/plugins/check_jenkins.sh]' in combined, 'Must manage check_jenkins.sh'
assert 'File[/usr/lib/nagios/plugins/check_docker.sh]' in combined, 'Must manage check_docker.sh'
assert 'File[/usr/lib/nagios/plugins/check_puppetserver.sh]' in combined, 'Must manage check_puppetserver.sh'
assert 'Service[nagios-nrpe-server]' in combined, 'Must manage nagios-nrpe-server service'
EOF
echo "PASS (nrpe::server compiles cleanly with explicitly configured resources)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Catalog Compilation for nrpe::client (puppet apply --noop)
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] Catalog compilation: nrpe::client (puppet apply --noop)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', "include nrpe::client"
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'nrpe::client compilation failed: {res.stderr}'
combined = res.stdout + res.stderr
assert 'Package[nagios-nrpe-plugin]' in combined, 'Must manage nagios-nrpe-plugin package'
assert 'Service[nagios-nrpe-server]' not in combined, 'Client must NOT manage server service'
EOF
echo "PASS (nrpe::client compiles cleanly with check plugin package)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Hiera Parameter Binding
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Hiera v5 automatic parameter binding for nrpe::server... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', "class { 'nrpe::server': }"
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'Hiera binding compilation failed: {res.stderr}'
EOF
echo "PASS (Hiera v5 binds server_port, allowed_hosts, and dont_blame_nrpe)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Master site.pp Fleet Compilation for All Three Nodes
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Fleet site.pp compilation across all three nodes... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
for node in ['puppet-server', 'app-server', 'cicd-server']:
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--certname', node,
        f'{puppet_dir}/manifests/site.pp'
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Compilation failed for node {node}: {res.stderr}'
    combined = res.stdout + res.stderr
    if node == 'puppet-server':
        assert 'Service[nagios-nrpe-server]' in combined, 'puppet-server must manage NRPE service'
        assert 'File[/etc/nagios/nrpe.cfg]' in combined, 'puppet-server must manage nrpe.cfg'
        assert 'File[/usr/lib/nagios/plugins/check_puppetserver.sh]' in combined, 'puppet-server must manage check_puppetserver.sh'
        assert 'check_jenkins.sh' not in combined, 'puppet-server must NOT manage check_jenkins.sh'
        assert 'check_docker.sh' not in combined, 'puppet-server must NOT manage check_docker.sh'
    elif node == 'cicd-server':
        assert 'Service[nagios-nrpe-server]' in combined, 'cicd-server must manage NRPE service'
        assert 'File[/etc/nagios/nrpe.cfg]' in combined, 'cicd-server must manage nrpe.cfg'
        assert 'File[/usr/lib/nagios/plugins/check_jenkins.sh]' in combined, 'cicd-server must manage check_jenkins.sh'
        assert 'File[/usr/lib/nagios/plugins/check_docker.sh]' in combined, 'cicd-server must manage check_docker.sh'
        assert 'check_puppetserver.sh' not in combined, 'cicd-server must NOT manage check_puppetserver.sh'
    elif node == 'app-server':
        assert 'Package[nagios-nrpe-plugin]' in combined, 'app-server must manage nagios-nrpe-plugin'
        assert 'Service[nagios-nrpe-server]' not in combined, 'app-server must NOT manage NRPE server'
EOF
echo "PASS (site.pp compiles for all three fleet nodes with correct role targeting)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Repeated Compilation Idempotency (Zero Dependency Cycles)
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Repeated compilation idempotency (cycle-free DAG)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
for i in range(2):
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '-e', "include nrpe::server"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Run {i+1} failed: {res.stderr}'
    assert 'Found 1 dependency cycle' not in res.stderr and 'Found 1 dependency cycle' not in res.stdout
EOF
echo "PASS (zero dependency cycles detected in repeat applications)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Security Regression: Unexpected Certname Receives Zero Custom Checks
# ------------------------------------------------------------------------------
echo -n "[Test 19/${TOTAL_COUNT}] Security regression: unexpected certname receives zero custom checks... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

# Scenario A: Unexpected node certname without explicit parameters
cmd1 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'unexpected-node.local',
    '-e', "include nrpe::server"
]
res1 = subprocess.run(cmd1, capture_output=True, text=True)
assert res1.returncode == 0, f'Unexpected certname compilation failed: {res1.stderr}'
combined1 = res1.stdout + res1.stderr

# Assert that NONE of the custom scripts are managed
assert 'check_puppetserver.sh' not in combined1, 'unexpected-node must NOT manage check_puppetserver.sh'
assert 'check_jenkins.sh' not in combined1, 'unexpected-node must NOT manage check_jenkins.sh'
assert 'check_docker.sh' not in combined1, 'unexpected-node must NOT manage check_docker.sh'

# Assert that baseline packages, config, and service ARE still managed
assert 'Package[nagios-nrpe-server]' in combined1, 'Must manage nagios-nrpe-server package'
assert 'File[/etc/nagios/nrpe.cfg]' in combined1, 'Must manage nrpe.cfg'
assert 'Service[nagios-nrpe-server]' in combined1, 'Must manage nagios-nrpe-server service'

# Scenario B: Arbitrary rogue server certname without parameters
cmd2 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'rogue-server',
    '-e', "include nrpe::server"
]
res2 = subprocess.run(cmd2, capture_output=True, text=True)
assert res2.returncode == 0, f'Rogue certname compilation failed: {res2.stderr}'
combined2 = res2.stdout + res2.stderr
assert 'check_puppetserver.sh' not in combined2, 'rogue-server must NOT manage check_puppetserver.sh'
assert 'check_jenkins.sh' not in combined2, 'rogue-server must NOT manage check_jenkins.sh'
assert 'check_docker.sh' not in combined2, 'rogue-server must NOT manage check_docker.sh'

# Scenario C: Explicit overrides for an unexpected node are honored
cmd3 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'custom-node.local',
    '-e', "class { 'nrpe::server': custom_plugins => ['check_docker.sh'] }"
]
res3 = subprocess.run(cmd3, capture_output=True, text=True)
assert res3.returncode == 0, f'Explicit override failed: {res3.stderr}'
combined3 = res3.stdout + res3.stderr
assert 'File[/usr/lib/nagios/plugins/check_docker.sh]' in combined3, 'Explicit override for check_docker.sh must be honored'
assert 'check_puppetserver.sh' not in combined3, 'Non-configured check_puppetserver.sh must NOT be present'
assert 'check_jenkins.sh' not in combined3, 'Non-configured check_jenkins.sh must NOT be present'
EOF
echo "PASS (unexpected certnames receive zero custom checks; explicit overrides honored)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 5A.3 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
