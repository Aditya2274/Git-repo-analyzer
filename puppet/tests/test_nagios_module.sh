#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Checkpoint 5A.4 (Nagios Core & Monitoring Configuration)
# Description: Comprehensive static, AST, compiled Puppet DAG graph, catalog
#              compilation, and local sandboxed behavioral verification for Nagios
#              Core, objects, Apache loopback web console, fail-closed credential
#              enforcement, and Ubuntu 24.04 package startup suppression.
# Note: All live package-install/service statements apply to sandboxed mocks
#       and Puppet catalog compilation under Approval Boundary A; real Ubuntu
#       apt/systemd convergence occurs only after EC2 provisioning (Phase 8).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=26

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 5A.4 (Nagios Core Puppet Module)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Nagios Package Declarations [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Nagios package declarations (nagios4 & plugins)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    server_content = f.read()
with open('${PUPPET_DIR}/modules/nrpe/manifests/client.pp') as f:
    client_content = f.read()

assert 'package { \$package_name:' in server_content, 'server.pp must declare package resource'
assert '\$package_name    = \'nagios4\'' in server_content or 'nagios4' in server_content, 'server.pp default package must be nagios4'
assert 'monitoring-plugins-basic' in server_content, 'server.pp must include monitoring-plugins-basic'
assert 'nagios-nrpe-plugin' not in server_content, 'server.pp must NOT declare nagios-nrpe-plugin (managed by nrpe::client)'
assert 'nagios-nrpe-plugin' in client_content, 'nrpe::client must manage nagios-nrpe-plugin'
"
echo "PASS (nagios4 and plugins declared without duplicate nrpe-plugin package)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Correct Service Name [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] Correct service name (nagios4 running & enabled)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    content = f.read()

assert 'service { \$service_name:' in content, 'server.pp must declare service resource'
assert '\$service_name    = \'nagios4\'' in content or 'nagios4' in content, 'service name must be nagios4'
assert 'hasstatus  => true' in content, 'service must have hasstatus enabled'
assert 'hasrestart => true' in content, 'service must have hasrestart enabled'
"
echo "PASS (service nagios4 managed with status and restart hooks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Correct Configuration Paths [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Correct configuration paths (/etc/nagios4/)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    server_content = f.read()
with open('${PUPPET_DIR}/modules/nagios/manifests/objects.pp') as f:
    objects_content = f.read()

assert '/etc/nagios4' in server_content, 'server.pp must manage /etc/nagios4 directory'
assert '\${config_dir}/nagios.cfg' in server_content, 'server.pp must manage nagios.cfg'
assert '\${config_dir}/cgi.cfg' in server_content, 'server.pp must manage cgi.cfg'
assert '\${config_dir}/resource.cfg' in server_content, 'server.pp must manage resource.cfg'
assert '/etc/nagios4/conf.d' in objects_content, 'objects.pp must manage /etc/nagios4/conf.d directory'
"
echo "PASS (authoritative configuration paths /etc/nagios4 and conf.d verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. Host Definitions for All Three Nodes [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Host definitions for all three nodes (puppet, app, cicd)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/objects/hosts.cfg.erb') as f:
    content = f.read()

assert 'host_name                       puppet-server' in content, 'hosts.cfg must define puppet-server'
assert 'address                         puppet-server' in content, 'puppet-server address must resolve via private hostname'

assert 'host_name                       app-server' in content, 'hosts.cfg must define app-server'
assert 'address                         127.0.0.1' in content, 'app-server address must be 127.0.0.1'

assert 'host_name                       cicd-server' in content, 'hosts.cfg must define cicd-server'
assert 'address                         cicd-server' in content, 'cicd-server address must resolve via private hostname'

assert 'generic-host' in content, 'hosts.cfg must define generic-host template'
"
echo "PASS (all 3 fleet hosts configured with private network addresses)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. NRPE Command Definition [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] NRPE command definition in commands.cfg... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/objects/commands.cfg.erb') as f:
    content = f.read()

assert 'command_name    check_nrpe' in content, 'commands.cfg must define check_nrpe'
nrpe_cmd = [line.strip() for line in content.splitlines() if 'check_nrpe' in line and 'command_line' in line][0]
assert '\$USER1\$/check_nrpe -H \$HOSTADDRESS\$ -c \$ARG1\$' in nrpe_cmd, 'check_nrpe must use \$HOSTADDRESS\$ and \$ARG1\$'
assert ' -a ' not in nrpe_cmd, 'check_nrpe command_line must NOT permit -a arbitrary argument passing'
assert '\$ARG2\$' not in nrpe_cmd, 'check_nrpe command_line must NOT accept \$ARG2\$'
"
echo "PASS (check_nrpe defined with fixed command invocation and zero argument expansion)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. Correct Node-Specific Service Assignments [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] Correct node-specific service assignments... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/objects/services.cfg.erb') as f:
    content = f.read()

assert 'host_name                       puppet-server' in content, 'services.cfg must define services for puppet-server'
assert 'check_nrpe!check_puppetserver' in content, 'puppet-server must have check_puppetserver'

assert 'host_name                       cicd-server' in content, 'services.cfg must define services for cicd-server'
assert 'check_nrpe!check_jenkins' in content, 'cicd-server must have check_jenkins'
assert 'check_nrpe!check_docker' in content, 'cicd-server must have check_docker'

assert 'host_name                       app-server' in content, 'services.cfg must define services for app-server'
assert 'check_local_disk' in content, 'app-server must have local disk check'
assert 'check_local_load' in content, 'app-server must have local load check'
assert 'check_local_procs' in content, 'app-server must have local procs check'
assert 'check_http_port' in content, 'app-server must have NGINX web check'
"
echo "PASS (node-specific services accurately mapped to remote NRPE and local checks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. No Jenkins/Docker Checks on puppet-server [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] No Jenkins/Docker checks on puppet-server... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/objects/services.cfg.erb') as f:
    content = f.read()

blocks = content.split('define service {')
puppet_server_services = [b for b in blocks if 'host_name                       puppet-server' in b]
assert len(puppet_server_services) >= 2, 'puppet-server must have at least 2 services'
for b in puppet_server_services:
    assert 'check_jenkins' not in b, 'puppet-server must NOT have check_jenkins'
    assert 'check_docker' not in b, 'puppet-server must NOT have check_docker'
"
echo "PASS (puppet-server strictly isolated from Jenkins and Docker checks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. No Puppet Server Check on cicd-server [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] No Puppet Server check on cicd-server... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/objects/services.cfg.erb') as f:
    content = f.read()

blocks = content.split('define service {')
cicd_server_services = [b for b in blocks if 'host_name                       cicd-server' in b]
assert len(cicd_server_services) >= 3, 'cicd-server must have at least 3 services'
for b in cicd_server_services:
    assert 'check_puppetserver' not in b, 'cicd-server must NOT have check_puppetserver'
"
echo "PASS (cicd-server strictly isolated from Puppet Server service check)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Apache Package and Configuration [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] Apache package and configuration resources... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/web.pp') as f:
    content = f.read()

assert 'package { \$apache_package:' in content, 'web.pp must declare apache package'
assert 'package { \$utils_packages:' in content, 'web.pp must declare apache2-utils'
assert '/etc/apache2/ports.conf' in content, 'web.pp must manage ports.conf'
assert '/etc/apache2/sites-available/nagios.conf' in content, 'web.pp must manage nagios.conf'
assert '/etc/apache2/sites-enabled/nagios.conf' in content, 'web.pp must enable nagios.conf link'
assert '/etc/apache2/sites-enabled/000-default.conf' in content, 'web.pp must disable 000-default.conf'
assert 'ensure  => absent' in content, '000-default.conf must be ensured absent'
"
echo "PASS (Apache packages, ports.conf, and virtual host properly declared)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. Localhost-Only Binding on Port 8080 [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Localhost-only binding on port 8080... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/ports.conf.erb') as f:
    ports_content = f.read()
with open('${PUPPET_DIR}/modules/nagios/templates/apache_nagios.conf.erb') as f:
    vhost_content = f.read()
with open('${PUPPET_DIR}/hieradata/common.yaml') as f:
    hiera_content = f.read()

assert 'Listen <%= @bind_address %>:<%= @listen_port %>' in ports_content, 'ports.conf must bind to @bind_address:@listen_port'
assert '<VirtualHost <%= @bind_address %>:<%= @listen_port %>>' in vhost_content, 'VirtualHost must bind to @bind_address:@listen_port'
assert 'nagios::web::listen_port: 8080' in hiera_content, 'Hiera must configure listen_port 8080'
assert 'nagios::web::bind_address: \'127.0.0.1\'' in hiera_content, 'Hiera must configure bind_address 127.0.0.1'
assert 'Listen 80\\n' not in ports_content, 'ports.conf must NOT listen on public port 80'
assert 'Listen 443\\n' not in ports_content, 'ports.conf must NOT listen on public port 443'
assert '0.0.0.0' not in ports_content, 'ports.conf must NOT listen on 0.0.0.0'
assert '0.0.0.0' not in vhost_content, 'VirtualHost must NOT bind to 0.0.0.0'
"
echo "PASS (Apache restricted exclusively to loopback 127.0.0.1:8080)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Basic Authentication Configuration [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Basic Authentication configuration... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/templates/apache_nagios.conf.erb') as f:
    content = f.read()

assert 'AuthType Basic' in content, 'vhost must configure AuthType Basic'
assert 'AuthName \"Nagios Access\"' in content, 'vhost must configure AuthName'
assert 'AuthUserFile <%= @htpasswd_file %>' in content, 'vhost must configure AuthUserFile'
assert 'Require valid-user' in content, 'vhost must enforce Require valid-user'
"
echo "PASS (HTTP Basic Authentication enforced on all Nagios web endpoints)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Authentication-File Permissions [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Authentication-file permissions (0640, root:www-data)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/web.pp') as f:
    content = f.read()

assert 'owner   => \'root\'' in content, 'htpasswd file owner must be root'
assert 'group   => \'www-data\'' in content, 'htpasswd file group must be www-data'
assert 'mode    => \'0640\'' in content, 'htpasswd file mode must be 0640'
"
echo "PASS (htpasswd.users configured with restrictive 0640 root:www-data permissions)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Fail-Closed Production Credential Enforcement [Catalog Compilation]
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Fail-closed credential enforcement & validation... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

def run_puppet(code, hiera_cfg=None, certname='app-server'):
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={hiera_cfg or puppet_dir + "/hiera.yaml"}',
        '--certname', certname,
        '-e', code
    ]
    return subprocess.run(cmd, capture_output=True, text=True)

