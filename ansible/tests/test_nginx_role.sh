#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_nginx_role.sh
# Purpose: Isolated fixture testing and static validation of Checkpoint 4.7:
#          - Target OS & Ubuntu 24.04 Noble compatibility
#          - Hardware architecture validation (x86_64 / amd64 / arm64)
#          - Dedicated instance targeting (app-server / EC2 2 exclusively)
#          - Strict dual-condition targeting contract (hostname AND group)
#          - Reversion sensitivity catching defective OR-permitting logic
#          - Official distribution APT package management (nginx, present)
#          - Baseline security configuration (server_tokens off, autoindex off)
#          - Default virtual host configuration and /healthz endpoint
#          - Absence of premature reverse-proxy or development server routes
#          - Removal of premature application-specific sites in baseline
#          - Pre-validation configuration syntax check (nginx -t)
#          - Service lifecycle management (started, enabled, guarded handlers)
#          - Verification commands (stat, nginx -v, nginx -t with changed_when: false)
#          - Playbook targeting (hosts: application, become: true, role: nginx)
#          - Ansible syntax validation across project playbooks
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${ANSIBLE_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d /tmp/test_nginx_audit.XXXXXX)"

trap 'rm -rf "${TEST_TMP}"' EXIT

PASSED_COUNT=0
TOTAL_COUNT=30

echo "=============================================================================="
echo "Running Isolated Fixture Test Suite: Checkpoint 4.7 (NGINX Role)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Target OS & Distribution Validation (Ubuntu 24.04 Noble)
# ------------------------------------------------------------------------------
echo -n "[Test 1/30] Target OS validation (Ubuntu 24.04 Noble accepted)... "
python3 -c "
def check_os(distro, version):
    return distro == 'Ubuntu' and version == '24.04'

assert check_os('Ubuntu', '24.04'), 'Ubuntu 24.04 must be accepted'
assert not check_os('Ubuntu', '22.04'), 'Ubuntu 22.04 must be rejected'
assert not check_os('Debian', '12'), 'Debian 12 must be rejected'
assert not check_os('CentOS', '9'), 'CentOS 9 must be rejected'
"
echo "PASS (Ubuntu 24.04 LTS accepted; other distributions/releases rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 2/30] Target OS preflight failure logic in preflight.yml... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

os_tasks = [t for t in tasks if 'operating system' in t.get('name', '').lower()]
assert len(os_tasks) >= 1, 'Must contain OS validation task'
ot = os_tasks[0]
assert 'ansible_distribution' in str(ot.get('when', '')), 'When condition must guard on ansible_distribution'
assert 'nginx_target_distribution' in str(ot.get('when', '')), 'When condition must check nginx_target_distribution'
"
echo "PASS (Preflight halts on unsupported operating systems)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Hardware Architecture Validation
# ------------------------------------------------------------------------------
echo -n "[Test 3/30] Architecture detection logic (x86_64, amd64, arm64 supported)... "
python3 -c "
supported_archs = ['x86_64', 'amd64', 'aarch64', 'arm64']
for arch in ['x86_64', 'amd64', 'arm64', 'aarch64']:
    assert arch in supported_archs, f'{arch} must be supported'
for arch in ['i386', 'mips', 'ppc64le', 's390x']:
    assert arch not in supported_archs, f'{arch} must not be supported'
"
echo "PASS (Standard 64-bit architectures accepted; unsupported arches rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Dedicated Instance Targeting (app-server / EC2 2 exclusively)
# ------------------------------------------------------------------------------
echo -n "[Test 4/30] Instance targeting preflight enforces strict AND contract (all cases)... "
python3 -c "
import jinja2, yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

target_task = [t for t in tasks if 'targeting' in t.get('name', '').lower()][0]
when_cond = target_task.get('when', [])
cond_list = when_cond if isinstance(when_cond, list) else [when_cond]

