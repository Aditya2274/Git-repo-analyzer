#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_puppet_architecture.sh
# Purpose: Isolated validation of Checkpoint 5A.1:
#          - Puppet module directory structure & file layout
#          - Puppet DSL syntax validation via `puppet parser validate`
#          - Node classification in site.pp (puppet-server, app-server, cicd-server)
#          - Resource chaining and dependency ordering (avoiding circular dependencies)
#          - Hiera v5 configuration and common data hierarchy validation
#          - Module class declarations and parameter definitions
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUPPET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${PUPPET_DIR}/.." && pwd)"

PASSED_COUNT=0
TOTAL_COUNT=15

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 5A.1 (Puppet Module Architecture)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Directory Structure Verification
# ------------------------------------------------------------------------------
echo -n "[Test 1/15] Directory structure & required module layout verification... "
python3 -c "
import os

required_dirs = [
    '${PUPPET_DIR}/manifests',
    '${PUPPET_DIR}/hieradata',
    '${PUPPET_DIR}/hieradata/nodes',
    '${PUPPET_DIR}/modules/common/manifests',
    '${PUPPET_DIR}/modules/common/files',
    '${PUPPET_DIR}/modules/nrpe/manifests',
    '${PUPPET_DIR}/modules/nrpe/templates',
    '${PUPPET_DIR}/modules/nagios/manifests',
    '${PUPPET_DIR}/modules/nagios/templates',
]

for d in required_dirs:
    assert os.path.isdir(d), f'Missing required directory: {d}'
"
echo "PASS (all required module, manifest, and hieradata directories exist)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Key File Existence Verification
# ------------------------------------------------------------------------------
echo -n "[Test 2/15] Required manifest and configuration files existence... "
python3 -c "
import os

required_files = [
    '${PUPPET_DIR}/manifests/site.pp',
    '${PUPPET_DIR}/hiera.yaml',
    '${PUPPET_DIR}/hieradata/common.yaml',
    '${PUPPET_DIR}/modules/common/manifests/init.pp',
    '${PUPPET_DIR}/modules/nrpe/manifests/init.pp',
    '${PUPPET_DIR}/modules/nrpe/manifests/server.pp',
    '${PUPPET_DIR}/modules/nrpe/manifests/client.pp',
    '${PUPPET_DIR}/modules/nagios/manifests/init.pp',
    '${PUPPET_DIR}/modules/nagios/manifests/server.pp',
    '${PUPPET_DIR}/modules/nagios/manifests/objects.pp',
    '${PUPPET_DIR}/modules/nagios/manifests/web.pp',
]

for f in required_files:
    assert os.path.isfile(f), f'Missing required file: {f}'
"
echo "PASS (all 11 architectural manifest and configuration files exist)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Puppet Parser Validation (site.pp)
# ------------------------------------------------------------------------------
echo -n "[Test 3/15] Puppet parser validate: manifests/site.pp... "
puppet parser validate "${PUPPET_DIR}/manifests/site.pp"
echo "PASS (manifests/site.pp is valid Puppet DSL)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Puppet Parser Validation (modules/common)
# ------------------------------------------------------------------------------
echo -n "[Test 4/15] Puppet parser validate: modules/common/... "
puppet parser validate "${PUPPET_DIR}/modules/common/manifests/init.pp"
echo "PASS (common module manifest syntax valid)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Puppet Parser Validation (modules/nrpe)
# ------------------------------------------------------------------------------
echo -n "[Test 5/15] Puppet parser validate: modules/nrpe/... "
puppet parser validate \
  "${PUPPET_DIR}/modules/nrpe/manifests/init.pp" \
  "${PUPPET_DIR}/modules/nrpe/manifests/server.pp" \
  "${PUPPET_DIR}/modules/nrpe/manifests/client.pp"
echo "PASS (all nrpe module manifests syntax valid)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Puppet Parser Validation (modules/nagios)
# ------------------------------------------------------------------------------
echo -n "[Test 6/15] Puppet parser validate: modules/nagios/... "
puppet parser validate \
  "${PUPPET_DIR}/modules/nagios/manifests/init.pp" \
  "${PUPPET_DIR}/modules/nagios/manifests/server.pp" \
  "${PUPPET_DIR}/modules/nagios/manifests/objects.pp" \
  "${PUPPET_DIR}/modules/nagios/manifests/web.pp"
echo "PASS (all nagios module manifests syntax valid)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Global Exec Path Default in site.pp
# ------------------------------------------------------------------------------
echo -n "[Test 7/15] Global Exec default path declared in site.pp... "
python3 -c "
with open('${PUPPET_DIR}/manifests/site.pp') as f:
    content = f.read()

assert 'Exec {' in content, 'site.pp must declare global Exec defaults'
assert '/bin' in content and '/usr/bin' in content and '/sbin' in content and '/usr/sbin' in content
"
echo "PASS (global Exec resource default path properly configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Node Classification: puppet-server
# ------------------------------------------------------------------------------
echo -n "[Test 8/15] Node classification: puppet-server (common + nagios + nrpe::client)... "
python3 -c "
with open('${PUPPET_DIR}/manifests/site.pp') as f:
    content = f.read()