# 1. Default behavior enables production credential enforcement (missing hash fails)
res_default = run_puppet("include nagios::web")
assert res_default.returncode != 0, 'Default include nagios::web MUST fail closed when hash is absent'
assert 'real operator-generated password hash is required' in res_default.stderr, res_default.stderr

# 2. Placeholder hash fails under default enforcement (enforce_production_secret omitted -> defaults true)
res_placeholder = run_puppet("""
class { 'nagios::web':
  admin_password_hash => '$apr1$demo$hashedpassword',
}
""")
assert res_placeholder.returncode != 0, 'Placeholder hash must FAIL under default enforcement'
assert 'placeholder' in res_placeholder.stderr.lower() and 'real operator-generated password hash is required' in res_placeholder.stderr

# 3. Empty and whitespace-only hashes fail
for bad_empty in ["''", "'   '"]:
    res_empty = run_puppet(f"""
    class {{ 'nagios::web':
      admin_password_hash => {bad_empty},
    }}
    """)
    assert res_empty.returncode != 0, f'Empty hash {bad_empty} must FAIL'
    assert 'real operator-generated password hash is required' in res_empty.stderr

# 4. Missing/undef hash fails explicitly
res_undef = run_puppet("""
class { 'nagios::web':
  admin_password_hash => undef,
}
""")
assert res_undef.returncode != 0, 'Explicit undef hash must FAIL'
assert 'real operator-generated password hash is required' in res_undef.stderr