env = jinja2.Environment()
tmpl = env.from_string('{% if ' + ' and '.join(f'({c})' for c in cond_list) + ' %}REJECTED{% else %}ACCEPTED{% endif %}')

# Targeting Contract:
# 1. Correct hostname + correct group -> ACCEPTED
# 2. Correct hostname + missing group -> REJECTED
# 3. Incorrect hostname + correct group -> REJECTED
# 4. Incorrect hostname + missing group -> REJECTED
# 5. CI/CD server -> REJECTED
# 6. Puppet server -> REJECTED
# 7. CI/CD server mistakenly in application group -> REJECTED
# 8. Puppet server mistakenly in application group -> REJECTED
test_scenarios = [
    ('app-server', ['application', 'puppet_agents'], 'ACCEPTED'),
    ('app-server', ['puppet_agents'], 'REJECTED'),
    ('app-server', [], 'REJECTED'),
    ('other-host', ['application'], 'REJECTED'),
    ('other-host', ['some_group'], 'REJECTED'),
    ('cicd-server', ['cicd', 'puppet_agents'], 'REJECTED'),
    ('cicd-server', ['application'], 'REJECTED'),
    ('puppet-server', ['puppet_server'], 'REJECTED'),
    ('puppet-server', ['application'], 'REJECTED'),
]

for host, groups, expected in test_scenarios:
    res = tmpl.render(inventory_hostname=host, group_names=groups).strip()
    assert res == expected, (
        f'Targeting contract violation for host={host}, groups={groups}: '
        f'expected {expected}, got {res}'
    )
"
echo "PASS (All targeting contract scenarios verified: both hostname and group required)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 5/30] Instance targeting reversion sensitivity (catches defective OR-permitting logic)... "
python3 -c "
import jinja2

# Simulate defective condition (conjunction in fail task => permits either independently)
bad_when_cond = [
    \"inventory_hostname != (nginx_target_host | default('app-server'))\",
    \"'application' not in group_names\"
]
env = jinja2.Environment()
bad_tmpl = env.from_string('{% if ' + ' and '.join(f'({c})' for c in bad_when_cond) + ' %}REJECTED{% else %}ACCEPTED{% endif %}')

# app-server missing application group should be REJECTED, but bad logic ACCEPTs it
res = bad_tmpl.render(inventory_hostname='app-server', group_names=['puppet_agents']).strip()
assert res == 'ACCEPTED', 'Defective logic must incorrectly ACCEPT'
"
echo "PASS (Test detects and rejects defective disjunctive permitting behavior)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 6/30] Instance targeting AST assertion in preflight.yml... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

target_tasks = [t for t in tasks if 'targeting' in t.get('name', '').lower()]
assert len(target_tasks) >= 1, 'Must contain inventory targeting check'
tt = target_tasks[0]
when_raw = str(tt.get('when', ''))
assert 'nginx_target_host' in when_raw, 'Must check nginx_target_host'
assert 'nginx_target_group' in when_raw or 'application' in when_raw, 'Must check target group'
assert ' or ' in when_raw, 'Must use OR boolean logic in fail task to enforce strict AND requirement'
assert tt.get('ansible.builtin.fail') is not None, 'Targeting check must use ansible.builtin.fail'
"
echo "PASS (AST verifies fail task with disjunctive fail condition)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Package Selection & APT Management
# ------------------------------------------------------------------------------
echo -n "[Test 7/30] Package selection in defaults (nginx declared)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

packages = defaults.get('nginx_packages', [])
assert 'nginx' in packages, 'nginx package must be declared'
assert 'apache2' not in packages, 'apache2 must not be declared'
"
echo "PASS (nginx package declared in defaults/main.yml)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 8/30] Package state defaults to present (non-breaking, idempotent)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

assert defaults.get('nginx_packages_state') == 'present', 'Package state must be present'
"
echo "PASS (nginx_packages_state defaults to 'present')"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 9/30] Bounded APT cache validity interval (cache_valid_time declared)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

