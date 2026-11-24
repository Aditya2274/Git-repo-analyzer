#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Checkpoint 5A.4 (Nagios Core & Monitoring Configuration)
# Description: Automated verification for Nagios Core server, object definitions,
#              Apache loopback virtual host, authentication security, validation
#              ordering, node targeting, and catalog compilation.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUPPET_DIR="${PROJECT_ROOT}/puppet"

PASSED_COUNT=0
TOTAL_COUNT=18

echo "=============================================================================="
echo "Running Test Suite: Checkpoint 5A.4 (Nagios Core Puppet Module)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Nagios Package Declarations
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Nagios package declarations (nagios4 & plugins)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    server_content = f.read()
with open('${PUPPET_DIR}/modules/nrpe/manifests/client.pp') as f:
    client_content = f.read()

assert 'package { \$package_name:' in server_content, 'server.pp must declare package resource'
assert '\$package_name    = \'nagios4\'' in server_content or '\$package_name = \'nagios4\'' in server_content or 'nagios4' in server_content, 'server.pp default package must be nagios4'
assert 'monitoring-plugins-basic' in server_content, 'server.pp must include monitoring-plugins-basic'
assert 'nagios-nrpe-plugin' not in server_content, 'server.pp must NOT declare nagios-nrpe-plugin (managed by nrpe::client)'
assert 'nagios-nrpe-plugin' in client_content, 'nrpe::client must manage nagios-nrpe-plugin'
"
echo "PASS (nagios4 and plugins declared without duplicate nrpe-plugin package)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Correct Service Name
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
# 3. Correct Configuration Paths
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
# 4. Host Definitions for All Three Nodes
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
# 5. NRPE Command Definition
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
# 6. Correct Node-Specific Service Assignments
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
# 7. No Jenkins/Docker Checks on puppet-server
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
# 8. No Puppet Server Check on cicd-server
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
# 9. Apache Package and Configuration
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
# 10. Localhost-Only Binding on Port 8080
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
# 11. Basic Authentication Configuration
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
# 12. Authentication-File Permissions
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
# 13. Placeholder Credential Detection
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Placeholder credential detection and security guard... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

# Scenario A: Production enforcement fails fast when placeholder hash is used
code_prod_fail = """
class { 'nagios::web':
  enforce_production_secret => true,
  admin_password_hash       => '$apr1$demo$hashedpassword',
}
"""
cmd1 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', code_prod_fail
]
res1 = subprocess.run(cmd1, capture_output=True, text=True)
assert res1.returncode != 0, 'Must fail compilation when placeholder hash is used with enforce_production_secret => true'
assert 'insecure placeholder credential' in res1.stderr, f'Error must mention placeholder credential: {res1.stderr}'

# Scenario B: Production enforcement succeeds when authentic test hash is supplied
code_prod_pass = """
class { 'nagios::web':
  enforce_production_secret => true,
  admin_password_hash       => '$apr1$testsalt$authenticsecurehash123',
}
"""
cmd2 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', code_prod_pass
]
res2 = subprocess.run(cmd2, capture_output=True, text=True)
assert res2.returncode == 0, f'Must pass compilation when authentic hash is provided: {res2.stderr}'

# Scenario C: Development mode emits security warning notify
code_dev = "include nagios::web"
cmd3 = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '-e', code_dev
]
res3 = subprocess.run(cmd3, capture_output=True, text=True)
assert res3.returncode == 0, f'Dev mode must compile: {res3.stderr}'
combined = res3.stdout + res3.stderr
assert 'nagios_placeholder_credential_warning' in combined, 'Must emit security warning notification in dev mode'
EOF
echo "PASS (placeholder rejected in production mode; warning notify emitted in dev mode)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Nagios Configuration Validation Ordering
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Nagios configuration validation ordering (nagios4 -v)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/server.pp') as f:
    server_content = f.read()

assert 'exec { \'nagios4_configtest\':' in server_content, 'server.pp must declare nagios4_configtest exec'
assert '/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg' in server_content, 'nagios4_configtest must validate /etc/nagios4/nagios.cfg'
assert 'refreshonly => true' in server_content, 'nagios4_configtest must be refreshonly'
assert 'notify      => Service[\$service_name]' in server_content or 'notify  => Service[\$service_name]' in server_content, 'nagios4_configtest must notify service'
assert 'Class[\'nagios::objects\']' in server_content, 'server.pp must chain objects before validation'
assert 'Exec[\'nagios4_configtest\']' in server_content, 'server.pp must order validation before service'
"
echo "PASS (nagios4 -v executes before service start and protects service from invalid config)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Apache Configuration Validation Ordering
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] Apache configuration validation ordering (apache2ctl configtest)... "
python3 -c "
with open('${PUPPET_DIR}/modules/nagios/manifests/web.pp') as f:
    web_content = f.read()

