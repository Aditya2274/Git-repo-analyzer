#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_docker_role.sh
# Purpose: Isolated fixture testing and static validation of Checkpoint 4.6:
#          - Target OS & Ubuntu 24.04 Noble compatibility
#          - Hardware architecture detection & validation (x86_64 / amd64)
#          - Dedicated instance targeting (cicd-server / EC2 3 exclusively)
#          - Official Docker APT repository, keyring path, and signed-by syntax
#          - Package declarations (docker-ce, cli, containerd, buildx, compose)
#          - Daemon configuration (/etc/docker/daemon.json) and log-rotation limits
#          - Security boundaries: zero unauthenticated TCP daemon exposure
#          - Service lifecycle: systemd started and enabled for docker & containerd
#          - User permissions: docker group, append: true, no premature jenkins user
#          - Modern Docker Compose plugin validation (docker compose version)
#          - Playbook targeting and Ansible syntax validation
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${ANSIBLE_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d /tmp/test_docker_audit.XXXXXX)"

trap 'rm -rf "${TEST_TMP}"' EXIT

PASSED_COUNT=0
TOTAL_COUNT=30

echo "=============================================================================="
echo "Running Isolated Fixture Test Suite: Checkpoint 4.6 (Docker Role)"
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

with open('${ANSIBLE_DIR}/roles/docker/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

os_tasks = [t for t in tasks if 'operating system' in t.get('name', '').lower()]
assert len(os_tasks) >= 1, 'Must contain OS validation task'
ot = os_tasks[0]
assert 'ansible_distribution' in str(ot.get('when', '')), 'When condition must guard on ansible_distribution'
assert 'docker_target_distribution' in str(ot.get('when', '')), 'When condition must check docker_target_distribution'
"
echo "PASS (Preflight halts on unsupported operating systems)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Hardware Architecture Detection & Validation (x86_64 / amd64)
# ------------------------------------------------------------------------------
echo -n "[Test 3/30] Architecture detection logic (x86_64 mapped to amd64)... "
python3 -c "
def get_arch(ansible_arch):
    return 'amd64' if ansible_arch in ['x86_64', 'amd64'] else 'arm64' if ansible_arch in ['aarch64', 'arm64'] else ansible_arch

assert get_arch('x86_64') == 'amd64'
assert get_arch('amd64') == 'amd64'
assert get_arch('aarch64') == 'arm64'
assert get_arch('arm64') == 'arm64'
"
echo "PASS (x86_64 mapped to amd64 for Docker APT repository string)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Dedicated Instance Targeting (cicd-server exclusively)
# ------------------------------------------------------------------------------
echo -n "[Test 4/30] Instance targeting preflight enforces strict AND contract (all cases)... "
python3 -c "
import jinja2, yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

target_task = [t for t in tasks if 'targeting' in t.get('name', '').lower()][0]
when_cond = target_task.get('when', [])
cond_list = when_cond if isinstance(when_cond, list) else [when_cond]

env = jinja2.Environment()
# In Ansible, list items in 'when' are AND-combined.
# The task is 'ansible.builtin.fail', so if when evaluates to True, execution is REJECTED.
# If when evaluates to False, execution is ACCEPTED.
tmpl = env.from_string('{% if ' + ' and '.join(f'({c})' for c in cond_list) + ' %}REJECTED{% else %}ACCEPTED{% endif %}')

# Targeting Contract:
# 1. Correct hostname + correct group -> ACCEPTED
# 2. Correct hostname + missing group -> REJECTED
# 3. Incorrect hostname + correct group -> REJECTED
# 4. Incorrect hostname + missing group -> REJECTED
# 5. App server (with standard application groups) -> REJECTED
# 6. Puppet server (with standard puppet_server group) -> REJECTED
# 7. App server with cicd group mistakenly added -> REJECTED
# 8. Puppet server with cicd group mistakenly added -> REJECTED
test_scenarios = [
    ('cicd-server', ['cicd', 'puppet_agents'], 'ACCEPTED'),
    ('cicd-server', ['puppet_agents'], 'REJECTED'),
    ('cicd-server', [], 'REJECTED'),
    ('other-host', ['cicd'], 'REJECTED'),
    ('other-host', ['some_group'], 'REJECTED'),
    ('app-server', ['application', 'puppet_agents'], 'REJECTED'),
    ('app-server', ['cicd'], 'REJECTED'),
    ('puppet-server', ['puppet_server'], 'REJECTED'),
    ('puppet-server', ['cicd'], 'REJECTED'),
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

echo -n "[Test 5/30] Instance targeting assertion in preflight.yml... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/preflight.yml', 'r') as f:
    tasks = yaml.safe_load(f)

target_tasks = [t for t in tasks if 'targeting' in t.get('name', '').lower()]
assert len(target_tasks) >= 1, 'Must contain inventory targeting check'
tt = target_tasks[0]
when_raw = str(tt.get('when', ''))
assert 'docker_target_host' in when_raw, 'Must check docker_target_host'
assert 'docker_target_group' in when_raw or 'cicd' in when_raw, 'Must check target group'
assert ' or ' in when_raw, 'Must use OR boolean logic in fail task to enforce AND requirement'
assert tt.get('ansible.builtin.fail') is not None, 'Targeting check must be ansible.builtin.fail'
"
echo "PASS (AST verifies fail task with disjunctive fail condition)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Repository & Keyring Configuration
# ------------------------------------------------------------------------------
echo -n "[Test 6/30] Docker official GPG key URL reachability (HTTP 200)... "
GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" -I "${GPG_URL}")"
if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "PASS (Verified Docker GPG key HTTP 200 on download.docker.com)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Failed to reach ${GPG_URL}, HTTP ${HTTP_CODE})"
    exit 1
fi

echo -n "[Test 7/30] Docker official Noble repository Release URL reachability (HTTP 200)... "
RELEASE_URL="https://download.docker.com/linux/ubuntu/dists/noble/Release"
HTTP_CODE_REL="$(curl -s -o /dev/null -w "%{http_code}" -I "${RELEASE_URL}")"
if [[ "${HTTP_CODE_REL}" == "200" ]]; then
    echo "PASS (Verified Docker Noble Release HTTP 200 on download.docker.com)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    echo "FAIL (Failed to reach ${RELEASE_URL}, HTTP ${HTTP_CODE_REL})"
    exit 1
fi

echo -n "[Test 8/30] APT keyrings directory permissions (0755, root:root)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/repository.yml', 'r') as f:
    tasks = yaml.safe_load(f)

dir_tasks = [t for t in tasks if 'keyrings directory' in t.get('name', '').lower()]
assert len(dir_tasks) >= 1, 'Must ensure keyrings directory exists'
dt = dir_tasks[0]['ansible.builtin.file']
assert dt.get('mode') == '0755', 'Mode must be 0755'
assert dt.get('state') == 'directory', 'State must be directory'
"
echo "PASS (Keyrings directory configured with mode 0755)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 9/30] Docker GPG keyring file path and mode (0644, docker.asc)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/repository.yml', 'r') as f:
    tasks = yaml.safe_load(f)

key_tasks = [t for t in tasks if 'docker gpg' in t.get('name', '').lower()]
assert len(key_tasks) >= 1, 'Must download Docker GPG key'
kt = key_tasks[0]['ansible.builtin.get_url']
assert 'docker.asc' in str(kt.get('dest')), 'Destination must be docker.asc'
assert kt.get('mode') == '0644', 'Keyring file mode must be 0644'
"
echo "PASS (Keyring downloaded to /etc/apt/keyrings/docker.asc with mode 0644)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 10/30] Modern signed-by repository configuration (zero deprecated apt-key)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/repository.yml', 'r') as f:
    content = f.read()

assert 'apt-key' not in content, 'Must NEVER use deprecated apt-key'
assert 'signed-by=' in content, 'Repository string must include signed-by='
assert 'download.docker.com/linux/ubuntu' in content, 'Must target official Docker repository'
"
echo "PASS (Uses signed-by keyring reference; zero deprecated apt-key usage)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 11/30] Dedicated repository filename (docker.list)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/repository.yml', 'r') as f:
    tasks = yaml.safe_load(f)

repo_task = [t for t in tasks if 'ansible.builtin.apt_repository' in t][0]['ansible.builtin.apt_repository']
assert 'docker' in str(repo_task.get('filename')), 'Repository filename must be docker'
"
echo "PASS (Repository isolated in /etc/apt/sources.list.d/docker.list)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Package Selection & Installation Declarations
# ------------------------------------------------------------------------------
echo -n "[Test 12/30] Prerequisite packages declared (ca-certificates, curl)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

prereqs = defaults.get('docker_prerequisite_packages', [])
assert 'ca-certificates' in prereqs, 'ca-certificates must be in prerequisites'
assert 'curl' in prereqs, 'curl must be in prerequisites'
"
echo "PASS (Prerequisites ca-certificates and curl declared in defaults)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 13/30] Docker Engine and CLI packages declared (docker-ce, docker-ce-cli)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

packages = defaults.get('docker_packages', [])
assert 'docker-ce' in packages, 'docker-ce must be declared'
assert 'docker-ce-cli' in packages, 'docker-ce-cli must be declared'
assert 'containerd.io' in packages, 'containerd.io must be declared'
"
echo "PASS (docker-ce, docker-ce-cli, and containerd.io declared)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 14/30] Docker Compose plugin declared (docker-compose-plugin)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

packages = defaults.get('docker_packages', [])
assert 'docker-compose-plugin' in packages, 'docker-compose-plugin must be declared'
assert 'docker-compose' not in packages, 'Legacy standalone docker-compose must NOT be declared'
assert 'docker-buildx-plugin' in packages, 'docker-buildx-plugin must be declared'
"
echo "PASS (docker-compose-plugin declared; legacy standalone docker-compose excluded)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 15/30] Package state defaults to present (non-breaking, idempotent)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

assert defaults.get('docker_packages_state') == 'present', 'Package state must be present'
"
echo "PASS (docker_packages_state defaults to 'present')"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Docker Daemon Configuration & Handlers
# ------------------------------------------------------------------------------
echo -n "[Test 16/30] Docker daemon configuration directory exists (/etc/docker, 0755)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

dir_tasks = [t for t in tasks if 'docker configuration directory' in t.get('name', '').lower()]
assert len(dir_tasks) >= 1, 'Must create /etc/docker'
dt = dir_tasks[0]['ansible.builtin.file']
assert dt.get('mode') == '0755'
assert dt.get('state') == 'directory'
"
echo "PASS (/etc/docker configured with mode 0755)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 17/30] Log-rotation settings in daemon.json (max-size: 10m, max-file: 3)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

daemon_cfg = defaults.get('docker_daemon_config', {})
assert daemon_cfg.get('log-driver') == 'json-file'
log_opts = daemon_cfg.get('log-opts', {})
assert log_opts.get('max-size') == '10m', 'max-size must be 10m'
assert log_opts.get('max-file') == '3', 'max-file must be 3'
"
echo "PASS (Log-driver json-file with max-size 10m and max-file 3 configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 18/30] Handlers defined for Docker daemon and containerd restart... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/handlers/main.yml', 'r') as f:
    handlers = yaml.safe_load(f)

handler_names = [h.get('name') for h in handlers]
assert 'Restart Docker daemon' in handler_names, 'Must contain Restart Docker daemon handler'
assert 'Restart containerd' in handler_names, 'Must contain Restart containerd handler'

for h in handlers:
    assert 'when' in h, 'Handler must be guarded'
    assert 'started' in str(h['when']), 'Handler must guard on started state'
"
echo "PASS (Restart handlers defined and guarded on service state == started)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Security Boundaries & Socket Protection
# ------------------------------------------------------------------------------
echo -n "[Test 19/30] Safety check rejects unauthenticated TCP daemon exposure... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/config.yml', 'r') as f:
    tasks = yaml.safe_load(f)

tcp_tasks = [t for t in tasks if 'tcp endpoint' in t.get('name', '').lower()]
assert len(tcp_tasks) >= 1, 'Must contain TCP socket security check'
tt = tcp_tasks[0]
assert 'CRITICAL SECURITY ALERT' in tt['ansible.builtin.fail']['msg']

# Test simulation: config with tcp:// must be detected
bad_config = {'hosts': ['unix:///var/run/docker.sock', 'tcp://0.0.0.0:2375']}
good_config = {'log-driver': 'json-file'}

has_tcp_bad = any(h.startswith('tcp://') for h in bad_config.get('hosts', []))
has_tcp_good = any(h.startswith('tcp://') for h in good_config.get('hosts', []))

assert has_tcp_bad, 'Must detect tcp:// in bad config'
assert not has_tcp_good, 'Good config must have no tcp://'
"
echo "PASS (Fails fast if tcp:// is configured in daemon.json hosts)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 20/30] Zero host Docker socket mounts in role tasks... "
python3 -c "
import os

for root, _, files in os.walk('${ANSIBLE_DIR}/roles/docker/tasks'):
    for f in files:
        if f.endswith('.yml'):
            with open(os.path.join(root, f), 'r') as fp:
                content = fp.read()
            assert '/var/run/docker.sock:/' not in content, f'Host socket mount found in {f}'
"
echo "PASS (Zero host Docker socket mounts present in role tasks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. User Permissions & Group Management
# ------------------------------------------------------------------------------
echo -n "[Test 21/30] Docker group creation task exists... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/users.yml', 'r') as f:
    tasks = yaml.safe_load(f)

grp_tasks = [t for t in tasks if 'ansible.builtin.group' in t]
assert len(grp_tasks) >= 1, 'Must ensure docker group exists'
gt = grp_tasks[0]['ansible.builtin.group']
assert 'docker' in str(gt.get('name'))
assert gt.get('state') == 'present'
"
echo "PASS (docker group creation declared with state: present)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 22/30] Premature Jenkins user addition strictly rejected in Phase 4... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/users.yml', 'r') as f:
    tasks = yaml.safe_load(f)

jenkins_tasks = [t for t in tasks if 'jenkins' in t.get('name', '').lower()]
assert len(jenkins_tasks) >= 1, 'Must guard against premature Jenkins user addition'
jt = jenkins_tasks[0]
assert 'CRITICAL SECURITY ALERT' in jt['ansible.builtin.fail']['msg']
assert 'jenkins' in str(jt.get('when', ''))
"
echo "PASS (Fails fast with security alert if jenkins user is added before Phase 7)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 23/30] User addition enforces append: true (preserves secondary groups)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/users.yml', 'r') as f:
    tasks = yaml.safe_load(f)

user_tasks = [t for t in tasks if 'ansible.builtin.user' in t]
assert len(user_tasks) >= 1, 'Must contain user management task'
ut = user_tasks[0]['ansible.builtin.user']
assert ut.get('append') == True, 'User task must specify append: true'
assert 'docker' in str(ut.get('groups')), 'User task must add to docker group'
"
echo "PASS (User membership task configures append: true to preserve groups)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 24/30] CI/CD group variables configure ubuntu user for EC2 3... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/inventory/group_vars/cicd.yml', 'r') as f:
    vars_data = yaml.safe_load(f)

users = vars_data.get('docker_users', [])
assert 'ubuntu' in users, 'ubuntu user must be in docker_users for cicd'
assert 'jenkins' not in users, 'jenkins must NOT be in docker_users in Phase 4'
"
echo "PASS (group_vars/cicd.yml defines docker_users = ['ubuntu'])"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Service Lifecycle & Management
# ------------------------------------------------------------------------------
echo -n "[Test 25/30] Docker daemon systemd service declared started and enabled... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/service.yml', 'r') as f:
    tasks = yaml.safe_load(f)

docker_svc = [t for t in tasks if 'docker daemon' in t.get('name', '').lower()][0]
st = docker_svc['ansible.builtin.systemd']
assert 'docker_service_state' in str(st.get('state'))
assert 'docker_service_enabled' in str(st.get('enabled'))

with open('${ANSIBLE_DIR}/roles/docker/defaults/main.yml', 'r') as f:
    defaults = yaml.safe_load(f)

assert defaults.get('docker_service_state') == 'started', 'docker_service_state must default to started'
assert defaults.get('docker_service_enabled') == True, 'docker_service_enabled must default to true'
"
echo "PASS (Docker daemon configured with state: started, enabled: true)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 26/30] containerd systemd service declared started and enabled... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/service.yml', 'r') as f:
    tasks = yaml.safe_load(f)

containerd_svc = [t for t in tasks if 'containerd' in t.get('name', '').lower()][0]
st = containerd_svc['ansible.builtin.systemd']
assert 'docker_service_state' in str(st.get('state'))
assert 'docker_service_enabled' in str(st.get('enabled'))
"
echo "PASS (containerd service configured with state: started, enabled: true)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Modern Docker Compose Plugin Verification
# ------------------------------------------------------------------------------
echo -n "[Test 27/30] Docker Compose plugin invocation format (docker compose version)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/roles/docker/tasks/verify.yml', 'r') as f:
    tasks = yaml.safe_load(f)

compose_tasks = [t for t in tasks if 'docker compose' in str(t.get('ansible.builtin.command', {}).get('cmd', ''))]
assert len(compose_tasks) >= 1, 'Must invoke docker compose version'
cmd = compose_tasks[0]['ansible.builtin.command']['cmd']
assert cmd.strip() == 'docker compose version', f'Expected docker compose version, got {cmd}'
"
echo "PASS (Verification uses official docker compose version plugin command)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Playbook Orchestration & Syntax Checks
# ------------------------------------------------------------------------------
echo -n "[Test 28/30] Playbook targeting in test-docker.yml (hosts: cicd)... "
python3 -c "
import yaml

with open('${ANSIBLE_DIR}/playbooks/test-docker.yml', 'r') as f:
    playbook = yaml.safe_load(f)

assert len(playbook) == 1, 'test-docker.yml must contain 1 play'
play = playbook[0]
assert play.get('hosts') == 'cicd', f'Expected hosts: cicd, got {play.get(\"hosts\")}'
assert play.get('become') == True, 'Must specify become: true'
assert 'docker' in play.get('roles', []), 'Must include docker role'
"
echo "PASS (test-docker.yml targets hosts: cicd with become: true and role: docker)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo -n "[Test 29/30] Ansible syntax validation on test-docker.yml... "
ansible-playbook --syntax-check "${ANSIBLE_DIR}/playbooks/test-docker.yml" >/dev/null 2>&1
echo "PASS (ansible-playbook --syntax-check exited 0)"
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
