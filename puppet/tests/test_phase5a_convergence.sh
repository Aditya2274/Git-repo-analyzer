#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Phase 5A.5 — End-to-End Catalog, DAG, Targeting & Fixture Convergence
# Purpose: Integrated local validation across all Phase 5A Puppet modules
#          (common, nrpe, nagios, site.pp, Hiera v5) under Approval Boundary A.
# Scope:
#   - Manifest & YAML syntax validation
#   - Fail-closed production gate & isolated test-fixture 4-node catalog compilation
#   - Strict cross-node resource isolation across complete compiled JSON catalogs
#   - End-to-end Nagios <-> NRPE monitoring command parity across nodes
#   - Full expanded_relationships.dot DAG cycle detection & DFS reachability
#   - Fixture-level behavioral validation & Puppet Service refresh safety
#   - Cross-cutting security & hygiene assertions (distinguishing catalog/fixture vs Boundary B)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=8

echo "=============================================================================="
echo "Running Test Suite: Phase 5A.5 (Integrated Puppet Fleet Validation)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Manifest Syntax & Hiera Fail-Closed Baseline Validation
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Manifest parser validate and Hiera fail-closed baseline... "
mapfile -t PP_FILES < <(find "${PUPPET_DIR}/manifests" "${PUPPET_DIR}/modules" -type f -name '*.pp' | sort)
if [[ ${#PP_FILES[@]} -eq 0 ]]; then
  echo "FAILED: No .pp files found"
  exit 1
fi
puppet parser validate "${PP_FILES[@]}"

export PUPPET_DIR
python3 - << 'EOF'
import os, yaml

puppet_dir = os.environ['PUPPET_DIR']
with open(os.path.join(puppet_dir, 'hiera.yaml')) as f:
    hiera_cfg = yaml.safe_load(f)
assert hiera_cfg.get('version') == 5, 'hiera.yaml must use Hiera v5'

with open(os.path.join(puppet_dir, 'hieradata/common.yaml')) as f:
    common = yaml.safe_load(f)

assert common.get('nagios::web::enforce_production_secret') is True, \
    'Production Hiera MUST keep nagios::web::enforce_production_secret: true'
assert 'nagios::web::admin_password_hash' not in common, \
    'common.yaml MUST NOT ship any Nagios admin password hash'
EOF
echo "PASS (${#PP_FILES[@]} manifests valid; production Hiera fail-closed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Decoupled Zero-Secret Catalog Gate: app-server Without Secrets in Hiera
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Decoupled zero-secret catalog gate: app-server without secret... "
export PUPPET_DIR
python3 - << 'EOF'
import json, os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
res = subprocess.run([
    'puppet', 'catalog', 'find', 'app-server',
    '--terminus=compiler',
    '--certname', 'app-server',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--manifest', f'{puppet_dir}/manifests/site.pp',
    '--color=false',
    '--render-as=json',
], capture_output=True, text=True)
assert res.returncode == 0, f'app-server catalog compilation failed: {res.stderr}'
cat = json.loads(res.stdout[res.stdout.index('{'):])
ht_res = [r for r in cat['resources'] if r['type'] == 'File' and r['title'] == '/etc/nagios4/htpasswd.users']
assert len(ht_res) == 1, 'File[/etc/nagios4/htpasswd.users] must be declared in catalog'
params = ht_res[0]['parameters']
assert params.get('owner') == 'root', f"Expected owner root, got {params.get('owner')}"
assert params.get('group') == 'www-data', f"Expected group www-data, got {params.get('group')}"
assert params.get('mode') == '0640', f"Expected mode 0640, got {params.get('mode')}"
assert params.get('replace') is False, f"Expected replace => false, got {params.get('replace')}"
assert 'content' not in params or params['content'] is None, 'Secret content must NOT be managed by Puppet'
assert '$2y$' not in res.stdout and '$apr1$' not in res.stdout and '$6$' not in res.stdout, \
    'No password hash may be present in compiled catalog'
EOF
echo "PASS (app-server compiles cleanly with zero secrets; htpasswd metadata enforced without content)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Deterministic 4-Node Fleet JSON Catalog Compilation & Zero Conflicts
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Deterministic JSON catalog compilation (all fleet nodes + default)... "
export PUPPET_DIR
python3 - << 'EOF'
import json, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def compile_json(node, hiera_cfg):
    res = subprocess.run([
        'puppet', 'catalog', 'find', node,
        '--terminus=compiler',
        '--certname', node,
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={hiera_cfg}',
        '--manifest', f'{puppet_dir}/manifests/site.pp',
        '--color=false',
        '--render-as=json',
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Catalog compile failed for {node}: {res.stderr}'
    assert 'Duplicate declaration' not in res.stderr, f'Duplicate resource in {node}: {res.stderr}'
    return json.loads(res.stdout[res.stdout.index('{'):])

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

    for node in ['puppet-server', 'app-server', 'cicd-server', 'unrecognized-node.local']:
        hiera_cfg = app_hiera if node == 'app-server' else f'{puppet_dir}/hiera.yaml'
        cat1 = compile_json(node, hiera_cfg)
        cat2 = compile_json(node, hiera_cfg)
        ids1 = [(r['type'], r['title']) for r in cat1['resources']]
        ids2 = [(r['type'], r['title']) for r in cat2['resources']]
        assert len(ids1) == len(set(ids1)), f'{node}: duplicate resource IDs in catalog'
        assert ids1 == ids2, f'{node}: non-deterministic catalog resource inventory across repeated compiles'
EOF
echo "PASS (all 4 catalogs compile cleanly, zero duplicates, deterministic)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Strict Cross-Node Resource & Class Isolation Verification
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Cross-node resource & class isolation across full catalogs... "
export PUPPET_DIR
python3 - << 'EOF'
import json, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def compile_json(node, hiera_cfg):
    res = subprocess.run([
        'puppet', 'catalog', 'find', node,
        '--terminus=compiler',
        '--certname', node,
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={hiera_cfg}',
        '--manifest', f'{puppet_dir}/manifests/site.pp',
        '--color=false',
        '--render-as=json',
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Catalog compile failed for {node}: {res.stderr}'
    return json.loads(res.stdout[res.stdout.index('{'):])

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

    cats = {
        'puppet-server': compile_json('puppet-server', f'{puppet_dir}/hiera.yaml'),
        'cicd-server': compile_json('cicd-server', f'{puppet_dir}/hiera.yaml'),
        'app-server': compile_json('app-server', app_hiera),
        'unrecognized-node.local': compile_json('unrecognized-node.local', f'{puppet_dir}/hiera.yaml'),
    }

def res_set(cat):
    return {(r['type'], r['title']) for r in cat['resources']}

def class_set(cat):
    return set(cat.get('classes', []))

# puppet-server (EC2 1)
p_res, p_cls = res_set(cats['puppet-server']), class_set(cats['puppet-server'])
assert {'common', 'nrpe::server'}.issubset(p_cls)
assert 'nagios' not in p_cls and 'nrpe::client' not in p_cls
assert ('Service', 'puppet') in p_res
assert ('Service', 'puppetserver') not in p_res, 'common module must not manage puppetserver daemon'
assert ('Service', 'nagios-nrpe-server') in p_res
assert ('File', '/usr/lib/nagios/plugins/check_puppetserver.sh') in p_res
assert ('File', '/usr/lib/nagios/plugins/check_jenkins.sh') not in p_res
assert ('File', '/usr/lib/nagios/plugins/check_docker.sh') not in p_res
assert ('Package', 'nagios4') not in p_res and ('Package', 'apache2') not in p_res
assert ('Package', 'nagios-nrpe-plugin') not in p_res

# cicd-server (EC2 3)
c_res, c_cls = res_set(cats['cicd-server']), class_set(cats['cicd-server'])
assert {'common', 'nrpe::server'}.issubset(c_cls)
assert 'nagios' not in c_cls and 'nrpe::client' not in c_cls
assert ('Service', 'puppet') in c_res
assert ('Service', 'nagios-nrpe-server') in c_res
assert ('File', '/usr/lib/nagios/plugins/check_jenkins.sh') in c_res
assert ('File', '/usr/lib/nagios/plugins/check_docker.sh') in c_res
assert ('File', '/usr/lib/nagios/plugins/check_puppetserver.sh') not in c_res
assert ('Package', 'nagios4') not in c_res and ('Package', 'apache2') not in c_res
assert ('Package', 'nagios-nrpe-plugin') not in c_res

# app-server (EC2 2)
a_res, a_cls = res_set(cats['app-server']), class_set(cats['app-server'])
assert {'common', 'nrpe::client', 'nagios', 'nagios::install_guard', 'nagios::server', 'nagios::objects', 'nagios::web'}.issubset(a_cls)
assert 'nrpe::server' not in a_cls
assert ('Service', 'puppet') in a_res
assert ('Package', 'nagios-nrpe-plugin') in a_res
assert ('Package', 'nagios4') in a_res and ('Package', 'apache2') in a_res
assert ('Package', 'monitoring-plugins-basic') in a_res
assert ('Service', 'nagios4') in a_res and ('Service', 'apache2') in a_res
assert ('Service', 'nagios-nrpe-server') not in a_res
assert ('Package', 'nagios-nrpe-server') not in a_res
assert ('File', '/etc/nagios/nrpe.cfg') not in a_res

# default / unrecognized node
d_res, d_cls = res_set(cats['unrecognized-node.local']), class_set(cats['unrecognized-node.local'])
assert 'common' in d_cls
assert not ({'nrpe::server', 'nrpe::client', 'nagios'} & d_cls)
assert ('Service', 'puppet') in d_res
assert ('Service', 'nagios-nrpe-server') not in d_res
assert ('Package', 'nagios4') not in d_res and ('Package', 'apache2') not in d_res
EOF
echo "PASS (strict node isolation verified across all 4 compiled catalogs)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. End-to-End Nagios <-> NRPE Monitoring Command & Loopback Parity
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Cross-node Nagios <-> NRPE monitoring contract parity... "
export PUPPET_DIR
python3 - << 'EOF'
import json, os, re, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def compile_json(node, hiera_cfg):
    res = subprocess.run([
        'puppet', 'catalog', 'find', node,
        '--terminus=compiler',
        '--certname', node,
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={hiera_cfg}',
        '--manifest', f'{puppet_dir}/manifests/site.pp',
        '--color=false',
        '--render-as=json',
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Catalog compile failed for {node}: {res.stderr}'
    return json.loads(res.stdout[res.stdout.index('{'):])

def file_content(cat, path):
    for r in cat['resources']:
        if r['type'] == 'File' and r['title'] == path:
            return r['parameters']['content']
    raise AssertionError(f'Missing File[{path}]')

def parse_nrpe_commands(nrpe_cfg):
    return set(re.findall(r'^command\[([^\]]+)\]=', nrpe_cfg, flags=re.MULTILINE))

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

    p_cat = compile_json('puppet-server', f'{puppet_dir}/hiera.yaml')
    c_cat = compile_json('cicd-server', f'{puppet_dir}/hiera.yaml')
    a_cat = compile_json('app-server', app_hiera)

p_cmds = parse_nrpe_commands(file_content(p_cat, '/etc/nagios/nrpe.cfg'))
c_cmds = parse_nrpe_commands(file_content(c_cat, '/etc/nagios/nrpe.cfg'))

assert 'check_puppetserver' in p_cmds
assert 'check_jenkins' not in p_cmds and 'check_docker' not in p_cmds
assert {'check_jenkins', 'check_docker'}.issubset(c_cmds)
assert 'check_puppetserver' not in c_cmds

services_cfg = file_content(a_cat, '/etc/nagios4/conf.d/services.cfg')
commands_cfg = file_content(a_cat, '/etc/nagios4/conf.d/commands.cfg')
hosts_cfg = file_content(a_cat, '/etc/nagios4/conf.d/hosts.cfg')
ports_conf = file_content(a_cat, '/etc/apache2/ports.conf')
nagios_vhost = file_content(a_cat, '/etc/apache2/sites-available/nagios.conf')

# Verify every check_nrpe!<command> invoked per host in Nagios services.cfg exists on that host's nrpe.cfg
host_checks = {'puppet-server': [], 'cicd-server': [], 'app-server': []}
for block in re.findall(r'define service\s*\{(.*?)\}', services_cfg, flags=re.DOTALL):
    host_m = re.search(r'^\s*host_name\s+(\S+)', block, flags=re.MULTILINE)
    cmd_m = re.search(r'^\s*check_command\s+(.+?)\s*$', block, flags=re.MULTILINE)
    if host_m and cmd_m:
        host_checks.setdefault(host_m.group(1), []).append(cmd_m.group(1))

assert host_checks['puppet-server'] and host_checks['cicd-server'] and host_checks['app-server']
for h, cmds in host_checks.items():
    for cmd in cmds:
        if cmd.startswith('check_nrpe!'):
            nrpe_cmd = cmd.split('!', 1)[1]
            target_cmds = p_cmds if h == 'puppet-server' else c_cmds
            assert nrpe_cmd in target_cmds, f'Nagios invokes {nrpe_cmd} on {h}, missing in nrpe.cfg ({target_cmds})'

assert any(c == 'check_nrpe!check_puppetserver' for c in host_checks['puppet-server'])
assert all('check_jenkins' not in c and 'check_docker' not in c for c in host_checks['puppet-server'])
assert any(c == 'check_nrpe!check_jenkins' for c in host_checks['cicd-server'])
assert any(c == 'check_nrpe!check_docker' for c in host_checks['cicd-server'])
assert all('check_puppetserver' not in c for c in host_checks['cicd-server'])
assert all(not c.startswith('check_nrpe!') for c in host_checks['app-server'])

# Verify all 3 hosts declared in hosts.cfg, $ARG1$-only check_nrpe, and loopback Apache 127.0.0.1:8080
for host in ['puppet-server', 'app-server', 'cicd-server']:
    assert f'host_name' in hosts_cfg and host in hosts_cfg
check_nrpe_cmd = re.search(
    r'define command\s*\{[^}]*command_name\s+check_nrpe\b[^}]*command_line\s+([^\n]+)',
    commands_cfg,
)
assert check_nrpe_cmd, 'Missing check_nrpe command definition in commands.cfg'
assert re.search(r'check_nrpe\s+-H\s+\$HOSTADDRESS\$\s+-c\s+\$ARG1\$', check_nrpe_cmd.group(1))
assert '$ARG2$' not in check_nrpe_cmd.group(1) and '$ARG3$' not in check_nrpe_cmd.group(1)
assert 'Listen 127.0.0.1:8080' in ports_conf and 'Listen 80\n' not in ports_conf
assert '<VirtualHost 127.0.0.1:8080>' in nagios_vhost
EOF
echo "PASS (Nagios services.cfg <-> NRPE commands.cfg & loopback contract verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Full DAG Cycle Detection & Critical Reachability (--graph dot verification)
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Full --graph DAG cycle detection & DFS ordering verification... "
export PUPPET_DIR
python3 - << 'EOF'
from collections import defaultdict, deque
import os, re, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def load_dot_graph(node, hiera_cfg):
    with tempfile.TemporaryDirectory() as gdir:
        res = subprocess.run([
            'puppet', 'apply', '--noop', '--graph', f'--graphdir={gdir}',
            f'--modulepath={puppet_dir}/modules',
            f'--hiera_config={hiera_cfg}',
            '--certname', node,
            f'{puppet_dir}/manifests/site.pp',
        ], capture_output=True, text=True)
        assert res.returncode == 0, f'Graph compilation failed for {node}: {res.stderr}'
        assert 'dependency cycle' not in (res.stdout + res.stderr).lower(), f'Cycle reported for {node}'
        dot_path = os.path.join(gdir, 'expanded_relationships.dot')
        assert os.path.isfile(dot_path), f'Missing expanded_relationships.dot for {node}'
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
        return nodes, edges

def assert_acyclic(node, nodes, edges):
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
    assert visited == len(nodes), f'{node}: DAG cycle detected in expanded_relationships.dot ({visited}/{len(nodes)})'

def reachable(edges, src, dst):
    seen = {src}
    q = deque([src])
    while q:
        u = q.popleft()
        if u == dst:
            return True
        for v in edges.get(u, ()):
            if v not in seen:
                seen.add(v)
                q.append(v)
    return False

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

    graphs = {
        'puppet-server': load_dot_graph('puppet-server', f'{puppet_dir}/hiera.yaml'),
        'cicd-server': load_dot_graph('cicd-server', f'{puppet_dir}/hiera.yaml'),
        'app-server': load_dot_graph('app-server', app_hiera),
    }

for node, (nodes, edges) in graphs.items():
    assert_acyclic(node, nodes, edges)
    # Baseline common class chain on every node
    assert reachable(edges, 'Package[curl]', 'File[/etc/timezone]')
    assert reachable(edges, 'File[/etc/timezone]', 'File[/etc/localtime]')
    assert reachable(edges, 'File[/etc/localtime]', 'Service[puppet]')

# Class stage ordering on each node
assert reachable(graphs['puppet-server'][1], 'Whit[Completed_class[Common]]', 'Whit[Admissible_class[Nrpe::Server]]')
assert reachable(graphs['cicd-server'][1], 'Whit[Completed_class[Common]]', 'Whit[Admissible_class[Nrpe::Server]]')
assert reachable(graphs['app-server'][1], 'Whit[Completed_class[Common]]', 'Whit[Admissible_class[Nrpe::Client]]')
assert reachable(graphs['app-server'][1], 'Whit[Completed_class[Nrpe::Client]]', 'Whit[Admissible_class[Nagios]]')

# NRPE complete chain on puppet-server and cicd-server
for node, custom_scripts in [
    ('puppet-server', ['File[/usr/lib/nagios/plugins/check_puppetserver.sh]']),
    ('cicd-server', ['File[/usr/lib/nagios/plugins/check_jenkins.sh]', 'File[/usr/lib/nagios/plugins/check_docker.sh]']),
]:
    e = graphs[node][1]
    assert reachable(e, 'Package[nagios-nrpe-server]', 'File[/etc/nagios]')
    assert reachable(e, 'File[/etc/nagios]', 'File[/etc/nagios/nrpe.d]')
    assert reachable(e, 'File[/etc/nagios/nrpe.d]', 'File[/etc/nagios/nrpe.cfg]')
    assert reachable(e, 'File[/etc/nagios/nrpe.cfg]', 'Service[nagios-nrpe-server]')
    assert reachable(e, 'Package[monitoring-plugins-basic]', 'File[/usr/lib/nagios/plugins]')
    assert reachable(e, 'Package[monitoring-plugins-basic]', 'Service[nagios-nrpe-server]')
    for sc in custom_scripts:
        assert reachable(e, 'File[/usr/lib/nagios/plugins]', sc)
        assert reachable(e, sc, 'Service[nagios-nrpe-server]')

# App-server full Nagios chain
ae = graphs['app-server'][1]
for pkg in ['Package[nagios4]', 'Package[monitoring-plugins-basic]', 'Package[apache2]', 'Package[apache2-utils]']:
    assert reachable(ae, 'Exec[nagios_enable_policy_rc_d]', pkg)
    assert reachable(ae, pkg, 'Exec[nagios_disable_policy_rc_d]')
assert reachable(ae, 'Exec[nagios_disable_policy_rc_d]', 'File[/etc/nagios4/nagios.cfg]')
assert reachable(ae, 'Exec[nagios_disable_policy_rc_d]', 'File[/etc/apache2/ports.conf]')
assert reachable(ae, 'File[/etc/nagios4/nagios.cfg]', 'Exec[nagios4_configtest]')
assert reachable(ae, 'File[/etc/nagios4/conf.d/services.cfg]', 'Exec[nagios4_configtest]')
assert reachable(ae, 'Exec[nagios4_configtest]', 'Service[nagios4]')
assert reachable(ae, 'Exec[nagios4_configtest_before_start]', 'Service[nagios4]')
assert reachable(ae, 'File[/etc/apache2/ports.conf]', 'Exec[apache2_configtest]')
assert reachable(ae, 'File[/etc/apache2/sites-available/nagios.conf]', 'Exec[apache2_configtest]')
assert reachable(ae, 'File[/etc/nagios4/htpasswd.users]', 'Exec[apache2_configtest]')
assert reachable(ae, 'Exec[apache2_configtest]', 'Service[apache2]')
assert reachable(ae, 'Exec[apache2_configtest_before_start]', 'Service[apache2]')
EOF
echo "PASS (zero cycles; all common -> nrpe -> nagios critical paths verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Fixture-Level Convergence, Validation Gate & Stopped-Service Safety
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Fixture-level apply convergence, validate_cmd gate & stopped service safety... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

# A. Fixture-level apply convergence (--detailed-exitcodes: 2 on initial converge -> 0 on re-apply)
#    plus malformed validate_cmd failing BEFORE notifying consumer (mock service restart)
with tempfile.TemporaryDirectory() as tmpdir:
    cfg = os.path.join(tmpdir, 'nrpe.cfg')
    restart_marker = os.path.join(tmpdir, 'restarted.count')
    valid_content = (
        "log_facility=daemon\n"
        "server_port=5666\n"
        "allowed_hosts=127.0.0.1,::1,app-server\n"
        "dont_blame_nrpe=0\n"
        "pid_file=/run/nagios/nrpe.pid\n"
    )
    validate_cmd = "/usr/bin/awk '/^[[:space:]]*(#|$)/ {next} /=/ {found++; next} {exit 1} END {exit (found >= 5 ? 0 : 1)}' %"

    def build_manifest(content):
        return f"""
file {{ '{cfg}':
  ensure       => file,
  mode         => '0644',
  content      => '{content}',
  validate_cmd => "{validate_cmd}",
  notify       => Exec['mock_service_refresh'],
}}
exec {{ 'mock_service_refresh':
  command     => '/bin/sh -c "echo tick >> {restart_marker}"',
  refreshonly => true,
}}
"""

    # Run 1: initial convergence -> exit 2, notification fires once
    r1 = subprocess.run([
        'puppet', 'apply', '--detailed-exitcodes', '-e', build_manifest(valid_content)
    ], capture_output=True, text=True)
    assert r1.returncode == 2, f'Initial fixture apply expected exit 2, got {r1.returncode}: {r1.stderr}'
    assert os.path.isfile(restart_marker) and len(open(restart_marker).read().splitlines()) == 1

    # Run 2: repeat convergence -> exit 0, zero changes, zero notifications
    r2 = subprocess.run([
        'puppet', 'apply', '--detailed-exitcodes', '-e', build_manifest(valid_content)
    ], capture_output=True, text=True)
    assert r2.returncode == 0, f'Repeat fixture apply expected exit 0 (converged), got {r2.returncode}: {r2.stderr}'
    assert len(open(restart_marker).read().splitlines()) == 1, 'Converged re-apply must not notify consumer'

    # Run 3: malformed config fails validate_cmd -> exit 4/6, original valid file preserved, zero notifications
    r3 = subprocess.run([
        'puppet', 'apply', '--detailed-exitcodes', '-e', build_manifest("BROKEN_LINE_WITHOUT_EQUALS\n")
    ], capture_output=True, text=True)
    assert r3.returncode in (4, 6), f'Malformed config MUST fail validation (4/6), got {r3.returncode}'
    assert open(cfg).read() == valid_content, 'Original valid file must remain untouched on validation failure'
    assert len(open(restart_marker).read().splitlines()) == 1, 'Failed validation must not fire service notify'

# B. Verify Puppet 8 Service#refresh skips restart when service is intentionally stopped
ruby_check = r"""
require 'puppet'
Puppet.initialize_settings
res = Puppet::Type.type(:service).new(name: 'nagios-nrpe-server', ensure: :stopped, enable: false)
prov = res.provider
prov.define_singleton_method(:status) { :stopped }
restarted = false
prov.define_singleton_method(:restart) { restarted = true }
res.refresh
abort('Service#refresh unexpectedly triggered restart while stopped!') if restarted
"""
r_ruby = subprocess.run(['ruby', '-e', ruby_check], capture_output=True, text=True)
assert r_ruby.returncode == 0, f'Puppet Service#refresh stopped check failed: {r_ruby.stderr}'
EOF
echo "PASS (fixture apply exit 2->0 converged; validate_cmd fail-closed; Puppet Service#refresh safe when stopped)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Cross-Cutting Security & Hardcoding Hygiene Audit
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Cross-cutting security & zero-hardcoded-IP hygiene audit... "
export PUPPET_DIR
python3 - << 'EOF'
import os, re

puppet_dir = os.environ['PUPPET_DIR']
ip_re = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')
allowed_ips = {'127.0.0.1', '0.0.0.0'}

scan_roots = [
    os.path.join(puppet_dir, 'manifests'),
    os.path.join(puppet_dir, 'hieradata'),
    os.path.join(puppet_dir, 'modules'),
]

for root in scan_roots:
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(('.pp', '.erb', '.yaml', '.yml', '.sh')):
                continue
            fpath = os.path.join(dirpath, fn)
            with open(fpath) as f:
                content = f.read()
            for match in ip_re.finditer(content):
                ip = match.group(0)
                assert ip in allowed_ips, f'Unexpected IPv4 address {ip} found in {fpath}'

# Verify negative non-execution safety rule on existing admin policy-rc.d script
tpl_path = os.path.join(puppet_dir, 'modules/nagios/templates/enable_policy_rc_d.sh.erb')
with open(tpl_path) as f:
    tpl = f.read()
assert 'exec env -i' not in tpl, 'enable_policy_rc_d.sh.erb must never execute admin policy-rc.d'
EOF
echo "PASS (zero hardcoded EC2 IPs; non-execution fail-closed policy verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Phase 5A.5 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "Note: Local validation covers catalog compilation, DAG ordering, node"
echo "      targeting, and fixture convergence. Live OS package/systemd convergence"
echo "      and end-to-end NRPE/Nagios runtime checks require EC2 provisioning (Boundary B)."
echo "=============================================================================="