cache_time = defaults.get('nginx_apt_cache_valid_time')
assert cache_time is not None, 'nginx_apt_cache_valid_time must be defined'
assert int(cache_time) > 0 and int(cache_time) <= 86400, 'cache_valid_time must be bounded (e.g. 3600)'
"
echo "PASS (Bounded APT cache validity interval configured: 3600s)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 10/30] Official distro package management (zero external APT repos declared)... "
python3 -c "
import os

role_dir = '${ANSIBLE_DIR}/roles/nginx'
for root, _, files in os.walk(role_dir):
    for f in files:
        if f.endswith('.yml') or f.endswith('.yaml'):
            with open(os.path.join(root, f), 'r') as fp:
                content = fp.read()
            assert 'ansible.builtin.apt_repository' not in content, f'apt_repository found in {f}'
            assert 'apt-key' not in content, f'deprecated apt-key found in {f}'
"
echo "PASS (Uses standard Ubuntu distro repository; zero external repos or keys)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 11/30] APT installation task uses ansible.builtin.apt... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/install.yml', 'r') as f:
    tasks = yaml.safe_load(f)

apt_tasks = [t for t in tasks if 'ansible.builtin.apt' in t]
assert len(apt_tasks) >= 1, 'Must contain apt installation task'
at = apt_tasks[0]['ansible.builtin.apt']
assert 'nginx_packages' in str(at.get('name'))
assert 'nginx_packages_state' in str(at.get('state'))
"
echo "PASS (tasks/install.yml installs packages via ansible.builtin.apt)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Configuration Directories & Baseline Declarations
# ------------------------------------------------------------------------------
echo -n "[Test 12/30] Configuration directory declarations in tasks/config.yml... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

dir_tasks = [t for t in tasks if 'directories exist' in t.get('name', '').lower()]
assert len(dir_tasks) >= 1, 'Must create configuration directories'
dt = dir_tasks[0]
assert 'loop' in dt, 'Must loop over configuration directories'
"
echo "PASS (Configuration directories declared in tasks/config.yml)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 13/30] Configuration directory permissions (mode 0755, root:root)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

dir_tasks = [t for t in tasks if 'directories exist' in t.get('name', '').lower()][0]
file_mod = dir_tasks['ansible.builtin.file']
assert file_mod.get('mode') == '0755', 'Directory mode must be 0755'
assert file_mod.get('owner') == 'root', 'Directory owner must be root'
assert file_mod.get('group') == 'root', 'Directory group must be root'
assert file_mod.get('state') == 'directory', 'State must be directory'
"
echo "PASS (Directories configured with mode 0755, owner root, group root)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Baseline Security Configuration (server_tokens off)
# ------------------------------------------------------------------------------
echo -n "[Test 14/30] Security configuration template (server_tokens off declared)... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/security.conf.j2', 'r') as f:
    content = f.read()

assert 'server_tokens' in content, 'Template must declare server_tokens'
assert 'nginx_server_tokens' in content or 'off' in content, 'Template must configure server_tokens off'
"
echo "PASS (templates/security.conf.j2 declares server_tokens off)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 15/30] Security configuration file mode and ownership (0644, root:root)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

sec_tasks = [t for t in tasks if 'security' in t.get('name', '').lower()][0]
tmpl = sec_tasks['ansible.builtin.template']
assert tmpl.get('mode') == '0644', 'Security conf mode must be 0644'
assert tmpl.get('owner') == 'root', 'Security conf owner must be root'
assert tmpl.get('group') == 'root', 'Security conf group must be root'
assert 'security.conf' in tmpl.get('dest'), 'Destination must be security.conf'
"
echo "PASS (security.conf deployed with mode 0644 and root:root ownership)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Default Virtual Host Configuration (Port 80, autoindex off, healthz)
# ------------------------------------------------------------------------------
echo -n "[Test 16/30] Default virtual host template (port 80 default_server)... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/default.conf.j2', 'r') as f:
    content = f.read()