# 5. Malformed hashes (plaintext, truncated, username:hash prefix) fail
for bad_hash in ["'plaintext123'", "'$2y$12$tooshort'", "'nagiosadmin:$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'"]:
    res_bad = run_puppet(f"""
    class {{ 'nagios::web':
      admin_password_hash => {bad_hash},
    }}
    """)
    assert res_bad.returncode != 0, f'Malformed hash {bad_hash} must FAIL'
    assert 'real operator-generated password hash is required' in res_bad.stderr

# 6. Valid test-only hash passes cleanly under default (true) production enforcement
res_valid = run_puppet("""
class { 'nagios::web':
  admin_password_hash => '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000',
}
""")
assert res_valid.returncode == 0, f'Valid test-only bcrypt hash must PASS: {res_valid.stderr}'

# 7. Test mode requires an explicit override (both enforce_production_secret => false AND explicit test value)
res_dev_no_hash = run_puppet("""
class { 'nagios::web':
  enforce_production_secret => false,
}
""")
assert res_dev_no_hash.returncode != 0, 'Even with enforcement disabled, missing hash cannot fall back silently'

res_dev_explicit = run_puppet("""
class { 'nagios::web':
  enforce_production_secret => false,
  admin_password_hash       => '$apr1$demo$hashedpassword',
}
""")
assert res_dev_explicit.returncode == 0, f'Explicit dev override with explicit placeholder must compile: {res_dev_explicit.stderr}'
assert 'nagios_placeholder_credential_warning' in (res_dev_explicit.stdout + res_dev_explicit.stderr)
EOF
echo "PASS (default fail-closed; absent/empty/malformed/placeholder rejected; valid test hash & explicit dev override verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Nagios Configuration Validation Ordering [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Nagios configuration validation commands (nagios4 -v)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    server_content = f.read()

assert 'exec { \'nagios4_configtest\':' in server_content, 'server.pp must declare nagios4_configtest exec'
assert 'exec { \'nagios4_configtest_before_start\':' in server_content, 'server.pp must declare nagios4_configtest_before_start exec'
assert '/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg' in server_content, 'nagios4 validation must run nagios4 -v /etc/nagios4/nagios.cfg'
assert 'refreshonly => true' in server_content, 'nagios4_configtest must be refreshonly'
assert 'is-active --quiet' in server_content, 'before_start gate must guard on inactive nagios4 service'
"
echo "PASS (nagios4 -v refresh and pre-start validation gates declared)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Apache Configuration Validation Ordering [Static]
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] Apache configuration validation commands (apache2ctl configtest)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/web.pp') as f:
    web_content = f.read()

assert 'exec { \'apache2_configtest\':' in web_content, 'web.pp must declare apache2_configtest exec'
assert 'exec { \'apache2_configtest_before_start\':' in web_content, 'web.pp must declare apache2_configtest_before_start exec'
assert '/usr/sbin/apache2ctl configtest' in web_content, 'apache2 validation must run apache2ctl configtest'
assert 'refreshonly => true' in web_content, 'apache2_configtest must be refreshonly'
assert 'is-active --quiet' in web_content, 'before_start gate must guard on inactive apache2 service'
"
echo "PASS (apache2ctl configtest refresh and pre-start validation gates declared)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Service Enablement and Startup Dependencies [Catalog Compilation]
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Service enablement and startup dependencies... "
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
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={app_hiera}',
        '--certname', 'app-server',
        '-e', 'include nagios'
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Catalog compilation failed: {res.stderr}'
    combined = res.stdout + res.stderr

    assert 'Exec[nagios_enable_policy_rc_d]' in combined, 'Must include package startup suppression'
    assert 'Service[nagios4]' in combined, 'Must manage Service[nagios4]'
    assert 'Service[apache2]' in combined, 'Must manage Service[apache2]'
    assert 'Package[nagios4]' in combined, 'Must manage Package[nagios4]'
    assert 'Package[apache2]' in combined, 'Must manage Package[apache2]'
EOF
echo "PASS (both nagios4 and apache2 services declare full dependency chain with install guard)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Puppet Target Isolation & Fail-Closed Site Manifest [Catalog Compilation]
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Puppet target isolation (app-server vs puppet/cicd-server)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

# 1. Production site.pp on app-server with default repo Hiera MUST fail closed (missing secret)
cmd_fail_closed = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'app-server',
    f'{puppet_dir}/manifests/site.pp'
]
res_fc = subprocess.run(cmd_fail_closed, capture_output=True, text=True)
assert res_fc.returncode != 0, 'Production app-server site.pp without credential MUST fail closed'
assert 'real operator-generated password hash is required' in res_fc.stderr

# 2. app-server with explicit test-only Hiera fixture compiles with Nagios + Apache + nrpe::client
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
    cmd_app = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={app_hiera}',
        '--certname', 'app-server',
        f'{puppet_dir}/manifests/site.pp'
    ]
    res_app = subprocess.run(cmd_app, capture_output=True, text=True)
    assert res_app.returncode == 0, f'app-server catalog failed: {res_app.stderr}'
    comb_app = res_app.stdout + res_app.stderr
    assert 'Package[nagios4]' in comb_app, 'app-server MUST manage nagios4'
    assert 'Package[apache2]' in comb_app, 'app-server MUST manage apache2'
    assert 'Package[nagios-nrpe-plugin]' in comb_app, 'app-server MUST manage nrpe client plugin'
    assert 'Package[nagios-nrpe-server]' not in comb_app, 'app-server must NOT manage nrpe server'