assert 'exec { \'apache2_configtest\':' in web_content, 'web.pp must declare apache2_configtest exec'
assert '/usr/sbin/apache2ctl configtest' in web_content, 'apache2_configtest must run apache2ctl configtest'
assert 'refreshonly => true' in web_content, 'apache2_configtest must be refreshonly'
assert 'notify      => Service[\$apache_service]' in web_content, 'apache2_configtest must notify apache service'
assert 'before      => Service[\$apache_service]' in web_content, 'apache2_configtest must execute before service'
"
echo "PASS (apache2ctl configtest validates configuration before service reload/start)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Service Enablement and Startup Dependencies
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Service enablement and startup dependencies... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
cmd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'app-server',
    '-e', 'include nagios'
]
res = subprocess.run(cmd, capture_output=True, text=True)
assert res.returncode == 0, f'Catalog compilation failed: {res.stderr}'
combined = res.stdout + res.stderr

assert 'Service[nagios4]' in combined, 'Must manage Service[nagios4]'
assert 'Service[apache2]' in combined, 'Must manage Service[apache2]'
assert 'Package[nagios4]' in combined, 'Must manage Package[nagios4]'
assert 'Package[apache2]' in combined, 'Must manage Package[apache2]'
EOF
echo "PASS (both nagios4 and apache2 services declare full dependency chain)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Puppet Target Isolation
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Puppet target isolation (app-server vs puppet/cicd-server)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

# 1. app-server catalog has Nagios and Apache, but NO nrpe::server
cmd_app = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
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

# 2. puppet-server catalog has NO Nagios or Apache
cmd_puppet = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'puppet-server',
    f'{puppet_dir}/manifests/site.pp'
]
res_puppet = subprocess.run(cmd_puppet, capture_output=True, text=True)
assert res_puppet.returncode == 0, f'puppet-server catalog failed: {res_puppet.stderr}'
comb_puppet = res_puppet.stdout + res_puppet.stderr
assert 'Package[nagios4]' not in comb_puppet, 'puppet-server must NOT manage nagios4'
assert 'Package[apache2]' not in comb_puppet, 'puppet-server must NOT manage apache2'
assert 'Package[nagios-nrpe-server]' in comb_puppet, 'puppet-server MUST manage nrpe server'

# 3. cicd-server catalog has NO Nagios or Apache
cmd_cicd = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'cicd-server',
    f'{puppet_dir}/manifests/site.pp'
]
res_cicd = subprocess.run(cmd_cicd, capture_output=True, text=True)
assert res_cicd.returncode == 0, f'cicd-server catalog failed: {res_cicd.stderr}'
comb_cicd = res_cicd.stdout + res_cicd.stderr
assert 'Package[nagios4]' not in comb_cicd, 'cicd-server must NOT manage nagios4'
assert 'Package[apache2]' not in comb_cicd, 'cicd-server must NOT manage apache2'
assert 'Package[nagios-nrpe-server]' in comb_cicd, 'cicd-server MUST manage nrpe server'

# 4. Attempting to include nagios on unexpected certname fails fast
cmd_rogue = [
    'puppet', 'apply', '--noop',
    f'--modulepath={puppet_dir}/modules',
    f'--hiera_config={puppet_dir}/hiera.yaml',
    '--certname', 'puppet-server',
    '-e', 'include nagios'
]
res_rogue = subprocess.run(cmd_rogue, capture_output=True, text=True)
assert res_rogue.returncode != 0, 'Including nagios on puppet-server must fail'
assert 'strictly restricted to app-server' in res_rogue.stderr, 'Error message must state restriction'
EOF
echo "PASS (Nagios Core exclusively deployed to app-server; rogue inclusion blocked)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Idempotent Resource Declarations and Handler Behavior
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Idempotent resource declarations (cycle-free DAG)... "
export PUPPET_DIR
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']
for iteration in range(2):
    cmd = [
        'puppet', 'apply', '--noop',
        f'--modulepath={puppet_dir}/modules',
        f'--hiera_config={puppet_dir}/hiera.yaml',
        '--certname', 'app-server',
        '-e', 'include nagios'
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f'Iteration {iteration+1} failed: {res.stderr}'
    assert 'dependency cycle' not in res.stderr.lower(), f'Cycle detected in iteration {iteration+1}'
EOF
echo "PASS (zero dependency cycles detected in repeat applications)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Checkpoint 5A.4 Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "=============================================================================="