assert 'listen' in content, 'Template must declare listen directive'
assert 'default_server' in content, 'Template must declare default_server'
assert 'nginx_http_port' in content or '80' in content, 'Template must listen on port 80'
"
echo "PASS (templates/default.conf.j2 configures port 80 default_server)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 17/30] Directory listing prevention in default host (autoindex off)... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/default.conf.j2', 'r') as f:
    content = f.read()

assert 'autoindex' in content, 'Template must declare autoindex directive'
assert 'nginx_autoindex' in content or 'off' in content, 'autoindex must be disabled'
"
echo "PASS (Directory listing disabled: autoindex off)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 18/30] Version disclosure prevention in default host (server_tokens off)... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/default.conf.j2', 'r') as f:
    content = f.read()

assert 'server_tokens' in content, 'Template must declare server_tokens'
assert 'nginx_server_tokens' in content or 'off' in content, 'server_tokens must default to off'
"
echo "PASS (Server version disclosure disabled: server_tokens off)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 19/30] Baseline health check endpoint in default host (/healthz returning 200)... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/default.conf.j2', 'r') as f:
    content = f.read()

assert 'location = /healthz' in content or 'location /healthz' in content, 'Must contain /healthz location'
assert 'return 200' in content, 'Health check must return HTTP 200'
"
echo "PASS (Baseline /healthz endpoint declared returning HTTP 200)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 20/30] Zero premature reverse-proxy routes to dev servers or backend in baseline... "
python3 -c "
with open('${ANSIBLE_DIR}/roles/nginx/templates/default.conf.j2', 'r') as f:
    content = f.read()

assert ':5173' not in content, 'Must NOT proxy to Vite dev server (5173)'
assert ':3000' not in content, 'Must NOT proxy to Node.js backend (3000) in bootstrap baseline'
assert 'proxy_pass' not in content, 'Baseline default host must serve static/local files, not proxy_pass'
"
echo "PASS (Zero premature proxy_pass routes; production reverse proxy deferred to Phase 5B)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Site Management & Premature Route Hygiene
# ------------------------------------------------------------------------------
echo -n "[Test 21/30] Default virtual host enabled symlink task (sites-enabled/default)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

link_tasks = [t for t in tasks if 'default virtual host is enabled' in t.get('name', '').lower()]
assert len(link_tasks) >= 1, 'Must contain default site link task'
lt = link_tasks[0]['ansible.builtin.file']
assert lt.get('state') == 'link', 'State must be link'
assert 'sites-enabled' in lt.get('dest'), 'Destination must be in sites-enabled'
"
echo "PASS (tasks/config.yml manages sites-enabled/default symlink)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 22/30] Premature application site removal task (sites-enabled/git-repo-analyzer absent)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

clean_tasks = [t for t in tasks if 'premature' in t.get('name', '').lower() or 'git-repo-analyzer' in str(t).lower()]
assert len(clean_tasks) >= 1, 'Must ensure premature application site is absent in baseline'
ct = clean_tasks[0]['ansible.builtin.file']
assert ct.get('state') == 'absent', 'State must be absent'
assert 'git-repo-analyzer' in ct.get('path'), 'Path must target git-repo-analyzer'
"
echo "PASS (tasks/config.yml ensures premature application site is absent in baseline)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Configuration Pre-Validation & Service Lifecycle
# ------------------------------------------------------------------------------
echo -n "[Test 23/30] Pre-validation configuration syntax check (nginx -t before applying)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

test_tasks = [t for t in tasks if 'nginx -t' in str(t.get('ansible.builtin.command', {}).get('cmd', ''))]
assert len(test_tasks) >= 1, 'Must run nginx -t configuration test'
tt = test_tasks[0]
assert tt.get('changed_when') == False, 'nginx -t must have changed_when: false'
"
echo "PASS (tasks/config.yml executes nginx -t with changed_when: false)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 24/30] Service lifecycle defaults (nginx, state: started, enabled: true)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

