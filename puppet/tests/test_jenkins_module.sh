#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_jenkins_module.sh (Phase 7.2 — Puppet Jenkins Module)
# Description: Comprehensive static, AST, catalog compilation, Hiera override,
#              DAG cycle/ordering, placement isolation, security hygiene, and
#              sandboxed fixture idempotency verification for puppet/modules/jenkins.
# Scope & Boundary Note:
#   - Executed strictly under Approval Boundary A (local catalog/fixture checks).
#   - Real Ubuntu 24.04 apt installation, live Jenkins daemon startup, and live
#     EC2 3 300 MB memory headroom validation remain PENDING Boundary B.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=21

echo "=============================================================================="
echo "Running Test Suite: Phase 7.2 (Puppet Jenkins Module)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Module Structure, Puppet Parser & ERB Syntax Validation
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Module layout, Puppet DSL parser & ERB template validation... "
mapfile -t JENKINS_PP < <(find "${PUPPET_DIR}/modules/jenkins/manifests" -type f -name '*.pp' | sort)
if [[ ${#JENKINS_PP[@]} -lt 5 ]]; then
  echo "FAILED: Expected 5 manifests in modules/jenkins/manifests"
  exit 1
fi
puppet parser validate "${PUPPET_DIR}/manifests/site.pp" "${JENKINS_PP[@]}"
for tpl in \
  "${PUPPET_DIR}/modules/jenkins/templates/override.conf.erb" \
  "${PUPPET_DIR}/modules/jenkins/templates/controller-hardening.groovy.erb"; do
  erb -x -T - "${tpl}" | ruby -c >/dev/null
done
python3 -c "import yaml; yaml.safe_load(open('${PUPPET_DIR}/hieradata/common.yaml'))"
echo "PASS (${#JENKINS_PP[@]} manifests, 2 ERB templates, and common.yaml valid)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Jenkins Class Compilation on cicd-server
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Deterministic JSON catalog compilation on cicd-server... "
export PUPPET_DIR
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

def compile_cicd():
    res = subprocess.run([
        'puppet', 'catalog', 'find', 'cicd-server',
        '--terminus=compiler',
        '--certname', 'cicd-server',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--manifest', f'{puppet_dir}/manifests/site.pp',
        '--color=false',
        '--render-as=json',
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Catalog compilation failed: {res.stderr}'
    assert 'Duplicate declaration' not in res.stderr, f'Duplicate resource: {res.stderr}'
    return json.loads(res.stdout[res.stdout.index('{'):])

cat1 = compile_cicd()
cat2 = compile_cicd()
classes = set(cat1.get('classes', []))
assert {'jenkins', 'jenkins::repo', 'jenkins::install', 'jenkins::config', 'jenkins::service'}.issubset(classes)
assert [(r['type'], r['title']) for r in cat1['resources']] == [(r['type'], r['title']) for r in cat2['resources']]
EOF
echo "PASS (cicd-server catalog compiles deterministically with all 5 jenkins classes)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Official Jenkins APT Repository & GPG Keyring Resources
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Jenkins APT repository, 2026 GPG keyring, signed-by & pin priority... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

assert ('File', '/etc/apt/keyrings') in by_id
assert ('Exec', 'jenkins_apt_gpg_key') in by_id
assert 'jenkins.io-2026.key' in by_id[('Exec', 'jenkins_apt_gpg_key')]['command']
assert 'apt-key' not in by_id[('Exec', 'jenkins_apt_gpg_key')]['command']
assert by_id[('File', '/etc/apt/keyrings/jenkins-keyring.asc')]['mode'] == '0644'

src = by_id[('File', '/etc/apt/sources.list.d/jenkins.list')]['content']
assert 'deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/' in src

pref = by_id[('File', '/etc/apt/preferences.d/jenkins')]['content']
assert 'Package: jenkins' in pref
assert 'Pin: origin pkg.jenkins.io' in pref
assert 'Pin-Priority: 900' in pref

assert by_id[('Exec', 'jenkins_apt_update')]['refreshonly'] is True

# Reject plain HTTP repo/key URLs
for bad_expr in [
    "class { 'jenkins': enforce_node => false, repo_base_url => 'http://pkg.jenkins.io/debian-stable' }",
    "class { 'jenkins': enforce_node => false, gpg_key_url => 'http://pkg.jenkins.io/debian-stable/jenkins.io-2026.key' }",
]:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', 'cicd-server', '-e', bad_expr,
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'Expected plain HTTP URL to fail closed: {bad_expr}'
EOF
echo "PASS (HTTPS pkg.jenkins.io repo, 2026 signed-by keyring, pin 900, HTTP rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Java 21 Runtime Dependency Enforcement
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Java 21 runtime dependency & non-Java-21 rejection... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

assert ('Package', 'openjdk-21-jre-headless') in by_id
assert by_id[('Package', 'openjdk-21-jre-headless')]['ensure'] == 'present'
assert ('Package', 'fontconfig') in by_id
reqs = by_id[('Package', 'jenkins')]['require']
assert 'Package[openjdk-21-jre-headless]' in reqs
assert 'Package[fontconfig]' in reqs

for bad_java in ['openjdk-17-jre-headless', 'openjdk-11-jre-headless', 'default-jre']:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', 'cicd-server', '-e', f"class {{ 'jenkins': java_package => '{bad_java}' }}",
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'Expected non-Java-21 package {bad_java} to be rejected'
EOF
echo "PASS (openjdk-21-jre-headless + fontconfig required; Java 17/11 rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Jenkins LTS 2.580.3 Version Baseline
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Jenkins LTS 2.580.3 planning baseline package ensure... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

assert by_id[('Package', 'jenkins')]['ensure'] == '2.580.3'
EOF
echo "PASS (Package[jenkins] defaults to 2.580.3 baseline)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Systemd Drop-in & Service Configuration
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Systemd drop-in override, daemon-reload & Service[jenkins]... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

assert by_id[('File', '/etc/systemd/system/jenkins.service.d')]['ensure'] == 'directory'
dropin = by_id[('File', '/etc/systemd/system/jenkins.service.d/override.conf')]
assert dropin['mode'] == '0644'
assert dropin['notify'] == 'Exec[jenkins_systemd_daemon_reload]'
assert by_id[('Exec', 'jenkins_systemd_daemon_reload')]['refreshonly'] is True

svc = by_id[('Service', 'jenkins')]
assert svc['ensure'] == 'running'
assert svc['enable'] is True
assert svc['provider'] == 'systemd'
assert svc['hasstatus'] is True and svc['hasrestart'] is True
EOF
echo "PASS (Systemd drop-in, daemon-reload, and running/enabled service configured)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. JVM Heap Settings (-Xms384m -Xmx512m) & Guardrails
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Approved JVM heap (-Xms384m -Xmx512m) & invalid heap rejection... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

override = by_id[('File', '/etc/systemd/system/jenkins.service.d/override.conf')]['content']
assert '-Xms384m' in override
assert '-Xmx512m' in override
assert '-Djava.awt.headless=true' in override

for bad_heap in [
    "class { 'jenkins': jvm_xms => '768m', jvm_xmx => '512m' }",
    "class { 'jenkins': jvm_xms => '512m', jvm_xmx => '2048m' }",
    "class { 'jenkins': jvm_xms => '0m', jvm_xmx => '512m' }",
]:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', 'cicd-server', '-e', bad_heap,
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'Expected invalid JVM heap to fail: {bad_heap}'
EOF
echo "PASS (-Xms384m -Xmx512m verified; invalid/oversized heap fails closed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Jenkins Home Ownership & Permissions
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Jenkins home directory & init.groovy.d ownership/permissions... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

home = by_id[('File', '/var/lib/jenkins')]
assert home['ensure'] == 'directory' and home['owner'] == 'jenkins' and home['group'] == 'jenkins' and home['mode'] == '0750'

initd = by_id[('File', '/var/lib/jenkins/init.groovy.d')]
assert initd['ensure'] == 'directory' and initd['owner'] == 'jenkins' and initd['group'] == 'jenkins' and initd['mode'] == '0750'

hardening = by_id[('File', '/var/lib/jenkins/init.groovy.d/01-controller-hardening.groovy')]
assert hardening['ensure'] == 'file' and hardening['owner'] == 'jenkins' and hardening['group'] == 'jenkins' and hardening['mode'] == '0640'
EOF
echo "PASS (/var/lib/jenkins 0750 and hardening script 0640 owned by jenkins:jenkins)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Port 8080 Wildcard Bind (0.0.0.0), Single Executor & Inbound Port Hardening
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Port 8080 wildcard bind (0.0.0.0), single executor (1), disabled JNLP/UDP & privileged port rejection... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

override = by_id[('File', '/etc/systemd/system/jenkins.service.d/override.conf')]['content']
assert 'Environment="JENKINS_PORT=8080"' in override
assert 'Environment="JENKINS_LISTEN_ADDRESS=0.0.0.0"' in override
assert 'wildcard listener, NOT' in override
assert 'cicd_analysis_sg' in override
assert '-Dhudson.DNSMultiCast.disabled=true' in override
assert '-Dhudson.udp=-1' in override
assert 'JENKINS_HTTPS_PORT' not in override

groovy = by_id[('File', '/var/lib/jenkins/init.groovy.d/01-controller-hardening.groovy')]['content']
assert 'setNumExecutors(1)' in groovy
assert 'setSlaveAgentPort(-1)' in groovy
assert 'DefaultCrumbIssuer(true)' in groovy
assert 'setAllowAnonymousRead(false)' in groovy

for bad_expr in [
    "class { 'jenkins': http_port => 80 }",
    "class { 'jenkins': http_port => 443 }",
    "class { 'jenkins': num_executors => 2 }",
]:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', 'cicd-server', '-e', bad_expr,
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'Expected invalid port/executor override to fail: {bad_expr}'
EOF
echo "PASS (Port 8080 explicit 0.0.0.0 wildcard bind, 1 executor, disabled JNLP/UDP, anonymous read blocked, 80/443 rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Zero Reverse-Proxy Web Servers on cicd-server (Distinguished from 0.0.0.0:8080 Wildcard)
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Zero nginx/apache2/haproxy packages on cicd-server (SG protects 0.0.0.0:8080 wildcard)... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
ids = {(r['type'], r['title']) for r in cat['resources']}

for forbidden in [
    ('Package', 'nginx'), ('Service', 'nginx'),
    ('Package', 'apache2'), ('Service', 'apache2'),
    ('Package', 'haproxy'), ('Service', 'haproxy'),
]:
    assert forbidden not in ids, f'Forbidden web proxy resource found on cicd-server: {forbidden}'
EOF
echo "PASS (Zero nginx/apache2/haproxy resources; 0.0.0.0:8080 wildcard bind is explicitly gated by AWS SG)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Docker Group Membership & Security Isolation
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Docker group membership for jenkins only & ADR 007 security posture... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
users = [r for r in cat['resources'] if r['type'] == 'User']
groups = {r['title']: r.get('parameters', {}) for r in cat['resources'] if r['type'] == 'Group'}

assert 'docker' in groups and groups['docker']['ensure'] == 'present'
assert len(users) == 1 and users[0]['title'] == 'jenkins'
u_params = users[0]['parameters']
assert u_params['groups'] == ['docker']
assert u_params['membership'] == 'minimum'

with open(os.path.join(puppet_dir, 'modules/jenkins/manifests/config.pp')) as f:
    cfg_src = f.read()
assert 'root-equivalent' in cfg_src
assert 'UNIX socket' in cfg_src
assert 'docker.sock' not in cfg_src
assert 'tcp://' not in cfg_src
EOF
echo "PASS (jenkins user only added to docker with membership => minimum; ADR 007 documented)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Hiera Parameter Overrides
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Hiera parameter overrides propagate cleanly into catalog... "
python3 - << 'EOF'
import json, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    override_yaml = os.path.join(tmpdir, 'override.yaml')
    hiera_yaml = os.path.join(tmpdir, 'hiera.yaml')
    with open(override_yaml, 'w') as f:
        f.write(
            "---\n"
            "jenkins::http_port: 8085\n"
            "jenkins::listen_address: '127.0.0.1'\n"
            "jenkins::jvm_xms: '256m'\n"
            "jenkins::jvm_xmx: '640m'\n"
            "jenkins::jenkins_version: '2.580.4'\n"
            "jenkins::jenkins_home: '/srv/jenkins'\n"
            "jenkins::manage_docker_group: false\n"
        )
    with open(hiera_yaml, 'w') as f:
        f.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'Test override'\n    path: '{override_yaml}'\n"
            f"  - name: 'Common data'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )
    res = subprocess.run([
        'puppet', 'catalog', 'find', 'cicd-server',
        '--terminus=compiler', '--certname', 'cicd-server',
        f'--modulepath={puppet_dir}/modules', f'--hiera_config={hiera_yaml}',
        '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
    ], capture_output=True, text=True, check=True)
    cat = json.loads(res.stdout[res.stdout.index('{'):])
    by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

    assert by_id[('Package', 'jenkins')]['ensure'] == '2.580.4'
    assert ('File', '/srv/jenkins') in by_id
    assert ('User', 'jenkins') not in by_id
    content = by_id[('File', '/etc/systemd/system/jenkins.service.d/override.conf')]['content']
    assert 'JENKINS_PORT=8085' in content
    assert 'JENKINS_LISTEN_ADDRESS=127.0.0.1' in content
    assert '-Xms256m -Xmx640m' in content
    assert 'JENKINS_HOME=/srv/jenkins' in content
EOF
echo "PASS (Hiera overrides for port, bind, heap, version, home, and docker group verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Full DAG Cycle Detection & Resource Ordering (--graph)
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Full --graph DAG cycle detection & strict resource ordering... "
python3 - << 'EOF'
from collections import defaultdict, deque
import os, re, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as gdir:
    res = subprocess.run([
        'puppet', 'apply', '--noop', '--graph', f'--graphdir={gdir}',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--certname', 'cicd-server',
        f'{puppet_dir}/manifests/site.pp',
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Graph compilation failed: {res.stderr}'
    assert 'dependency cycle' not in (res.stdout + res.stderr).lower()

    dot_path = os.path.join(gdir, 'expanded_relationships.dot')
    edges = defaultdict(set)
    nodes = set()
    with open(dot_path) as f:
        for line in f:
            m = re.match(r'^\s*"([^"]+)"\s*->\s*"([^"]+)"', line)
            if m:
                u, v = m.group(1), m.group(2)
                nodes.add(u)
                nodes.add(v)
                edges[u].add(v)

    indeg = {u: 0 for u in nodes}
    for u, nbrs in edges.items():
        for v in nbrs:
            indeg[v] += 1
    q = deque([u for u, d in indeg.items() if d == 0])
    visited = 0
    while q:
        u = q.popleft()
        visited += 1
        for v in edges.get(u, ()):
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)
    assert visited == len(nodes), f'DAG cycle detected ({visited}/{len(nodes)})'

    def reachable(src, dst):
        seen = {src}
        dq = deque([src])
        while dq:
            cur = dq.popleft()
            if cur == dst:
                return True
            for nxt in edges.get(cur, ()):
                if nxt not in seen:
                    seen.add(nxt)
                    dq.append(nxt)
        return False

    # Node-level stage chain: common -> nrpe::server -> jenkins
    assert reachable('Whit[Completed_class[Common]]', 'Whit[Admissible_class[Nrpe::Server]]')
    assert reachable('Whit[Completed_class[Nrpe::Server]]', 'Whit[Admissible_class[Jenkins]]')
    assert reachable('Whit[Completed_class[Jenkins::Repo]]', 'Whit[Admissible_class[Jenkins::Install]]')
    assert reachable('Whit[Completed_class[Jenkins::Install]]', 'Whit[Admissible_class[Jenkins::Config]]')
    assert reachable('Whit[Completed_class[Jenkins::Config]]', 'Whit[Admissible_class[Jenkins::Service]]')

    # Resource-level critical ordering paths
    assert reachable('Exec[jenkins_apt_gpg_key]', 'File[/etc/apt/keyrings/jenkins-keyring.asc]')
    assert reachable('File[/etc/apt/keyrings/jenkins-keyring.asc]', 'File[/etc/apt/sources.list.d/jenkins.list]')
    assert reachable('File[/etc/apt/sources.list.d/jenkins.list]', 'Exec[jenkins_apt_update]')
    assert reachable('Exec[jenkins_apt_update]', 'Package[jenkins]')
    assert reachable('Package[openjdk-21-jre-headless]', 'Package[jenkins]')
    assert reachable('Package[fontconfig]', 'Package[jenkins]')
    assert reachable('Package[jenkins]', 'File[/var/lib/jenkins]')
    assert reachable('File[/var/lib/jenkins]', 'File[/var/lib/jenkins/init.groovy.d/01-controller-hardening.groovy]')
    assert reachable('File[/etc/systemd/system/jenkins.service.d/override.conf]', 'Exec[jenkins_systemd_daemon_reload]')
    assert reachable('Exec[jenkins_systemd_daemon_reload]', 'Service[jenkins]')
    assert reachable('User[jenkins]', 'Service[jenkins]')
EOF
echo "PASS (Zero cycles; all repo -> install -> config -> service paths verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Behavioral Idempotency & Config Refresh Fixture Test
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Sandboxed fixture apply idempotency (exit 2 -> 0 -> refresh on change -> 0)... "
python3 - << 'EOF'
import os, stat, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    j_home = os.path.join(tmpdir, 'var_lib_jenkins')
    dropin_dir = os.path.join(tmpdir, 'systemd_dropin')
    dropin_file = os.path.join(dropin_dir, 'override.conf')
    svc_state = os.path.join(tmpdir, 'svc.active')
    events_log = os.path.join(tmpdir, 'events.log')
    fake_systemctl = os.path.join(tmpdir, 'systemctl')

    with open(fake_systemctl, 'w') as f:
        f.write(f"""#!/usr/bin/env bash
set -eu
cmd="${{1:-}}"
case "$cmd" in
  daemon-reload)
    echo "daemon-reload" >> "{events_log}"
    ;;
  is-active)
    test -f "{svc_state}"
    ;;
  start)
    echo "start" >> "{events_log}"
    touch "{svc_state}"
    ;;
  stop)
    echo "stop" >> "{events_log}"
    rm -f "{svc_state}"
    ;;
  restart)
    echo "restart" >> "{events_log}"
    touch "{svc_state}"
    ;;
  *)
    exit 1
    ;;
esac
""")
    os.chmod(fake_systemctl, 0o755)

    def apply_fixture(http_port=8080, jvm_xmx='512m'):
        expr = (
            f"class {{ 'jenkins': "
            f"enforce_node => false, manage_repo => false, manage_packages => false, "
            f"manage_users => false, manage_ownership => false, manage_docker_group => false, "
            f"manage_service => true, service_provider => 'base', "
            f"systemctl_bin => '{fake_systemctl}', "
            f"jenkins_home => '{j_home}', "
            f"systemd_dropin_dir => '{dropin_dir}', "
            f"systemd_dropin_file => '{dropin_file}', "
            f"http_port => {http_port}, jvm_xmx => '{jvm_xmx}' }}"
        )
        return subprocess.run([
            'puppet', 'apply', '--detailed-exitcodes',
            f'--modulepath={puppet_dir}/modules', '--certname', 'cicd-server', '-e', expr,
        ], capture_output=True, text=True)

    # Run 1: initial convergence -> exit 2
    r1 = apply_fixture(8080, '512m')
    assert r1.returncode == 2, f'Expected exit 2 on initial apply, got {r1.returncode}: {r1.stderr}'
    assert os.path.isfile(dropin_file)
    assert os.path.isfile(os.path.join(j_home, 'init.groovy.d', '01-controller-hardening.groovy'))
    assert (stat.S_IMODE(os.stat(j_home).st_mode)) == 0o750
    ev1 = open(events_log).read().splitlines()
    assert 'daemon-reload' in ev1 and 'start' in ev1

    # Run 2: idempotent steady-state re-apply -> exit 0, zero new daemon-reload/restart
    r2 = apply_fixture(8080, '512m')
    assert r2.returncode == 0, f'Expected exit 0 on steady-state re-apply, got {r2.returncode}: {r2.stderr}'
    assert open(events_log).read().splitlines() == ev1, 'Idempotent re-apply must not reload or restart service'

    # Run 3: configuration change -> exit 2, daemon-reload + restart triggered
    r3 = apply_fixture(8088, '640m')
    assert r3.returncode == 2, f'Expected exit 2 on config update, got {r3.returncode}: {r3.stderr}'
    ev3 = open(events_log).read().splitlines()
    assert ev3.count('daemon-reload') == 2
    assert 'restart' in ev3[len(ev1):]

    # Run 4: post-change idempotency -> exit 0
    r4 = apply_fixture(8088, '640m')
    assert r4.returncode == 0, f'Expected exit 0 after change convergence, got {r4.returncode}: {r4.stderr}'
EOF
echo "PASS (exit 2 -> 0 steady-state; config update triggers daemon-reload + restart -> 0)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. cicd-server Role Integration & NRPE Preservation
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] cicd-server classification preserves common, nrpe::server & check_jenkins... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
classes = set(cat.get('classes', []))
ids = {(r['type'], r['title']) for r in cat['resources']}

assert {'common', 'nrpe::server', 'jenkins'}.issubset(classes)
assert ('Service', 'puppet') in ids
assert ('Service', 'nagios-nrpe-server') in ids
assert ('Service', 'jenkins') in ids
assert ('File', '/usr/lib/nagios/plugins/check_jenkins.sh') in ids
assert ('File', '/usr/lib/nagios/plugins/check_docker.sh') in ids
EOF
echo "PASS (common, nrpe::server, check_jenkins, check_docker, and jenkins co-exist cleanly)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Absence of Jenkins / Nagios Placement Conflicts Across Fleet Nodes
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Strict fleet placement isolation (Jenkins on cicd-server only)... "
python3 - << 'EOF'
import json, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def compile_node(node, hiera_cfg):
    res = subprocess.run([
        'puppet', 'catalog', 'find', node,
        '--terminus=compiler', '--certname', node,
        f'--modulepath={puppet_dir}/modules', f'--hiera_config={hiera_cfg}',
        '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
    ], capture_output=True, text=True, check=True)
    return json.loads(res.stdout[res.stdout.index('{'):])

with tempfile.TemporaryDirectory() as tmpdir:
    app_hiera = os.path.join(tmpdir, 'hiera.yaml')
    app_override = os.path.join(tmpdir, 'app.yaml')
    with open(app_override, 'w') as f:
        f.write("---\nnagios::web::admin_password_hash: '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'\n")
    with open(app_hiera, 'w') as f:
        f.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'App'\n    path: '{app_override}'\n"
            f"  - name: 'Common'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )

    p_cat = compile_node('puppet-server', f'{puppet_dir}/hiera.yaml')
    a_cat = compile_node('app-server', app_hiera)
    c_cat = compile_node('cicd-server', f'{puppet_dir}/hiera.yaml')

for name, cat in [('puppet-server', p_cat), ('app-server', a_cat)]:
    cls = set(cat.get('classes', []))
    ids = {(r['type'], r['title']) for r in cat['resources']}
    assert not any(c.startswith('jenkins') for c in cls), f'{name} must never include jenkins classes'
    assert ('Package', 'jenkins') not in ids and ('Service', 'jenkins') not in ids

c_cls = set(c_cat.get('classes', []))
assert not any(c.startswith('nagios') or c.startswith('application') or c == 'nrpe::client' for c in c_cls)

# Direct inclusion guard fails closed on non-cicd certnames
for bad_cert in ['puppet-server', 'app-server', 'unknown-node.example']:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', bad_cert, '-e', "class { 'jenkins': }",
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'jenkins class must fail closed when included on {bad_cert}'
    assert 'strictly restricted to cicd-server' in (bad.stdout + bad.stderr)
EOF
echo "PASS (Zero jenkins on puppet/app servers; zero nagios/app on cicd; node guard fails closed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Unknown-Certname Safety Behavior (node default)
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Unknown-certname node default safety baseline preserved... "
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'unknown-host.internal',
    '--terminus=compiler', '--certname', 'unknown-host.internal',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
cls = set(cat.get('classes', []))
ids = {(r['type'], r['title']) for r in cat['resources']}

assert 'common' in cls
assert not any(c.startswith(('jenkins', 'nagios', 'nrpe', 'application')) for c in cls)
assert ('Package', 'jenkins') not in ids and ('Service', 'jenkins') not in ids
EOF
echo "PASS (Unknown certname receives common baseline only; zero jenkins resources)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Zero Embedded Credentials, API Tokens, or Groq Keys
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Zero embedded credentials, API tokens, or GROQ_API_KEY... "
python3 - << 'EOF'
import os, re

puppet_dir = os.environ['PUPPET_DIR']
scan_files = []
for root in [os.path.join(puppet_dir, 'modules/jenkins'), os.path.join(puppet_dir, 'hieradata')]:
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(('.pp', '.erb', '.yaml', '.yml')):
                scan_files.append(os.path.join(dirpath, fn))

forbidden_patterns = [
    r'GROQ_API_KEY',
    r'createAccount\s*\(',
    r'jenkins_api_token\s*:',
    r'admin_password',
    r'initialAdminPassword',
    r'runSetupWizard\s*=\s*false',
    r'AuthorizationStrategy\.Unsecured',
]

for fpath in scan_files:
    with open(fpath) as f:
        text = f.read()
    for pat in forbidden_patterns:
        if pat == r'AuthorizationStrategy\.Unsecured':
            # Permitted only as an instanceof rejection check inside controller-hardening.groovy.erb
            if fpath.endswith('controller-hardening.groovy.erb'):
                assert 'instanceof AuthorizationStrategy.Unsecured' in text
                assert 'setAuthorizationStrategy(new AuthorizationStrategy.Unsecured' not in text
                continue
        assert not re.search(pat, text), f'Forbidden secret/credential pattern {pat} found in {fpath}'
EOF
echo "PASS (Zero passwords, tokens, GROQ_API_KEY, or wizard bypasses embedded)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Absolute Path & Control-Character Input Hardening
# ------------------------------------------------------------------------------
echo -n "[Test 19/${TOTAL_COUNT}] Input hardening against relative paths & control characters... "
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
for bad_expr in [
    "class { 'jenkins': enforce_node => false, jenkins_home => 'relative/jenkins' }",
    "class { 'jenkins': enforce_node => false, systemd_dropin_file => 'override.conf' }",
    "class { 'jenkins': enforce_node => false, jenkins_home => \"/var/lib/jenkins\necho evil\" }",
]:
    bad = subprocess.run([
        'puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
        '--certname', 'cicd-server', '-e', bad_expr,
    ], capture_output=True, text=True)
    assert bad.returncode != 0, f'Expected malformed path input to fail: {bad_expr}'
EOF
echo "PASS (Relative paths and newline/control characters fail closed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 20. Pending Boundary B Live Check Awareness Check
# ------------------------------------------------------------------------------
echo -n "[Test 20/${TOTAL_COUNT}] Boundary A vs pending Boundary B documentation hygiene... "
python3 - << 'EOF'
import os, re

puppet_dir = os.environ['PUPPET_DIR']
with open(os.path.join(puppet_dir, 'modules/jenkins/manifests/init.pp')) as f:
    init_src = f.read()
assert 'revalidated' in init_src and 'pkg.jenkins.io/debian-stable' in init_src
assert '300 MB' in init_src and 'Boundary B' in init_src

# Ensure no unauthorized EC2/private IPv4 addresses appear in jenkins module
ip_re = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')
for dirpath, _, filenames in os.walk(os.path.join(puppet_dir, 'modules/jenkins')):
    for fn in filenames:
        with open(os.path.join(dirpath, fn)) as f:
            for match in ip_re.finditer(f.read()):
                assert match.group(0) in {'127.0.0.1', '0.0.0.0'}, f'Unexpected IPv4 {match.group(0)} in {fn}'
EOF
echo "PASS (Boundary B revalidation & 300 MB headroom pending status documented; zero stray IPs)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 21. Listener Wildcard Security Review, NRPE Loopback & Backend/SG Alignment
# ------------------------------------------------------------------------------
echo -n "[Test 21/${TOTAL_COUNT}] Jenkins 0.0.0.0 wildcard rationale, NRPE 127.0.0.1:8080 & AWS SG/backend alignment... "
python3 - << 'EOF'
import json, os, re, subprocess

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.path.dirname(puppet_dir)

# 1. Verify Jenkins manifests, template, and Hiera document wildcard socket, EC2 1:1 NAT & clear layer separation
doc_expectations = [
    (os.path.join(puppet_dir, 'modules/jenkins/manifests/init.pp'),
     ['wildcard', 'Winstone/Jetty', '127.0.0.1', '1:1 NAT', 'cicd_analysis_sg', 'primary network-level', 'application-layer', 'setAllowAnonymousRead(false)', 'DefaultCrumbIssuer(true)']),
    (os.path.join(puppet_dir, 'modules/jenkins/manifests/config.pp'),
     ['wildcard', 'Winstone/Jetty', '127.0.0.1', '1:1 NAT', 'cicd_analysis_sg', 'primary network-level', 'Application-layer', 'setAllowAnonymousRead(false)', 'DefaultCrumbIssuer(true)']),
    (os.path.join(puppet_dir, 'modules/jenkins/templates/override.conf.erb'),
     ['wildcard listener', 'Winstone/Jetty', '127.0.0.1', '1:1', 'cicd_analysis_sg', 'primary network-level', 'Application-layer', 'setAllowAnonymousRead(false)', 'DefaultCrumbIssuer(true)']),
    (os.path.join(puppet_dir, 'hieradata/common.yaml'),
     ['Wildcard IPv4 bind', 'Winstone/Jetty', '127.0.0.1:8080', '1:1 NAT', 'cicd_analysis_sg', 'primary network-level', 'application-layer']),
]
for fpath, required_terms in doc_expectations:
    with open(fpath) as f:
        txt = f.read()
    normalized = ' '.join(re.sub(r'\n\s*#\s*', ' ', txt).split())
    for term in required_terms:
        assert term in normalized, f'Expected listener security rationale term {term!r} in {fpath}'
    lower_txt = normalized.lower()
    assert '0.0.0.0 is a private' not in lower_txt
    assert 'is a private-only' not in lower_txt and 'as a private-only' not in lower_txt
    assert 'mitigated by' not in lower_txt and 'mitigated via' not in lower_txt

# 2. Verify compiled catalog matches NRPE check_jenkins.sh assumptions (127.0.0.1:8080, 200|403)
res = subprocess.run([
    'puppet', 'catalog', 'find', 'cicd-server',
    '--terminus=compiler', '--certname', 'cicd-server',
    f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp', '--color=false', '--render-as=json',
], capture_output=True, text=True, check=True)
cat = json.loads(res.stdout[res.stdout.index('{'):])
by_id = {(r['type'], r['title']): r.get('parameters', {}) for r in cat['resources']}

override = by_id[('File', '/etc/systemd/system/jenkins.service.d/override.conf')]['content']
groovy = by_id[('File', '/var/lib/jenkins/init.groovy.d/01-controller-hardening.groovy')]['content']
assert 'Environment="JENKINS_PORT=8080"' in override
assert 'Environment="JENKINS_LISTEN_ADDRESS=0.0.0.0"' in override
assert 'setAllowAnonymousRead(false)' in groovy
assert 'DefaultCrumbIssuer(true)' in groovy

with open(os.path.join(puppet_dir, 'modules/nrpe/files/check_jenkins.sh')) as f:
    nrpe_src = f.read()
assert 'JENKINS_HOST="127.0.0.1"' in nrpe_src
assert 'JENKINS_PORT=8080' in nrpe_src
assert 'http://${JENKINS_HOST}:${JENKINS_PORT}/login' in nrpe_src
assert '^(200|403)$' in nrpe_src

# 3. Verify Terraform cicd_analysis_sg enforces TCP 8080 exclusively from app_monitoring_sg
with open(os.path.join(project_root, 'terraform/modules/ec2/main.tf')) as f:
    tf_src = f.read()
sg_match = re.search(
    r'resource "aws_security_group" "cicd_analysis_sg" \{(.*?)\n\}',
    tf_src,
    re.DOTALL,
)
assert sg_match, 'cicd_analysis_sg block not found in terraform/modules/ec2/main.tf'
sg_body = sg_match.group(1)
ingress_blocks = re.findall(r'ingress \{(.*?)\}', sg_body, re.DOTALL)
assert ingress_blocks, 'No ingress rules parsed in cicd_analysis_sg'
port_8080_rules = [b for b in ingress_blocks if re.search(r'from_port\s*=\s*8080\b', b)]
assert len(port_8080_rules) == 1, f'Expected single TCP 8080 ingress rule in cicd_analysis_sg, got {len(port_8080_rules)}'
rule_8080 = port_8080_rules[0]
assert 'aws_security_group.app_monitoring_sg.id' in rule_8080
assert 'cidr_blocks' not in rule_8080
for ing in ingress_blocks:
    assert '0.0.0.0/0' not in ing, f'Unexpected public 0.0.0.0/0 ingress rule in cicd_analysis_sg: {ing}'

# 4. Verify Ansible /etc/hosts & backend LiveJenkinsClient connectivity alignment
with open(os.path.join(project_root, 'ansible/roles/common/tasks/hosts.yml')) as f:
    hosts_src = f.read()
assert "hostvars['cicd-server']['private_ip']" in hosts_src

with open(os.path.join(puppet_dir, 'modules/application/templates/backend.env.erb')) as f:
    env_erb = f.read()
assert 'JENKINS_URL=<%= @jenkins_url %>' in env_erb

with open(os.path.join(project_root, 'backend/src/services/liveJenkinsClient.ts')) as f:
    live_src = f.read()
assert 'CrumbResponseSchema' in live_src
assert 'controllerOrigin' in live_src
EOF
echo "PASS (Wildcard 0.0.0.0:8080 rationale, NRPE 127.0.0.1:8080, backend connectivity & SG boundary verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Phase 7.2 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "Note: Local validation covers parser, catalog compilation, Hiera overrides,"
echo "      DAG ordering/acyclicity, isolation, and sandboxed fixture idempotency."
echo "      PENDING Boundary B: live apt install (2.580.3 + Java 21 revalidation),"
echo "      live systemd jenkins startup, live port 8080/API integration, and live"
echo "      >= 300 MB MemAvailable acceptance on the 2 GB EC2 cicd-server."
echo "=============================================================================="