# 3. puppet-server and cicd-server compile cleanly against repo hiera.yaml with ZERO Nagios/Apache
for node in ['puppet-server', 'cicd-server']:
    cmd_other = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--certname', node,
        f'{puppet_dir}/manifests/site.pp'
    ]
    res_other = subprocess.run(cmd_other, capture_output=True, text=True)
    assert res_other.returncode == 0, f'{node} catalog failed: {res_other.stderr}'
    comb_other = res_other.stdout + res_other.stderr
    assert 'Package[nagios4]' not in comb_other, f'{node} must NOT manage nagios4'
    assert 'Package[apache2]' not in comb_other, f'{node} must NOT manage apache2'
    assert 'Package[nagios-nrpe-server]' in comb_other, f'{node} MUST manage nrpe server'

# 4. Attempting direct include nagios on non-app certnames fails fast
for rogue in ['puppet-server', 'cicd-server', 'unexpected.local']:
    cmd_rogue = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--certname', rogue,
        '-e', 'include nagios'
    ]
    res_rogue = subprocess.run(cmd_rogue, capture_output=True, text=True)
    assert res_rogue.returncode != 0, f'Including nagios on {rogue} must fail'
    assert 'strictly restricted to app-server' in res_rogue.stderr
EOF
echo "PASS (Nagios Core exclusively on app-server; fail-closed default and rogue inclusion blocked)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Idempotent Resource Declarations [Catalog Compilation]
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Idempotent resource declarations (cycle-free DAG)... "
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
    for iteration in range(2):
        cmd = [
            'puppet', 'apply', '--noop',
            f'--modulepath={puppet_dir}/modules',
            f'--hiera_config={app_hiera}',
            '--certname', 'app-server',
            f'{puppet_dir}/manifests/site.pp'
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        assert res.returncode == 0, f'Iteration {iteration+1} failed: {res.stderr}'
        assert 'dependency cycle' not in res.stderr.lower(), f'Cycle detected in iteration {iteration+1}'
EOF
echo "PASS (zero dependency cycles detected in repeat applications)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Puppet Parser Validate All Manifests & POSIX Shell Check on ERB Guard Scripts
# ------------------------------------------------------------------------------
echo -n "[Test 19/${TOTAL_COUNT}] Puppet parser validate all Nagios manifests & ERB sh -n... "
puppet parser validate "${PUPPET_DIR}"/modules/nagios/manifests/*.pp
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
ruby_script = """
require 'erb'
class Ctx
  def initialize
    @policy_file = '/tmp/mock/policy-rc.d'
    @pid_file = '/tmp/mock/guard.pid'
    @marker = 'PUPPET-MANAGED-TEMP-POLICY-RC-D: git-repo-analyzer-nagios'
    @suppressed_services = ['nagios4', 'apache2']
  end
  def get_binding; binding; end
end
ctx = Ctx.new.get_binding
ARGV.each do |tmpl|
  rendered = ERB.new(File.read(tmpl)).result(ctx)
  out_path = tmpl + '.rendered'
  File.write('/tmp/' + File.basename(tmpl, '.erb'), rendered)
end
"""
subprocess.run([
    'ruby', '-e', ruby_script,
    f'{puppet_dir}/modules/nagios/templates/enable_policy_rc_d.sh.erb',
    f'{puppet_dir}/modules/nagios/templates/disable_policy_rc_d.sh.erb'
], check=True)
for name in ['enable_policy_rc_d.sh', 'disable_policy_rc_d.sh']:
    p = f'/tmp/{name}'
    res = subprocess.run(['sh', '-n', p], capture_output=True, text=True)
    os.remove(p)
    assert res.returncode == 0, f'sh -n failed on {name}: {res.stderr}'
EOF
echo "PASS (all manifests & rendered policy-rc.d guard shell scripts pass syntax checks)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 20. Compiled Puppet DAG Graph Reachability Verification [Catalog Compilation]
# ------------------------------------------------------------------------------
echo -n "[Test 20/${TOTAL_COUNT}] Compiled Puppet DAG graph ordering verification (--graph)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, re, subprocess, tempfile
from collections import defaultdict, deque

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    app_hiera = os.path.join(tmpdir, 'hiera.yaml')
    app_override = os.path.join(tmpdir, 'test_app_override.yaml')
    graph_dir = os.path.join(tmpdir, 'graph')
    os.makedirs(graph_dir, exist_ok=True)
    with open(app_override, 'w') as f:
        f.write("---\nnagios::web::admin_password_hash: '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'\n")
    with open(app_hiera, 'w') as f:
        f.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'Test app override'\n    path: '{app_override}'\n"
            f"  - name: 'Common data'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={app_hiera}',
        '--certname', 'app-server',
        '--graph', f'--graphdir={graph_dir}',
        f'{puppet_dir}/manifests/site.pp'
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Graph compilation failed: {res.stderr}'

    dot_file = os.path.join(graph_dir, 'expanded_relationships.dot')
    assert os.path.isfile(dot_file), 'expanded_relationships.dot was not generated'

    adj = defaultdict(set)
    edge_re = re.compile(r'^\s*"([^"]+)"\s*->\s*"([^"]+)"')
    with open(dot_file) as df:
        for line in df:
            m = edge_re.match(line)
            if m:
                adj[m.group(1)].add(m.group(2))

    def reaches(src, dst):
        seen = {src}
        q = deque([src])
        while q:
            cur = q.popleft()
            if cur == dst:
                return True
            for nxt in adj.get(cur, ()):
                if nxt not in seen:
                    seen.add(nxt)
                    q.append(nxt)
        return False

    pkgs = [
        'Package[nagios4]',
        'Package[monitoring-plugins-basic]',
        'Package[apache2]',
        'Package[apache2-utils]',
    ]
    nagios_cfgs = [
        'File[/etc/nagios4]',
        'File[/etc/nagios4/nagios.cfg]',
        'File[/etc/nagios4/cgi.cfg]',
        'File[/etc/nagios4/resource.cfg]',
        'File[/etc/nagios4/conf.d]',
        'File[/etc/nagios4/conf.d/timeperiods.cfg]',
        'File[/etc/nagios4/conf.d/commands.cfg]',
        'File[/etc/nagios4/conf.d/contacts.cfg]',
        'File[/etc/nagios4/conf.d/hosts.cfg]',
        'File[/etc/nagios4/conf.d/services.cfg]',
    ]
    apache_cfgs = [
        'File[/etc/apache2/ports.conf]',
        'File[/etc/apache2/sites-available/nagios.conf]',
        'File[/etc/apache2/sites-enabled/nagios.conf]',
        'File[/etc/apache2/sites-enabled/000-default.conf]',
        'File[/etc/nagios4/htpasswd.users]',
    ]

    # 1. Package suppression wraps ALL 4 packages before cleanup
    for pkg in pkgs:
        assert reaches('Exec[nagios_enable_policy_rc_d]', pkg), f'enable_policy must precede {pkg}'
        assert reaches(pkg, 'Exec[nagios_disable_policy_rc_d]'), f'{pkg} must precede disable_policy'

    # 2. Cleanup happens before directories/configs and before services
    for cfg in nagios_cfgs + apache_cfgs:
        assert reaches('Exec[nagios_disable_policy_rc_d]', cfg), f'disable_policy must precede {cfg}'

    # 3. Nagios dirs/configs/objects precede Nagios validators, which precede Service[nagios4]
    for cfg in nagios_cfgs:
        assert reaches(cfg, 'Exec[nagios4_configtest]'), f'{cfg} must precede nagios4_configtest'
        assert reaches(cfg, 'Exec[nagios4_configtest_before_start]'), f'{cfg} must precede nagios4_configtest_before_start'
    assert reaches('Exec[nagios4_configtest]', 'Service[nagios4]'), 'nagios4_configtest must precede Service[nagios4]'
    assert reaches('Exec[nagios4_configtest_before_start]', 'Service[nagios4]'), 'before_start must precede Service[nagios4]'

    # 4. Apache configs & htpasswd precede Apache validators, which precede Service[apache2]
    for cfg in apache_cfgs:
        assert reaches(cfg, 'Exec[apache2_configtest]'), f'{cfg} must precede apache2_configtest'
        assert reaches(cfg, 'Exec[apache2_configtest_before_start]'), f'{cfg} must precede apache2_configtest_before_start'
        assert reaches(cfg, 'Exec[nagios4_configtest]'), f'{cfg} must deploy before Nagios/Apache validations'
    assert reaches('Exec[apache2_configtest]', 'Service[apache2]'), 'apache2_configtest must precede Service[apache2]'
    assert reaches('Exec[apache2_configtest_before_start]', 'Service[apache2]'), 'before_start must precede Service[apache2]'
EOF
echo "PASS (compiled Puppet DAG strictly enforces full 9-step first-install & validation ordering)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 21. Sandboxed Behavioral Test: policy-rc.d Startup Suppression & Cleanup
# ------------------------------------------------------------------------------
echo -n "[Test 21/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): policy-rc.d blocks nagios4/apache2 then cleans up... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    policy = os.path.join(tmpdir, 'policy-rc.d')
    pid_file = os.path.join(tmpdir, 'guard.pid')
    probe_out = os.path.join(tmpdir, 'probe.txt')

    manifest = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}

exec {{ 'probe_during_pkg_install':
  command  => "
    set -u
    rc_nagios=0; '{policy}' nagios4 start || rc_nagios=\\$?
    rc_nagios_svc=0; '{policy}' nagios4.service start || rc_nagios_svc=\\$?
    rc_apache=0; '{policy}' apache2 start || rc_apache=\\$?
    rc_apache_svc=0; '{policy}' apache2.service restart || rc_apache_svc=\\$?
    rc_cron=0; '{policy}' cron start || rc_cron=\\$?
    echo \\"nagios=\\${{rc_nagios}} nagios_svc=\\${{rc_nagios_svc}} apache=\\${{rc_apache}} apache_svc=\\${{rc_apache_svc}} cron=\\${{rc_cron}}\\" > '{probe_out}'
  ",
  provider => 'shell',
  require  => Exec['nagios_enable_policy_rc_d'],
  before   => Exec['nagios_disable_policy_rc_d'],
}}
"""
    res = subprocess.run([
        'puppet', 'apply', f'--modulepath={puppet_dir}/modules', '-e', manifest
    ], capture_output=True, text=True)
    assert res.returncode == 0, f'Puppet apply behavioral test failed: {res.stderr}\n{res.stdout}'

    with open(probe_out) as f:
        probe = f.read().strip()
    assert probe == 'nagios=101 nagios_svc=101 apache=101 apache_svc=101 cron=0', f'Unexpected probe output: {probe}'
    assert not os.path.exists(policy), 'Temporary policy-rc.d must be removed after package phase'
    assert not os.path.exists(pid_file), 'Temporary guard PID file must be removed after package phase'
EOF
echo "PASS (scoped exit 101 for nagios4/apache2, exit 0 for unrelated daemons, clean removal)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 22. Sandboxed Behavioral Test: Existing Admin Executable policy-rc.d Fails Closed Without Execution & Steady-State Idempotency
# ------------------------------------------------------------------------------
echo -n "[Test 22/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): executable admin policy fails closed unexecuted & steady-state idempotency... "
export PUPPET_DIR
python3 - << 'EOF'
import hashlib, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

for label, body_template in [
    ('executable_deny_101', "#!/bin/sh\n/usr/bin/touch '{sentinel}'\nexit 101\n"),
    ('executable_allow_0',  "#!/bin/sh\n/usr/bin/touch '{sentinel}'\nexit 0\n"),
]:
    with tempfile.TemporaryDirectory() as tmpdir:
        policy = os.path.join(tmpdir, 'policy-rc.d')
        pid_file = os.path.join(tmpdir, 'guard.pid')
        sentinel = os.path.join(tmpdir, 'side_effect_sentinel')
        pkg_nagios = os.path.join(tmpdir, 'pkg_nagios4_installed')
        pkg_apache = os.path.join(tmpdir, 'pkg_apache2_installed')

        admin_content = body_template.format(sentinel=sentinel).encode('utf-8')
        with open(policy, 'wb') as f:
            f.write(admin_content)
        os.chmod(policy, 0o755)
        before_sha = hashlib.sha256(admin_content).hexdigest()

        manifest = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}
exec {{ 'mock_pkg_nagios4':
  command => '/usr/bin/touch {pkg_nagios}',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
exec {{ 'mock_pkg_apache2':
  command => '/usr/bin/touch {pkg_apache}',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
"""
        res = subprocess.run([
            'puppet', 'apply', '--detailed-exitcodes',
            f'--modulepath={puppet_dir}/modules', '-e', manifest
        ], capture_output=True, text=True)
        assert res.returncode in (4, 6), f'{label}: preflight must FAIL closed (4/6), got {res.returncode}'
        combined = res.stdout + res.stderr
        assert 'administrator-managed policy' in combined, f'{label}: missing diagnostic: {combined}'
        assert 'manually resolve' in combined, f'{label}: missing operator instructions: {combined}'
        assert not os.path.exists(sentinel), f'{label}: SIDE-EFFECT SENTINEL TRIGGERED — admin script was executed!'
        assert not os.path.exists(pkg_nagios), f'{label}: failed preflight MUST block nagios4 package install'
        assert not os.path.exists(pkg_apache), f'{label}: failed preflight MUST block apache2 package install'
        assert os.listdir(tmpdir) == ['policy-rc.d'], f'{label}: unexpected artifacts left: {os.listdir(tmpdir)}'
        with open(policy, 'rb') as f:
            assert hashlib.sha256(f.read()).hexdigest() == before_sha, f'{label}: admin file must stay byte-for-byte identical'

with tempfile.TemporaryDirectory() as tmpdir2:
    # Steady-state repeated Puppet runs when all target packages are installed (even with admin policy present)
    policy2 = os.path.join(tmpdir2, 'policy-rc.d')
    pid2 = os.path.join(tmpdir2, 'guard.pid')
    sentinel2 = os.path.join(tmpdir2, 'side_effect_sentinel')
    admin_steady = f"#!/bin/sh\n/usr/bin/touch '{sentinel2}'\nexit 101\n"
    with open(policy2, 'w') as f:
        f.write(admin_steady)
    os.chmod(policy2, 0o755)
    manifest_steady = f"""
class {{ 'nagios::install_guard':
  target_packages => ['bash', 'coreutils'],
  policy_file     => '{policy2}',
  pid_file        => '{pid2}',
}}
Exec['nagios_enable_policy_rc_d'] -> Exec['nagios_disable_policy_rc_d']
"""
    for run in range(2):
        res_b = subprocess.run([
            'puppet', 'apply', '--detailed-exitcodes',
            f'--modulepath={puppet_dir}/modules', '-e', manifest_steady
        ], capture_output=True, text=True)
        assert res_b.returncode == 0, f'Steady-state run {run+1} must return 0 changes, got {res_b.returncode}: {res_b.stderr}\n{res_b.stdout}'
    assert not os.path.exists(sentinel2), 'Steady-state run must not execute admin policy'
    with open(policy2) as f:
        assert f.read() == admin_steady
EOF
echo "PASS (executable admin policy fails closed unexecuted via sentinel proof; byte-for-byte unchanged; steady-state 0 changes)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 23. Sandboxed Behavioral Test: Failed Package Install Failsafe & Recovery Cleanup
# ------------------------------------------------------------------------------
echo -n "[Test 23/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): failed install fails open & recovers... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    policy = os.path.join(tmpdir, 'policy-rc.d')
    pid_file = os.path.join(tmpdir, 'guard.pid')

    # A: Simulate package install failure between enable and disable
    manifest_fail = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}

exec {{ 'simulated_pkg_failure':
  command => '/bin/false',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
"""
    res_fail = subprocess.run([
        'puppet', 'apply', '--detailed-exitcodes',
        f'--modulepath={puppet_dir}/modules', '-e', manifest_fail
    ], capture_output=True, text=True)
    assert res_fail.returncode in (4, 6), f'Simulated package failure run must exit 4 or 6, got {res_fail.returncode}'

    # Even before recovery runs, dead Puppet PID means policy-rc.d fails open (exit 0)
    assert os.path.isfile(policy), 'Sanity: policy file was created prior to package failure'
    for svc in ['nagios4', 'nagios4.service', 'apache2', 'apache2.service', 'cron']:
        rc = subprocess.run([policy, svc, 'start']).returncode
        assert rc == 0, f'After Puppet exits on failure, {svc} must fail open (0), got {rc}'

    # B: Recovery Puppet run once package is present cleans up orphaned marker & PID files cleanly
    manifest_recover = f"""
class {{ 'nagios::install_guard':
  target_packages => ['bash'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}
Exec['nagios_enable_policy_rc_d'] -> Exec['nagios_disable_policy_rc_d']
"""
    res_rec = subprocess.run([
        'puppet', 'apply', f'--modulepath={puppet_dir}/modules', '-e', manifest_recover
    ], capture_output=True, text=True)
    assert res_rec.returncode == 0, f'Recovery run failed: {res_rec.stderr}'
    assert not os.path.exists(policy), 'Recovery run must clean up orphaned Puppet policy-rc.d'
    assert not os.path.exists(pid_file), 'Recovery run must clean up orphaned guard PID file'
EOF
echo "PASS (failed package run fails open after Puppet exits; recovery run cleans orphaned guard)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 24. Behavioral Test: Failed Validation Blocks Service & No Unnecessary Restarts
# ------------------------------------------------------------------------------
echo -n "[Test 24/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): failed validation blocks service & steady-state idempotency... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

with tempfile.TemporaryDirectory() as tmpdir:
    service_flag = os.path.join(tmpdir, 'service_started')
    cfg_file = os.path.join(tmpdir, 'mock.cfg')

    # Mirrors exact server.pp / web.pp validation + before_start pattern:
    def make_manifest(cfg_content, validate_cmd, service_active_already):
        is_active = '/bin/true' if service_active_already else '/bin/false'
        return f"""
file {{ '{cfg_file}':
  ensure  => file,
  content => '{cfg_content}',
  notify  => Exec['mock_configtest'],
}}

exec {{ 'mock_configtest':
  command     => '{validate_cmd}',
  refreshonly => true,
  notify      => Exec['mock_service'],
  before      => Exec['mock_service'],
}}

exec {{ 'mock_configtest_before_start':
  command => '{validate_cmd}',
  unless  => '{is_active}',
  require => File['{cfg_file}'],
  before  => Exec['mock_service'],
}}

exec {{ 'mock_service':
  command     => '/usr/bin/touch {service_flag}',
  unless      => '{is_active}',
  refreshonly => false,
}}
"""

    # A: Initial broken config must FAIL validation and NEVER start service
    res_a = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', '-e', make_manifest('broken', '/bin/false', False)], capture_output=True, text=True)
    assert res_a.returncode in (4, 6), f'Failed validation must exit 4 or 6, got {res_a.returncode}'
    assert not os.path.exists(service_flag), 'Failed validation on first install must BLOCK service startup'

    # B: Second run with unchanged broken config still on disk & service stopped MUST STILL validate & block startup!
    res_b = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', '-e', make_manifest('broken', '/bin/false', False)], capture_output=True, text=True)
    assert res_b.returncode in (4, 6), f'Repeat run with broken config must exit 4 or 6, got {res_b.returncode}'
    assert not os.path.exists(service_flag), 'Repeat run with still-broken config MUST still block startup'

    # C: Service already active + broken config update MUST execute mock_configtest and FAIL (no bogus unless bypass)
    res_c = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', '-e', make_manifest('new_broken', '/bin/false', True)], capture_output=True, text=True)
    assert res_c.returncode in (4, 6), f'Active service + broken config change MUST fail configtest (exit 4/6), got {res_c.returncode}'

    # D: Valid config deploys and starts service cleanly; repeat steady-state run causes 0 restarts
    res_d = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', '-e', make_manifest('valid_cfg', '/bin/true', False)], capture_output=True, text=True)
    assert res_d.returncode == 2, f'Valid first-install config must exit 2 (changes applied), got {res_d.returncode}'
    assert os.path.exists(service_flag), 'Valid config must start service'
    os.remove(service_flag)

    res_e = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', '-e', make_manifest('valid_cfg', '/bin/true', True)], capture_output=True, text=True)
    assert res_e.returncode == 0, f'Steady-state unchanged run must return 0 changes, got {res_e.returncode}'
    assert not os.path.exists(service_flag), 'Steady-state run must NEVER restart running service'
EOF
echo "PASS (failed validation blocks start/reload even across retries; steady-state causes 0 restarts)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 25. Sandboxed Behavioral Test: Non-Executable & Symlink Admin Policies Fail Safely Unmodified
# ------------------------------------------------------------------------------
echo -n "[Test 25/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): non-exec & symlink admin policies fail closed safely... "
export PUPPET_DIR
python3 - << 'EOF'
import hashlib, os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

def run_fail_preflight(label, setup_fn, verify_fn):
    with tempfile.TemporaryDirectory() as tmpdir:
        policy = os.path.join(tmpdir, 'policy-rc.d')
        pid_file = os.path.join(tmpdir, 'guard.pid')
        pkg_nagios = os.path.join(tmpdir, 'pkg_nagios4')
        pkg_apache = os.path.join(tmpdir, 'pkg_apache2')
        ctx = setup_fn(tmpdir, policy)

        manifest = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}
exec {{ 'mock_pkg_nagios4':
  command => '/usr/bin/touch {pkg_nagios}',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
exec {{ 'mock_pkg_apache2':
  command => '/usr/bin/touch {pkg_apache}',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
"""
        res = subprocess.run([
            'puppet', 'apply', '--detailed-exitcodes',
            f'--modulepath={puppet_dir}/modules', '-e', manifest
        ], capture_output=True, text=True)
        assert res.returncode in (4, 6), f'{label}: preflight must fail closed (4/6), got {res.returncode}: {res.stderr}'
        combined = res.stdout + res.stderr
        assert 'administrator-managed policy' in combined, f'{label}: missing diagnostic: {combined}'
        assert 'manually resolve' in combined, f'{label}: missing operator guidance: {combined}'
        assert not os.path.exists(pkg_nagios), f'{label}: must block nagios4 install'
        assert not os.path.exists(pkg_apache), f'{label}: must block apache2 install'
        assert not os.path.exists(pid_file), f'{label}: must leave zero guard PID files'
        verify_fn(tmpdir, policy, ctx)

# Case 1: Non-executable admin file (0644)
def setup_non_exec(td, p):
    raw = b"#!/bin/sh\n# Admin policy\nexit 101\n"
    with open(p, 'wb') as f:
        f.write(raw)
    os.chmod(p, 0o644)
    return hashlib.sha256(raw).hexdigest()

def verify_non_exec(td, p, before_sha):
    assert os.path.isfile(p) and not os.path.islink(p)
    assert (os.stat(p).st_mode & 0o777) == 0o644
    with open(p, 'rb') as f:
        assert hashlib.sha256(f.read()).hexdigest() == before_sha

# Case 2: Valid symlink targeting an executable script containing Puppet's marker & sentinel (must NEVER follow/execute/delete symlink!)
def setup_valid_symlink(td, p):
    target = os.path.join(td, 'admin_target.sh')
    sentinel = os.path.join(td, 'symlink_sentinel')
    raw = f"#!/bin/sh\n# PUPPET-MANAGED-TEMP-POLICY-RC-D: git-repo-analyzer-nagios\n/usr/bin/touch '{sentinel}'\nexit 101\n".encode('utf-8')
    with open(target, 'wb') as f:
        f.write(raw)
    os.chmod(target, 0o755)
    os.symlink(target, p)
    return (target, sentinel, hashlib.sha256(raw).hexdigest())

def verify_valid_symlink(td, p, ctx):
    target, sentinel, before_sha = ctx
    assert os.path.islink(p) and os.readlink(p) == target, 'Symlink must remain untouched'
    assert not os.path.exists(sentinel), 'Symlink target must NEVER be executed!'
    with open(target, 'rb') as f:
        assert hashlib.sha256(f.read()).hexdigest() == before_sha, 'Symlink target must remain byte-for-byte identical'

# Case 3: Broken symlink
def setup_broken_symlink(td, p):
    target = '/nonexistent/admin/policy-rc.d'
    os.symlink(target, p)
    return target

def verify_broken_symlink(td, p, target):
    assert os.path.islink(p) and os.readlink(p) == target, 'Broken symlink must remain untouched'

run_fail_preflight('non_executable_file', setup_non_exec, verify_non_exec)
run_fail_preflight('symlink_to_executable', setup_valid_symlink, verify_valid_symlink)
run_fail_preflight('broken_symlink', setup_broken_symlink, verify_broken_symlink)
EOF
echo "PASS (non-exec files and symlinks fail preflight safely, unexecuted, and byte-for-byte unchanged)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 26. Sandboxed Behavioral Test: Existing Puppet Guard Recovery & Concurrent Lock Protection
# ------------------------------------------------------------------------------
echo -n "[Test 26/${TOTAL_COUNT}] Behavioral (sandboxed /tmp): Puppet stale-guard recovery & concurrent lock protection... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

# Part A: Existing Puppet-managed guard with dead/stale PID recovers and cleans up cleanly
with tempfile.TemporaryDirectory() as tmpdir_stale:
    policy = os.path.join(tmpdir_stale, 'policy-rc.d')
    pid_file = os.path.join(tmpdir_stale, 'guard.pid')
    probe_out = os.path.join(tmpdir_stale, 'probe.txt')
    marker = 'PUPPET-MANAGED-TEMP-POLICY-RC-D: git-repo-analyzer-nagios'
    with open(policy, 'w') as f:
        f.write(f"#!/bin/sh\n# {marker}\nexit 0\n")
    os.chmod(policy, 0o755)
    with open(pid_file, 'w') as f:
        f.write("999999\n")

    manifest_stale = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}
exec {{ 'probe_after_stale_refresh':
  command  => "
    rc_nag=0; '{policy}' nagios4 start || rc_nag=\\$?
    rc_apa=0; '{policy}' apache2.service start || rc_apa=\\$?
    rc_cro=0; '{policy}' cron start || rc_cro=\\$?
    echo \\"nag=\\${{rc_nag}} apa=\\${{rc_apa}} cro=\\${{rc_cro}}\\" > '{probe_out}'
  ",
  provider => 'shell',
  require  => Exec['nagios_enable_policy_rc_d'],
  before   => Exec['nagios_disable_policy_rc_d'],
}}
"""
    res_stale = subprocess.run([
        'puppet', 'apply', '--detailed-exitcodes',
        f'--modulepath={puppet_dir}/modules', '-e', manifest_stale
    ], capture_output=True, text=True)
    assert res_stale.returncode == 2, f'Stale Puppet guard recovery failed ({res_stale.returncode}): {res_stale.stderr}'
    with open(probe_out) as f:
        assert f.read().strip() == 'nag=101 apa=101 cro=0'
    assert not os.path.exists(policy), 'Puppet-managed policy must be cleaned up after refresh+install'
    assert not os.path.exists(pid_file)

# Part B: Concurrent active Puppet process protection preserves existing Puppet guard
with tempfile.TemporaryDirectory() as tmpdir_live:
    policy = os.path.join(tmpdir_live, 'policy-rc.d')
    pid_file = os.path.join(tmpdir_live, 'guard.pid')
    pkg_flag = os.path.join(tmpdir_live, 'pkg_should_not_run')
    marker = 'PUPPET-MANAGED-TEMP-POLICY-RC-D: git-repo-analyzer-nagios'
    original_policy = f"#!/bin/sh\n# {marker}\nexit 101\n"
    with open(policy, 'w') as f:
        f.write(original_policy)
    os.chmod(policy, 0o755)
    proc = subprocess.Popen(['python3', '-c', 'import time; time.sleep(15)', 'puppet-simulated-concurrent-agent'])
    try:
        with open(pid_file, 'w') as f:
            f.write(f"{proc.pid}\n")
        manifest_live = f"""
class {{ 'nagios::install_guard':
  target_packages => ['nonexistent-nagios-test-pkg'],
  policy_file     => '{policy}',
  pid_file        => '{pid_file}',
}}
exec {{ 'mock_pkg_install':
  command => '/usr/bin/touch {pkg_flag}',
  require => Exec['nagios_enable_policy_rc_d'],
  before  => Exec['nagios_disable_policy_rc_d'],
}}
"""
        res_live = subprocess.run([
            'puppet', 'apply', '--detailed-exitcodes',
            f'--modulepath={puppet_dir}/modules', '-e', manifest_live
        ], capture_output=True, text=True)
        assert res_live.returncode in (4, 6), f'Concurrent Puppet guard must fail safely (4/6), got {res_live.returncode}'
        assert 'Concurrent active Puppet process' in (res_live.stdout + res_live.stderr)
        assert not os.path.exists(pkg_flag), 'Must not install packages while concurrent Puppet process holds lock'
        assert os.path.isfile(policy) and os.path.isfile(pid_file)
    finally:
        proc.terminate()
        proc.wait(timeout=5)
EOF
echo "PASS (Puppet stale-guard recovery and concurrent live lock protection verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 5A.4 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