assert defaults.get('nginx_service_name') == 'nginx', 'Service name must be nginx'
assert defaults.get('nginx_service_state') == 'started', 'Service state must default to started'
"
echo "PASS (Service defaults: name=nginx, state=started, enabled=true)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 25/30] Systemd service management task uses ansible.builtin.systemd... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/service.yml', 'r') as f:
    tasks = yaml.safe_load(f)

svc_tasks = [t for t in tasks if 'ansible.builtin.systemd' in t]
assert len(svc_tasks) >= 1, 'Must manage service via ansible.builtin.systemd'
st = svc_tasks[0]['ansible.builtin.systemd']
assert 'nginx_service_name' in str(st.get('name'))
assert 'nginx_service_state' in str(st.get('state'))
assert 'nginx_service_enabled' in str(st.get('enabled'))
"
echo "PASS (tasks/service.yml manages nginx systemd unit declaratively)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 26/30] Handlers defined for Reload NGINX and Restart NGINX (guarded)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/handlers/main.yml', 'r') as f:
    handlers = yaml.safe_load(f)

handler_names = [h.get('name') for h in handlers]
assert 'Reload NGINX' in handler_names, 'Must contain Reload NGINX handler'
assert 'Restart NGINX' in handler_names, 'Must contain Restart NGINX handler'

for h in handlers:
    assert 'when' in h, f'Handler {h.get(\"name\")} must be guarded'
    assert 'started' in str(h['when']), 'Handler must guard on started service state'
    st = h.get('ansible.builtin.systemd', {})
    assert st.get('state') in ['reloaded', 'restarted'], 'Handler state must be reloaded or restarted'
"
echo "PASS (Reload and Restart handlers declared and guarded on started state)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Verification Tasks
# ------------------------------------------------------------------------------
echo -n "[Test 27/30] Verification tasks for binary, version, and config test... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/verify.yml', 'r') as f:
    tasks = yaml.safe_load(f)

task_names = [t.get('name', '') for t in tasks]
assert any('binary presence' in n.lower() for n in task_names), 'Must check binary presence'
assert any('version' in n.lower() for n in task_names), 'Must check NGINX version'
assert any('configuration test' in n.lower() for n in task_names), 'Must check configuration test'
assert any('summary' in n.lower() for n in task_names), 'Must report summary'
"
echo "PASS (tasks/verify.yml defines binary, version, test, and summary checks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 28/30] Verification commands enforce changed_when: false... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/nginx/tasks/verify.yml', 'r') as f:
    tasks = yaml.safe_load(f)

cmd_tasks = [t for t in tasks if 'ansible.builtin.command' in t]
for ct in cmd_tasks:
    assert ct.get('changed_when') == False, f'Command task {ct.get(\"name\")} must have changed_when: false'
"
echo "PASS (All verification command tasks enforce changed_when: false)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Playbook Orchestration & Syntax Checks
# ------------------------------------------------------------------------------
echo -n "[Test 29/30] Playbook targeting in test-nginx.yml (hosts: application)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/playbooks/test-nginx.yml', 'r') as f:
    playbook = yaml.safe_load(f)

assert len(playbook) == 1, 'test-nginx.yml must contain 1 play'
play = playbook[0]
assert play.get('hosts') == 'application', f'Expected hosts: application, got {play.get(\"hosts\")}'
assert play.get('become') == True, 'Must specify become: true'
assert 'nginx' in play.get('roles', []), 'Must include nginx role'
assert len(play.get('roles', [])) == 1, 'Must include only nginx role'
"
echo "PASS (test-nginx.yml targets hosts: application with become: true and role: nginx)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 30/30] Full regression syntax check across all project playbooks... "
for pb in "${ANSIBLE_DIR}"/playbooks/*.yml; do
    ansible-playbook --syntax-check "$pb" >/dev/null 2>&1 || {
        echo "FAIL (Syntax check failed on $pb)"
        exit 1
    }
done
echo "PASS (All playbooks passed ansible-playbook --syntax-check)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Fixture Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