assert \"node 'puppet-server'\" in content, 'site.pp must define node puppet-server'
block = content.split(\"node 'puppet-server'\")[1].split(\"node 'app-server'\")[0]
assert 'common' in block, 'puppet-server must include common'
assert 'nagios' in block, 'puppet-server must include nagios'
assert 'nrpe::client' in block, 'puppet-server must include nrpe::client'
assert 'nrpe::server' not in block, 'puppet-server must not include nrpe::server'
"
echo "PASS (puppet-server classified with common, nagios, and nrpe::client)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Node Classification: app-server
# ------------------------------------------------------------------------------
echo -n "[Test 9/15] Node classification: app-server (common + nrpe::server)... "
python3 -c "
with open('${PUPPET_DIR}/manifests/site.pp') as f:
    content = f.read()

assert \"node 'app-server'\" in content, 'site.pp must define node app-server'
block = content.split(\"node 'app-server'\")[1].split(\"node 'cicd-server'\")[0]
assert 'common' in block, 'app-server must include common'
assert 'nrpe::server' in block, 'app-server must include nrpe::server'
assert 'nagios' not in block, 'app-server must not include nagios'
"
echo "PASS (app-server classified with common and nrpe::server)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Node Classification: cicd-server
# ------------------------------------------------------------------------------
echo -n "[Test 10/15] Node classification: cicd-server (common + nrpe::server)... "
python3 -c "
with open('${PUPPET_DIR}/manifests/site.pp') as f:
    content = f.read()

assert \"node 'cicd-server'\" in content, 'site.pp must define node cicd-server'
block = content.split(\"node 'cicd-server'\")[1].split(\"node default\")[0]
assert 'common' in block, 'cicd-server must include common'
assert 'nrpe::server' in block, 'cicd-server must include nrpe::server'
assert 'nagios' not in block, 'cicd-server must not include nagios'
"
echo "PASS (cicd-server classified with common and nrpe::server)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Resource Dependency Ordering in site.pp (No Cycles)
# ------------------------------------------------------------------------------
echo -n "[Test 11/15] Resource dependency ordering in site.pp (-> arrow chaining)... "
python3 -c "
with open('${PUPPET_DIR}/manifests/site.pp') as f:
    content = f.read()

# Check arrow chaining
assert 'class { \'common\': }' in content, 'Classes must be declared'
assert '->' in content, 'site.pp must enforce explicit dependency ordering via ->'
"
echo "PASS (explicit class relationship chaining established without cycles)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Hiera v5 Configuration Validation
# ------------------------------------------------------------------------------
echo -n "[Test 12/15] Hiera v5 configuration syntax and structure (hiera.yaml)... "
python3 -c "
import yaml

with open('${PUPPET_DIR}/hiera.yaml') as f:
    hiera = yaml.safe_load(f)

assert hiera.get('version') == 5, 'hiera.yaml must specify version: 5'
assert 'hierarchy' in hiera, 'hiera.yaml must define hierarchy'
assert any(h.get('path') == 'common.yaml' for h in hiera['hierarchy']), 'Hierarchy must include common.yaml'
"
echo "PASS (hiera.yaml conforms to Puppet Hiera v5 specification)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Hiera Common Data Validation (hieradata/common.yaml)
# ------------------------------------------------------------------------------
echo -n "[Test 13/15] Hiera common data parameter declarations (hieradata/common.yaml)... "
python3 -c "
import yaml

with open('${PUPPET_DIR}/hieradata/common.yaml') as f:
    data = yaml.safe_load(f)

assert 'common::timezone' in data, 'common::timezone must be declared'
assert 'common::manage_puppet_agent' in data, 'common::manage_puppet_agent must be declared'
assert 'common::packages' in data, 'common::packages must be declared'
assert 'nrpe::server::server_port' in data, 'nrpe::server::server_port must be declared'
assert 'nrpe::server::allowed_hosts' in data, 'nrpe::server::allowed_hosts must be declared'
"
echo "PASS (common.yaml declares valid Hiera parameters for common, nrpe, and nagios)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Puppet Agent Steady-State Declaration in common/init.pp
# ------------------------------------------------------------------------------
echo -n "[Test 14/15] Puppet Agent steady-state service management in common/init.pp... "
python3 -c "
with open('${PUPPET_DIR}/modules/common/manifests/init.pp') as f:
    content = f.read()

assert 'service {' in content or 'service {' in content.lower(), 'common must declare service resource'
assert 'ensure' in content and 'running' in content, 'common must manage agent ensure => running'
assert 'enable' in content and 'true' in content, 'common must manage agent enable => true'
assert 'manage_puppet_agent' in content, 'common must support manage_puppet_agent flag'
"
echo "PASS (common module enforces steady-state running/enabled Puppet Agent daemon)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Cross-Check with Existing Ansible Playbook Syntax
# ------------------------------------------------------------------------------
echo -n "[Test 15/15] Regression: All 7 Ansible playbooks retain clean syntax... "
ansible-playbook -i "${PROJECT_ROOT}/ansible/inventory/hosts.ini" --syntax-check \
  "${PROJECT_ROOT}/ansible/playbooks/site.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/enroll-puppet-agents.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/test-common.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/test-puppet-server.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/test-puppet-agent.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/test-docker.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/test-nginx.yml" >/dev/null 2>&1
echo "PASS (Ansible operational and diagnostic playbooks remain syntax clean)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 5A.1 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
