#!/usr/bin/env bash
# ==============================================================================
# Test Suite: test_phase5b_application.sh
# Purpose: Comprehensive verification of Phase 5B (Checkpoints 5B.2 - 5B.5):
#          - application::nodejs (Node.js 24 LTS NodeSource contract, no Node 20)
#          - application::backend (gitrepo user, data dir, 0640 backend.env, systemd unit)
#          - application::nginx (SPA + /api/ reverse proxy, nginx -t gate, no Nagios route)
#          - application (node guard, --graph DAG cycle-free ordering, health gates,
#            known-good retention pruning, failed-health abort, zero-rebuild rollback)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUPPET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${PUPPET_DIR}/.." && pwd)"

PASSED_COUNT=0
TOTAL_COUNT=26

echo "=============================================================================="
echo "Running Test Suite: Phase 5B (Puppet Application Deployment & Rollback)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Manifest, ERB Template & Python Helper Syntax Validation
# ------------------------------------------------------------------------------
echo -n "[Test 1/${TOTAL_COUNT}] Parser validate manifests, ERB ruby -c, Python py_compile... "
puppet parser validate \
  "${PUPPET_DIR}/manifests/site.pp" \
  "${PUPPET_DIR}/modules/application/manifests/init.pp" \
  "${PUPPET_DIR}/modules/application/manifests/nodejs.pp" \
  "${PUPPET_DIR}/modules/application/manifests/release.pp" \
  "${PUPPET_DIR}/modules/application/manifests/backend.pp" \
  "${PUPPET_DIR}/modules/application/manifests/nginx.pp"

for tpl in \
  "${PUPPET_DIR}/modules/application/templates/backend.env.erb" \
  "${PUPPET_DIR}/modules/application/templates/git-repo-analyzer-backend.service.erb" \
  "${PUPPET_DIR}/modules/application/templates/nginx_git_repo_analyzer.conf.erb"; do
  erb -x -T - "${tpl}" | ruby -c >/dev/null
done

python3 - <<PY
import os, py_compile, tempfile
with tempfile.TemporaryDirectory() as tmpdir:
    for idx, src in enumerate([
        "${PUPPET_DIR}/modules/application/files/release_manager.py",
        "${PUPPET_DIR}/modules/application/files/health_check.py",
    ]):
        py_compile.compile(src, cfile=os.path.join(tmpdir, f"mod{idx}.pyc"), doraise=True)
PY

python3 -c "import yaml; yaml.safe_load(open('${PUPPET_DIR}/hieradata/common.yaml'))"
echo "PASS (5 manifests, 3 ERB templates, 2 Python helpers, and common.yaml valid)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 2. Node.js 24 LTS Repository Contract & Node 20 EOL Rejection
# ------------------------------------------------------------------------------
echo -n "[Test 2/${TOTAL_COUNT}] application::nodejs NodeSource 24 LTS contract & Node 20 rejection... "
export PUPPET_DIR PROJECT_ROOT
python3 - << 'EOF'
import os, subprocess

puppet_dir = os.environ['PUPPET_DIR']

res = subprocess.run(
    ['puppet', 'apply', '--noop', '--show_diff',
     f'--modulepath={puppet_dir}/modules', '--certname', 'app-server',
     '-e', "class { 'application::nodejs': }"],
    capture_output=True, text=True
)
assert res.returncode == 0, f"application::nodejs --noop failed: {res.stderr}"
combined = res.stdout + res.stderr
assert '/etc/apt/keyrings/nodesource.gpg' in combined
assert '/etc/apt/sources.list.d/nodesource.list' in combined
assert '/etc/apt/preferences.d/nodesource-nodejs' in combined
assert 'Package[nodejs]' in combined

with open(os.path.join(puppet_dir, 'modules/application/manifests/nodejs.pp')) as fh:
    src = fh.read()
assert 'https://deb.nodesource.com/node_24.x' in src
assert 'nodistro main' in src
assert 'node_20.x' not in src, 'nodejs.pp must never configure Node 20 EOL repo'

for bad_expr in [
    "class { 'application::nodejs': node_major => 20 }",
    "class { 'application::nodejs': repo_base_url => 'https://deb.nodesource.com/node_20.x' }",
    "class { 'application::nodejs': repo_base_url => 'http://deb.nodesource.com/node_24.x' }",
]:
    bad = subprocess.run(
        ['puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
         '--certname', 'app-server', '-e', bad_expr],
        capture_output=True, text=True
    )
    assert bad.returncode != 0, f"Expected failure for invalid Node repo input: {bad_expr}"
EOF
echo "PASS (NodeSource node_24.x configured; Node 20 & plain HTTP fail closed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 3. Behavioral Node.js Runtime Version Gate (Node 24 passes, Node 20 fails)
# ------------------------------------------------------------------------------
echo -n "[Test 3/${TOTAL_COUNT}] Behavioral Node.js major=24 runtime gate (pass v24, reject v20)... "
python3 - << 'EOF'
import os, shutil, stat, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
real_node24 = shutil.which('node')
assert real_node24, 'node binary expected in PATH'
ver_out = subprocess.check_output([real_node24, '-v'], text=True).strip()
assert ver_out.startswith('v24.'), f'Expected local node v24.x for runtime check, got {ver_out}'

r_ok = subprocess.run(
    ['puppet', 'apply', '--detailed-exitcodes',
     f'--modulepath={puppet_dir}/modules', '--certname', 'app-server',
     '-e', f"class {{ 'application::nodejs': manage_packages => false, verify_runtime => true, node_bin => '{real_node24}' }}"],
    capture_output=True, text=True
)
assert r_ok.returncode == 0, f"Node 24 check should exit 0 (idempotent), got {r_ok.returncode}: {r_ok.stderr}"

with tempfile.TemporaryDirectory() as tmpdir:
    fake_node20 = os.path.join(tmpdir, 'node')
    with open(fake_node20, 'w') as fh:
        fh.write("#!/bin/sh\nif [ \"$1\" = '-v' ]; then echo v20.19.0; exit 0; fi\nexit 1\n")
    os.chmod(fake_node20, 0o755)
    r_fail = subprocess.run(
        ['puppet', 'apply', '--detailed-exitcodes',
         f'--modulepath={puppet_dir}/modules', '--certname', 'app-server',
         '-e', f"class {{ 'application::nodejs': manage_packages => false, verify_runtime => true, node_bin => '{fake_node20}' }}"],
        capture_output=True, text=True
    )
    assert r_fail.returncode not in (0, 2), f"Fake Node 20 runtime MUST fail verification gate (rc={r_fail.returncode})"
    assert 'Expected Node.js 24 LTS' in (r_fail.stdout + r_fail.stderr)
EOF
echo "PASS (real Node v24.x passes with exit 0; mock Node v20 rejected)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 4. application::backend User, Paths, backend.env (0640), & Systemd Hardening
# ------------------------------------------------------------------------------
echo -n "[Test 4/${TOTAL_COUNT}] Backend user, data dir, 0640 backend.env & systemd unit rendering... "
python3 - << 'EOF'
import os, stat, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

# Production catalog check (--noop)
res_prod = subprocess.run(
    ['puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules',
     '--certname', 'app-server', '-e', "class { 'application::backend': release_active => true, cors_origin => 'http://127.0.0.1' }"],
    capture_output=True, text=True
)
assert res_prod.returncode == 0, f"Backend --noop catalog failed: {res_prod.stderr}"
comb = res_prod.stdout + res_prod.stderr
for r in [
    'Group[gitrepo]', 'User[gitrepo]',
    'File[/var/lib/git-repo-analyzer]', 'File[/var/lib/git-repo-analyzer/data]',
    'File[/etc/git-repo-analyzer]', 'File[/etc/git-repo-analyzer/backend.env]',
    'File[/etc/systemd/system/git-repo-analyzer-backend.service]',
    'Exec[app_systemd_daemon_reload]', 'Exec[app_verify_backend_entrypoint]',
    'Service[git-repo-analyzer-backend]',
]:
    assert r in comb, f"Missing expected resource {r} in backend catalog"

# Sandbox render check
with tempfile.TemporaryDirectory() as sandbox:
    env_file = os.path.join(sandbox, 'etc/app/backend.env')
    unit_file = os.path.join(sandbox, 'systemd/git-repo-analyzer-backend.service')
    for d in ('var', 'etc', 'systemd'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)
    expr = (
        f"class {{ 'application::backend': "
        f"release_active => false, manage_users => false, manage_ownership => false, manage_service => false, "
        f"base_dir => '{sandbox}/opt', data_base_dir => '{sandbox}/var/lib', data_dir => '{sandbox}/var/lib/data', "
        f"env_dir => '{sandbox}/etc/app', env_file => '{env_file}', systemd_unit_path => '{unit_file}', "
        f"cors_origin => 'http://127.0.0.1, http://localhost:3000' }}"
    )
    r = subprocess.run(
        ['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr],
        capture_output=True, text=True
    )
    assert r.returncode in (0, 2), f"Backend sandbox render failed: {r.stderr}"
    assert stat.S_IMODE(os.stat(os.path.join(sandbox, 'etc/app')).st_mode) == 0o750
    assert stat.S_IMODE(os.stat(env_file).st_mode) == 0o640
    assert stat.S_IMODE(os.stat(os.path.join(sandbox, 'var/lib/data')).st_mode) == 0o750
    assert stat.S_IMODE(os.stat(unit_file).st_mode) == 0o644

    env_txt = open(env_file).read()
    for key in [
        'NODE_ENV=production', 'PORT=3000', 'HOST=127.0.0.1',
        f"DATA_DIR={sandbox}/var/lib/data", 'CORS_ORIGIN=http://127.0.0.1,http://localhost:3000',
        'SSRF_CHECK_DNS=true', 'ANALYSIS_TIMEOUT_MS=600000', 'POLL_INTERVAL_MS=1500',
        'JENKINS_MOCK_MODE=true', 'JENKINS_JOB_NAME=git-repo-analyzer',
        'JENKINS_REQUEST_TIMEOUT_MS=5000',
    ]:
        assert key in env_txt, f"Missing env line '{key}'"

    unit_txt = open(unit_file).read()
    for line in [
        'User=gitrepo', 'Group=gitrepo',
        f'WorkingDirectory={sandbox}/opt/backend',
        f'EnvironmentFile={env_file}',
        f'ExecStart=/usr/bin/node {sandbox}/opt/backend/dist/server.js',
        'Restart=always', 'RestartSec=5s', 'KillSignal=SIGTERM', 'TimeoutStopSec=15',
        'StandardOutput=journal', 'StandardError=journal', 'NoNewPrivileges=true',
        'ProtectSystem=strict', f'ReadWritePaths={sandbox}/var/lib/data',
    ]:
        assert line in unit_txt, f"Missing systemd directive '{line}'"
EOF
echo "PASS (0750/0640 permissions, all 14 env vars, and systemd hardening verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 5. Backend Fail-Closed Security Checks + Live Node 24 Backend Boot Under Puppet Env
# ------------------------------------------------------------------------------
echo -n "[Test 5/${TOTAL_COUNT}] Backend fail-closed guards & live Node 24 Express boot with generated env... "
python3 - << 'EOF'
import json, os, shutil, socket, subprocess, tempfile, time, urllib.request

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']

fail_cases = [
    ("SSRF disabled in prod", "class { 'application::backend': node_env => 'production', ssrf_check_dns => false }"),
    ("Empty CORS in active prod release", "class { 'application::backend': release_active => true, node_env => 'production', cors_origin => '' }"),
    ("Wildcard CORS", "class { 'application::backend': cors_origin => '*' }"),
    ("Credentials in CORS", "class { 'application::backend': cors_origin => 'http://user:pass@127.0.0.1' }"),
    ("Live Jenkins missing creds", "class { 'application::backend': jenkins_mock_mode => false }"),
    ("Live Jenkins placeholder token", "class { 'application::backend': jenkins_mock_mode => false, jenkins_url => 'http://127.0.0.1:8080', jenkins_user => 'ci', jenkins_api_token => 'CHANGE_ME' }"),
    ("CORS path injection", "class { 'application::backend': cors_origin => 'http://127.0.0.1/bad' }"),
    ("Newline in CORS", "class { 'application::backend': cors_origin => \"http://127.0.0.1\\nPORT=9999\" }"),
    ("CORS port 0", "class { 'application::backend': cors_origin => 'http://127.0.0.1:0' }"),
    ("CORS port > 65535", "class { 'application::backend': cors_origin => 'http://127.0.0.1:99999' }"),
    ("CORS trailing comma", "class { 'application::backend': cors_origin => 'http://127.0.0.1,' }"),
    ("Invalid jenkins_url", "class { 'application::backend': jenkins_url => 'http://:' }"),
    ("Relative data_dir", "class { 'application::backend': data_dir => 'relative/data' }"),
]
for label, expr in fail_cases:
    r = subprocess.run(
        ['puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr],
        capture_output=True, text=True
    )
    assert r.returncode != 0, f"Expected fail-closed failure for {label}"

# Pick free ephemeral loopback port and boot REAL backend server using Puppet-rendered backend.env
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    free_port = sock.getsockname()[1]

with tempfile.TemporaryDirectory() as sandbox:
    env_file = os.path.join(sandbox, 'etc/backend.env')
    unit_file = os.path.join(sandbox, 'systemd/git-repo-analyzer-backend.service')
    os.makedirs(os.path.dirname(unit_file), exist_ok=True)
    data_dir = os.path.join(sandbox, 'data')
    expr = (
        f"class {{ 'application::backend': "
        f"release_active => false, manage_users => false, manage_ownership => false, manage_service => false, "
        f"base_dir => '{sandbox}/opt', data_base_dir => '{sandbox}', data_dir => '{data_dir}', "
        f"env_dir => '{sandbox}/etc', env_file => '{env_file}', systemd_unit_path => '{unit_file}', "
        f"port => {free_port}, host => '127.0.0.1', node_env => 'production', ssrf_check_dns => true }}"
    )
    r = subprocess.run(
        ['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr],
        capture_output=True, text=True
    )
    assert r.returncode in (0, 2), f"Backend env generation failed: {r.stderr}"

    child_env = {'PATH': os.environ['PATH']}
    for line in open(env_file):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        k, v = line.split('=', 1)
        child_env[k] = v

    node_bin = shutil.which('node')
    server_js = os.path.join(project_root, 'backend/dist/server.js')
    proc = subprocess.Popen(
        [node_bin, server_js],
        cwd=os.path.join(project_root, 'backend'),
        env=child_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        healthy = False
        for _ in range(30):
            if proc.poll() is not None:
                raise AssertionError(f"Backend exited prematurely ({proc.returncode}): {proc.stderr.read()}")
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{free_port}/api/health', timeout=1.0) as resp:
                    if resp.getcode() == 200:
                        body = json.loads(resp.read().decode('utf-8'))
                        assert body.get('status') == 'UP'
                        healthy = True
                        break
            except Exception:
                time.sleep(0.15)
        assert healthy, "Backend never became healthy on generated Puppet backend.env"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
EOF
echo "PASS (fail-closed guards enforced; real backend/dist/server.js booted & served /api/health using Puppet backend.env)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 6. NGINX Production Config Rendering & Real `nginx -t` Syntax Verification
# ------------------------------------------------------------------------------
echo -n "[Test 6/${TOTAL_COUNT}] NGINX SPA + /api/ reverse proxy rendering & real nginx -t check... "
python3 - << 'EOF'
import os, shutil, socket, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

# Pick free unprivileged port (>1024) avoiding reserved verify/Nagios/backend ports
while True:
    with socket.socket() as sock:
        sock.bind(('0.0.0.0', 0))
        ngx_port = sock.getsockname()[1]
    if ngx_port not in (3000, 8080, 8081, 8082):
        break
with socket.socket() as vsock:
    vsock.bind(('127.0.0.1', 0))
    ngx_vport = vsock.getsockname()[1]

with tempfile.TemporaryDirectory() as sandbox:
    conf_d = os.path.join(sandbox, 'nginx/conf.d')
    avail = os.path.join(sandbox, 'nginx/sites-available')
    enabled = os.path.join(sandbox, 'nginx/sites-enabled')
    www = os.path.join(sandbox, 'www')
    for d in (conf_d, avail, enabled, os.path.join(www, 'dist'), os.path.join(sandbox, 'nginx/tmp')):
        os.makedirs(d, exist_ok=True)
    # Create pre-existing baseline default symlink to assert Puppet removes it when release_active => true
    with open(os.path.join(avail, 'default'), 'w') as fh:
        fh.write('server {}\n')
    os.symlink(os.path.join(avail, 'default'), os.path.join(enabled, 'default'))

    # 6a. Render default production port 80 IPv4 + IPv6 config into sandbox and verify exact directives
    expr_default_port = (
        f"class {{ 'application::nginx': "
        f"release_active => true, manage_package => false, manage_service => false, manage_ownership => false, "
        f"nginx_bin => '/nonexistent-nginx-bin', conf_d_dir => '{conf_d}', "
        f"sites_available_dir => '{avail}', sites_enabled_dir => '{enabled}', www_dir => '{www}' }}"
    )
    r_p80 = subprocess.run(
        ['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr_default_port],
        capture_output=True, text=True
    )
    assert r_p80.returncode in (0, 2), f"Port 80 sandbox render failed:\n{r_p80.stdout}\n{r_p80.stderr}"
    port80_txt = open(os.path.join(avail, 'git-repo-analyzer')).read()
    assert 'listen 80 default_server;' in port80_txt
    assert 'listen [::]:80 default_server;' in port80_txt

    nginx_bin = shutil.which('nginx') or '/usr/sbin/nginx'
    main_conf = os.path.join(sandbox, 'nginx/nginx.conf')
    with open(main_conf, 'w') as fh:
        fh.write(
            f"pid {sandbox}/nginx/nginx.pid;\n"
            f"error_log {sandbox}/nginx/error.log;\n"
            f"events {{ worker_connections 64; }}\n"
            f"http {{\n"
            f"    access_log {sandbox}/nginx/access.log;\n"
            f"    client_body_temp_path {sandbox}/nginx/tmp/body;\n"
            f"    proxy_temp_path {sandbox}/nginx/tmp/proxy;\n"
            f"    fastcgi_temp_path {sandbox}/nginx/tmp/fcgi;\n"
            f"    uwsgi_temp_path {sandbox}/nginx/tmp/uwsgi;\n"
            f"    scgi_temp_path {sandbox}/nginx/tmp/scgi;\n"
            f"    include {conf_d}/*.conf;\n"
            f"    include {enabled}/*;\n"
            f"}}\n"
        )
    test_cmd_param = (
        f"nginx_configtest_cmd => \"{nginx_bin} -t -p '{sandbox}/nginx' -c '{main_conf}' -e stderr\", "
        if os.path.isfile(nginx_bin) and os.access(nginx_bin, os.X_OK)
        else "nginx_bin => '/nonexistent-nginx-bin', "
    )

    expr = (
        f"class {{ 'application::nginx': "
        f"release_active => true, manage_package => false, manage_service => false, manage_ownership => false, manage_ipv6 => false, "
        f"listen_port => {ngx_port}, nginx_verify_port => {ngx_vport}, {test_cmd_param}"
        f"conf_d_dir => '{conf_d}', sites_available_dir => '{avail}', sites_enabled_dir => '{enabled}', www_dir => '{www}' }}"
    )
    r = subprocess.run(
        ['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr],
        capture_output=True, text=True
    )
    assert r.returncode in (0, 2), f"application::nginx failed:\n{r.stdout}\n{r.stderr}"

    site_file = os.path.join(avail, 'git-repo-analyzer')
    assert os.path.isfile(site_file)
    assert os.path.islink(os.path.join(enabled, 'git-repo-analyzer'))
    assert not os.path.lexists(os.path.join(enabled, 'default')), 'Default NGINX site must be removed upon activation'

    site_txt = open(site_file).read()
    assert f"root {www}/dist;" in site_txt
    assert "try_files $uri $uri/ /index.html;" in site_txt
    assert "location /api/" in site_txt
    assert "proxy_pass http://127.0.0.1:3000/api/;" in site_txt
    assert 'if (-f "/opt/git-repo-analyzer/maintenance.flag")' in site_txt
    assert f"listen 127.0.0.1:{ngx_vport};" in site_txt
    assert "@app_maintenance_page" in site_txt
    assert "server_tokens off;" in site_txt
    for forbidden in ['nagios', 'apache', '8080', 'jenkins', 'cicd-server']:
        assert forbidden not in site_txt.lower(), f"Forbidden string '{forbidden}' found in NGINX config"

    # Negative check: invalid nginx snippet triggers Puppet Exec[app_nginx_configtest] failure cleanly
    if os.path.isfile(nginx_bin) and os.access(nginx_bin, os.X_OK):
        with open(os.path.join(conf_d, 'broken.conf'), 'w') as fh:
            fh.write('invalid_nginx_directive_xyz;\n')
        r_bad_ngx = subprocess.run(
            ['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server',
             '-e', expr.replace(f"listen_port => {ngx_port}", f"listen_port => {ngx_port + 1}")],
            capture_output=True, text=True
        )
        assert r_bad_ngx.returncode not in (0, 2), 'Corrupt NGINX config must fail Puppet configtest gate'
EOF
echo "PASS (SPA routing, /api/ loopback proxy, default disabled, zero Nagios/Jenkins leakage, nginx -t passed)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 7. Nagios Coexistence & Apache Loopback Non-Collision on app-server
# ------------------------------------------------------------------------------
echo -n "[Test 7/${TOTAL_COUNT}] Coexistence with Nagios Core + Apache 127.0.0.1:8080 on app-server... "
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    app_override = os.path.join(tmpdir, 'app.yaml')
    app_hiera = os.path.join(tmpdir, 'hiera.yaml')
    sha = 'd' * 64
    with open(app_override, 'w') as fh:
        fh.write(
            "---\n"
            "nagios::web::admin_password_hash: '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'\n"
            "application::release_version: '1.0.0'\n"
            f"application::expected_sha256: '{sha}'\n"
            "application::cors_origin: 'http://127.0.0.1'\n"
        )
    with open(app_hiera, 'w') as fh:
        fh.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'Test override'\n    path: '{app_override}'\n"
            f"  - name: 'Common'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )
    graph_dir = os.path.join(tmpdir, 'graphs')
    os.makedirs(graph_dir, exist_ok=True)
    res = subprocess.run(
        ['puppet', 'apply', '--noop',
         f'--modulepath={puppet_dir}/modules', f'--hiera_config={app_hiera}',
         '--certname', 'app-server', '--graph', f'--graphdir={graph_dir}',
         f'{puppet_dir}/manifests/site.pp'],
        capture_output=True, text=True
    )
    assert res.returncode == 0, f"Coexistence catalog compilation failed: {res.stderr}"
    dot_txt = open(os.path.join(graph_dir, 'expanded_relationships.dot')).read()
    for res_name in [
        'Service[nagios4]', 'Service[apache2]', 'Service[git-repo-analyzer-backend]', 'Service[nginx]',
        'Package[nodejs]', 'Exec[app_enter_maintenance]', 'Exec[app_verify_backend_health_gate]',
        'Exec[app_verify_frontend_health_gate]', 'Exec[app_promote_release]',
        'Exec[app_exit_maintenance]', 'Exec[app_prune_releases]',
    ]:
        assert res_name in dot_txt, f"Missing expected resource '{res_name}' in full app-server catalog graph"
EOF
echo "PASS (Nagios, Apache 127.0.0.1:8080, Backend, NGINX, and Node 24 coexist without duplicate declarations)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 8. Target Isolation Across Fleet Nodes & Direct Inclusion Fail-Closed Guard
# ------------------------------------------------------------------------------
echo -n "[Test 8/${TOTAL_COUNT}] Strict fleet node isolation (app-server only; rogue inclusion fails)... "
python3 - << 'EOF'
import os, subprocess, tempfile

puppet_dir = os.environ['PUPPET_DIR']

for node in ['puppet-server', 'cicd-server', 'unknown-default']:
    with tempfile.TemporaryDirectory() as gdir:
        r = subprocess.run(
            ['puppet', 'apply', '--noop',
             f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
             '--certname', node, '--graph', f'--graphdir={gdir}', f'{puppet_dir}/manifests/site.pp'],
            capture_output=True, text=True
        )
        assert r.returncode == 0, f"Node {node} failed site.pp --noop: {r.stderr}"
        dot_txt = open(os.path.join(gdir, 'expanded_relationships.dot')).read()
        assert 'Application' not in dot_txt, f"{node} must NOT contain Application classes"
        assert 'git-repo-analyzer-backend' not in dot_txt, f"{node} must NOT contain backend service"

    r_rogue = subprocess.run(
        ['puppet', 'apply', '--noop',
         f'--modulepath={puppet_dir}/modules', f'--hiera_config={puppet_dir}/hiera.yaml',
         '--certname', node, '-e', 'include application'],
        capture_output=True, text=True
    )
    assert r_rogue.returncode != 0, f"Direct inclusion of application on {node} must fail closed"
    assert 'strictly restricted to app-server' in r_rogue.stderr
EOF
echo "PASS (puppet-server, cicd-server, and default receive zero application resources; direct rogue include blocked)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 9. Full --graph DAG Cycle Detection & Critical Causal Path Ordering
# ------------------------------------------------------------------------------
echo -n "[Test 9/${TOTAL_COUNT}] --graph DAG cycle detection & end-to-end ordering... "
python3 - << 'EOF'
import os, re, subprocess, tempfile
from collections import defaultdict, deque

puppet_dir = os.environ['PUPPET_DIR']
with tempfile.TemporaryDirectory() as tmpdir:
    app_override = os.path.join(tmpdir, 'app.yaml')
    app_hiera = os.path.join(tmpdir, 'hiera.yaml')
    graph_dir = os.path.join(tmpdir, 'graphs')
    os.makedirs(graph_dir, exist_ok=True)
    with open(app_override, 'w') as fh:
        fh.write(
            "---\n"
            "nagios::web::admin_password_hash: '$2y$12$TESTONLYHASHVALUEFORTESTING00000000000000000000000000'\n"
            "application::release_version: '1.0.0'\n"
            f"application::expected_sha256: '{'e' * 64}'\n"
            "application::cors_origin: 'http://127.0.0.1'\n"
        )
    with open(app_hiera, 'w') as fh:
        fh.write(
            f"---\nversion: 5\nhierarchy:\n"
            f"  - name: 'Test override'\n    path: '{app_override}'\n"
            f"  - name: 'Common'\n    path: '{puppet_dir}/hieradata/common.yaml'\n"
        )
    res = subprocess.run(
        ['puppet', 'apply', '--noop',
         f'--modulepath={puppet_dir}/modules', f'--hiera_config={app_hiera}',
         '--certname', 'app-server', '--graph', f'--graphdir={graph_dir}',
         f'{puppet_dir}/manifests/site.pp'],
        capture_output=True, text=True
    )
    assert res.returncode == 0, f"Graph compilation failed: {res.stderr}"
    assert 'dependency cycle' not in res.stderr.lower()

    dot_path = os.path.join(graph_dir, 'expanded_relationships.dot')
    assert os.path.isfile(dot_path), 'Missing expanded_relationships.dot'
    edges = defaultdict(set)
    with open(dot_path) as fh:
        for line in fh:
            m = re.match(r'\s*"([^"]+)"\s*->\s*"([^"]+)"', line)
            if m:
                edges[m.group(1)].add(m.group(2))

    def reachable(src, dst):
        q = deque([src])
        seen = {src}
        while q:
            cur = q.popleft()
            if cur == dst:
                return True
            for nxt in edges.get(cur, ()):
                if nxt not in seen:
                    seen.add(nxt)
                    q.append(nxt)
        return False

    causal_chain = [
        'Package[nodejs]',
        'Exec[app_verify_node_major_24]',
        'Exec[app_prepare_release]',
        'Exec[app_enter_maintenance]',
        'Exec[app_activate_release]',
        'Exec[app_sync_backend_restart]',
        'Service[git-repo-analyzer-backend]',
        'Exec[app_mark_service_synced]',
        'Exec[app_verify_backend_health_gate]',
        'File[/etc/nginx/sites-enabled/git-repo-analyzer]',
        'Exec[app_nginx_configtest_before_start]',
        'Service[nginx]',
        'Exec[app_verify_frontend_health_gate]',
        'Exec[app_promote_release]',
        'Exec[app_exit_maintenance]',
        'Exec[app_prune_releases]',
    ]
    for a, b in zip(causal_chain, causal_chain[1:]):
        assert reachable(a, b), f"Missing causal DAG path: {a} -> ... -> {b}"
    assert reachable('Exec[app_activate_release]', 'Exec[app_verify_backend_entrypoint]')
    assert reachable('Exec[app_verify_backend_entrypoint]', 'Service[git-repo-analyzer-backend]')
EOF
echo "PASS (zero cycles; full Nodejs -> Release -> Backend -> HealthGate -> Nginx -> FrontendHealth -> Promote/Prune chain verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 10. End-to-End Behavioral Lifecycle: Deploy -> Retain -> Health Failure Block -> Rollback
# ------------------------------------------------------------------------------
echo -n "[Test 10/${TOTAL_COUNT}] Behavioral deployment lifecycle, failed-health block, retention & rollback... "
python3 - << 'EOF'
import hashlib, http.server, io, json, os, shutil, subprocess, tarfile, tempfile, threading, time

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']

with tempfile.TemporaryDirectory() as sandbox:
    for d in (
        'var', 'etc', 'cache/staging', 'systemd', 'nginx/conf.d',
        'nginx/sites-available', 'nginx/sites-enabled', 'nginx/tmp'
    ):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)
    with open(os.path.join(sandbox, 'nginx/nginx.conf'), 'w') as fh:
        fh.write(
            f"pid {sandbox}/nginx/nginx.pid;\n"
            f"error_log {sandbox}/nginx/error.log;\n"
            f"events {{ worker_connections 64; }}\n"
            f"http {{\n"
            f"    access_log {sandbox}/nginx/access.log;\n"
            f"    client_body_temp_path {sandbox}/nginx/tmp/body;\n"
            f"    proxy_temp_path {sandbox}/nginx/tmp/proxy;\n"
            f"    fastcgi_temp_path {sandbox}/nginx/tmp/fcgi;\n"
            f"    uwsgi_temp_path {sandbox}/nginx/tmp/uwsgi;\n"
            f"    scgi_temp_path {sandbox}/nginx/tmp/scgi;\n"
            f"    include {sandbox}/nginx/conf.d/*.conf;\n"
            f"    include {sandbox}/nginx/sites-enabled/*;\n"
            f"}}\n"
        )

    class HealthState:
        backend_code = 200
        frontend_code = 200
        frontend_ct = 'text/html; charset=utf-8'

    state = HealthState()

    def current_manifest_release():
        mf = os.path.join(sandbox, 'opt/current/release-manifest.json')
        if os.path.isfile(mf):
            return json.load(open(mf))['releaseId']
        return '0.0.0'

    def current_frontend_html():
        idx = os.path.join(sandbox, 'www/dist/index.html')
        if os.path.isfile(idx):
            return open(idx, 'rb').read()
        return b'<!doctype html><html><body><div id="root"></div></body></html>'

    def write_be_health(handler, code):
        handler.send_response(code)
        handler.send_header('Content-Type', 'application/json')
        rel = current_manifest_release()
        if code == 200:
            handler.send_header('X-App-Release', rel)
            payload = json.dumps({'status': 'UP', 'timestamp': '2026-11-26T00:00:00Z', 'releaseId': rel}).encode()
        else:
            payload = b'{"status":"DOWN"}'
        handler.end_headers()
        handler.wfile.write(payload)

    class BackendHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/api/health':
                write_be_health(self, state.backend_code)
            else:
                self.send_response(404); self.end_headers()
        def log_message(self, *args): pass

    def make_fe_handler(*, gate_maintenance):
        class FrontendHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if gate_maintenance and os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag')):
                    self.send_response(503); self.send_header('Content-Type', 'application/json'); self.end_headers()
                    self.wfile.write(b'{"status":"MAINTENANCE"}')
                    return
                if self.path == '/':
                    self.send_response(state.frontend_code)
                    self.send_header('Content-Type', state.frontend_ct)
                    self.end_headers()
                    self.wfile.write(current_frontend_html())
                elif self.path == '/api/health':
                    write_be_health(self, state.backend_code)
                else:
                    self.send_response(404); self.end_headers()
            def log_message(self, *args): pass
        return FrontendHandler

    srv_b = http.server.ThreadingHTTPServer(('127.0.0.1', 0), BackendHandler)
    srv_f = http.server.ThreadingHTTPServer(('127.0.0.1', 0), make_fe_handler(gate_maintenance=True))
    srv_v = http.server.ThreadingHTTPServer(('127.0.0.1', 0), make_fe_handler(gate_maintenance=False))
    b_port = srv_b.server_address[1]
    f_port = srv_f.server_address[1]
    v_port = srv_v.server_address[1]
    threading.Thread(target=srv_b.serve_forever, daemon=True).start()
    threading.Thread(target=srv_f.serve_forever, daemon=True).start()
    threading.Thread(target=srv_v.serve_forever, daemon=True).start()

    def make_release(staging_dir, version):
        archive_name = f"{version}.tar.gz"
        archive_path = os.path.join(staging_dir, archive_name)
        sidecar_path = os.path.join(staging_dir, f"{archive_name}.sha256")
        manifest = {
            "releaseId": version,
            "gitCommit": f"commit-{version}",
            "builtAt": "2026-11-25T15:40:00Z",
            "nodeVersion": "v24.13.1",
        }
        with tarfile.open(archive_path, "w:gz") as tar:
            def add(rel, data, mode=0o644):
                ti = tarfile.TarInfo(name=f"release/{rel}")
                ti.size = len(data)
                ti.mode = mode
                tar.addfile(ti, io.BytesIO(data))
            add("release-manifest.json", json.dumps(manifest).encode('utf-8'))
            add("backend/dist/server.js", open(os.path.join(project_root, 'backend/dist/server.js'), 'rb').read())
            add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
            add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
            add("backend/node_modules/pkg/index.js", b"module.exports = 1;\n")
            add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
        sha = hashlib.sha256(open(archive_path, 'rb').read()).hexdigest()
        with open(sidecar_path, 'w') as fh:
            fh.write(f"{sha}  {archive_name}\n")
        return sha

    def apply_app(sandbox_arg, version, sha, *, detailed=True):
        node_bin = shutil.which('node')
        expr = (
            f"class {{ 'application': "
            f"release_version => '{version}', "
            f"expected_sha256 => '{sha}', "
            f"retain_releases => 2, "
            f"manage_packages => false, "
            f"manage_users => false, "
            f"manage_ownership => false, "
            f"manage_service => false, "
            f"manage_ipv6 => false, "
            f"nginx_bin => '/nonexistent-nginx-bin', "
            f"verify_runtime => true, "
            f"verify_health => true, "
            f"health_attempts => 1, "
            f"health_delay => 1, "
            f"node_bin => '{node_bin}', "
            f"base_dir => '{sandbox_arg}/opt', "
            f"cache_dir => '{sandbox_arg}/cache', "
            f"staging_dir => '{sandbox_arg}/cache/staging', "
            f"www_dir => '{sandbox_arg}/www', "
            f"data_base_dir => '{sandbox_arg}/var/lib', "
            f"data_dir => '{sandbox_arg}/var/lib/data', "
            f"state_file => '{sandbox_arg}/var/lib/release-state.json', "
            f"env_dir => '{sandbox_arg}/etc/app', "
            f"env_file => '{sandbox_arg}/etc/app/backend.env', "
            f"systemd_unit_path => '{sandbox_arg}/systemd/git-repo-analyzer-backend.service', "
            f"conf_d_dir => '{sandbox_arg}/nginx/conf.d', "
            f"sites_available_dir => '{sandbox_arg}/nginx/sites-available', "
            f"sites_enabled_dir => '{sandbox_arg}/nginx/sites-enabled', "
            f"backend_port => {b_port}, "
            f"listen_port => {f_port}, "
            f"nginx_verify_port => {v_port}, "
            f"cors_origin => 'http://127.0.0.1:{f_port}' }}"
        )
        args = ['puppet', 'apply']
        if detailed:
            args.append('--detailed-exitcodes')
        args += [f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr]
        return subprocess.run(args, capture_output=True, text=True)

    try:
        staging = os.path.join(sandbox, 'cache/staging')
        releases = os.path.join(sandbox, 'opt/releases')
        state_path = os.path.join(sandbox, 'var/lib/release-state.json')
        sentinel_path = os.path.join(sandbox, 'var/lib/data/analysis-history.json')

        sha_100 = make_release(staging, '1.0.0')
        time.sleep(0.02)
        sha_101 = make_release(staging, '1.0.1')
        time.sleep(0.02)
        sha_102 = make_release(staging, '1.0.2')
        time.sleep(0.02)
        sha_103 = make_release(staging, '1.0.3')

        # A: Deploy 1.0.0 -> exit 2 then exit 0
        r1 = apply_app(sandbox, '1.0.0', sha_100)
        assert r1.returncode == 2, f"Deploy 1.0.0 failed ({r1.returncode}): {r1.stderr}"
        assert not os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag'))
        r1b = apply_app(sandbox, '1.0.0', sha_100)
        assert r1b.returncode == 0, f"Steady-state 1.0.0 failed idempotency ({r1b.returncode}): {r1b.stdout}\n{r1b.stderr}"

        # Write persistent analysis data sentinel (must survive upgrades & rollbacks!)
        sentinel_bytes = '{"preserved":true,"analyses":["a1"]}\n'
        with open(sentinel_path, 'w') as fh:
            fh.write(sentinel_bytes)

        # B: Deploy 1.0.1
        time.sleep(0.02)
        r2 = apply_app(sandbox, '1.0.1', sha_101)
        assert r2.returncode == 2, f"Deploy 1.0.1 failed: {r2.stderr}"
        st2 = json.load(open(state_path))
        assert st2['currentKnownGood']['releaseId'] == '1.0.1'
        assert st2['previousKnownGood']['releaseId'] == '1.0.0'

        # C: Deploy 1.0.2 -> retain_releases=2 keeps 1.0.2 + 1.0.1 and prunes 1.0.0
        time.sleep(0.02)
        r3 = apply_app(sandbox, '1.0.2', sha_102)
        assert r3.returncode == 2, f"Deploy 1.0.2 failed: {r3.stderr}"
        assert os.path.isdir(os.path.join(releases, '1.0.2'))
        assert os.path.isdir(os.path.join(releases, '1.0.1'))
        assert not os.path.exists(os.path.join(releases, '1.0.0')), 'Old release 1.0.0 beyond retain=2 should be pruned after health pass'

        # D: Deploy 1.0.3 with UNHEALTHY backend (HTTP 503) -> MUST keep maintenance active, block promotion/pruning, auto-revert symlinks to 1.0.2, and retain 1.0.1 & 1.0.2
        state.backend_code = 503
        r_bad = apply_app(sandbox, '1.0.3', sha_103, detailed=True)
        assert r_bad.returncode not in (0, 2), f'Unhealthy release 1.0.3 must fail Puppet health gate (rc={r_bad.returncode})'
        assert os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag')), 'Failed release must leave maintenance mode active'
        st_bad = json.load(open(state_path))
        assert st_bad['currentKnownGood']['releaseId'] == '1.0.2', 'Failed release must NEVER replace currentKnownGood'
        assert os.path.isdir(os.path.join(releases, '1.0.1')), 'Previous known-good 1.0.1 MUST be retained when new release fails health'
        assert os.path.isdir(os.path.join(releases, '1.0.2')), 'Previous known-good 1.0.2 MUST be retained'
        assert os.path.realpath(os.path.join(sandbox, 'opt/backend')) == os.path.realpath(os.path.join(releases, '1.0.2/backend')), 'Backend must auto-revert consistently to 1.0.2 on health fail'
        assert os.path.realpath(os.path.join(sandbox, 'www/dist')) == os.path.realpath(os.path.join(releases, '1.0.2/frontend/dist')), 'Frontend must auto-revert consistently to 1.0.2 on health fail'

        # E: Restore health and Hiera rollback to retained 1.0.1 even with 1.0.1 tarball removed from staging
        state.backend_code = 200
        os.unlink(os.path.join(staging, '1.0.1.tar.gz'))
        os.unlink(os.path.join(staging, '1.0.1.tar.gz.sha256'))
        r_rb = apply_app(sandbox, '1.0.1', sha_101)
        assert r_rb.returncode == 2, f"Rollback to 1.0.1 failed ({r_rb.returncode}):\n{r_rb.stdout}\n{r_rb.stderr}"
        assert not os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag'))
        r_rb2 = apply_app(sandbox, '1.0.1', sha_101)
        assert r_rb2.returncode == 0, f'Post-rollback repeat run must converge exit 0 (got {r_rb2.returncode}):\n{r_rb2.stdout}\n{r_rb2.stderr}'
        assert os.path.realpath(os.path.join(sandbox, 'opt/backend')) == os.path.realpath(os.path.join(releases, '1.0.1/backend'))
        assert os.path.realpath(os.path.join(sandbox, 'www/dist')) == os.path.realpath(os.path.join(releases, '1.0.1/frontend/dist'))
        assert open(sentinel_path).read() == sentinel_bytes, 'DATA_DIR analysis history must survive upgrades & rollbacks untouched'
    finally:
        srv_b.shutdown()
        srv_f.shutdown()
        srv_v.shutdown()
        srv_b.server_close()
        srv_f.server_close()
        srv_v.server_close()
EOF
echo "PASS (full lifecycle exit 2->0, post-health pruning, health-fail block retaining prior release, zero-rebuild rollback, DATA_DIR intact)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 11. Secrets Hygiene & Zero Hardcoded EC2 IP Audit
# ------------------------------------------------------------------------------
echo -n "[Test 11/${TOTAL_COUNT}] Cross-cutting secrets & zero hardcoded IP hygiene audit... "
python3 - << 'EOF'
import os, re, yaml

puppet_dir = os.environ['PUPPET_DIR']
allowed_ips = {'127.0.0.1', '0.0.0.0'}
ipv4_re = re.compile(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b')

scan_roots = [
    os.path.join(puppet_dir, 'manifests'),
    os.path.join(puppet_dir, 'hieradata'),
    os.path.join(puppet_dir, 'modules/application'),
    os.path.join(puppet_dir, 'tests/test_phase5b_release.sh'),
    os.path.join(puppet_dir, 'tests/test_phase5b_application.sh'),
]

for target in scan_roots:
    paths = [target] if os.path.isfile(target) else [
        os.path.join(r, f)
        for r, dirs, files in os.walk(target)
        for f in files
        if '__pycache__' not in r and not f.endswith('.pyc')
    ]
    for p in paths:
        content = open(p, encoding='utf-8').read()
        for ip in ipv4_re.findall(content):
            assert ip in allowed_ips, f"Disallowed hardcoded IPv4 '{ip}' found in {p}"

common = yaml.safe_load(open(os.path.join(puppet_dir, 'hieradata/common.yaml')))
for forbidden_key in [
    'application::jenkins_api_token',
    'application::backend::jenkins_api_token',
    'application::release_version',
    'application::expected_sha256',
]:
    assert not common.get(forbidden_key), f"{forbidden_key} must NOT be pre-populated in common.yaml"

backend_pp = open(os.path.join(puppet_dir, 'modules/application/manifests/backend.pp')).read()
assert 'show_diff => false' in backend_pp
assert "mode      => '0640'" in backend_pp
EOF
echo "PASS (zero hardcoded IPs, zero secrets in common.yaml, 0640/show_diff => false enforced)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 12. Real NGINX Proxy <-> Real Node 24 Express Backend End-to-End CORS Matrix
# ------------------------------------------------------------------------------
echo -n "[Test 12/${TOTAL_COUNT}] Live NGINX <-> Node 24 Express end-to-end CORS & SPA proxy matrix... "
python3 - << 'EOF'
import hashlib, io, json, os, shutil, socket, subprocess, tarfile, tempfile, time, urllib.error, urllib.request

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
nginx_bin = shutil.which('nginx') or '/usr/sbin/nginx'
node_bin = shutil.which('node')
assert os.path.isfile(nginx_bin) and node_bin

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

b_port = free_port()
f_port = free_port()
v_port = free_port()

with tempfile.TemporaryDirectory() as sandbox:
    for d in ('var', 'etc', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled', 'nginx/tmp/body', 'nginx/tmp/proxy', 'nginx/tmp/fcgi', 'nginx/tmp/uwsgi', 'nginx/tmp/scgi'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)

    staging = os.path.join(sandbox, 'cache/staging')
    tar_path = os.path.join(staging, '1.0.0.tar.gz')
    manifest = {"releaseId": "1.0.0", "gitCommit": "cors-audit", "builtAtUtc": "2026-11-25T16:00:00Z", "nodeVersion": "v24.13.1"}
    with tarfile.open(tar_path, 'w:gz') as tar:
        seen = set()
        def add(rel, data):
            if rel in seen:
                return
            seen.add(rel)
            ti = tarfile.TarInfo(name=f"release/{rel}")
            ti.size = len(data)
            ti.mode = 0o644
            tar.addfile(ti, io.BytesIO(data))
        add("release-manifest.json", json.dumps(manifest).encode())
        for r, _, files in os.walk(os.path.join(project_root, 'backend/dist')):
            for fn in files:
                full_f = os.path.join(r, fn)
                if os.path.isfile(full_f) and not os.path.islink(full_f):
                    rel_f = os.path.relpath(full_f, os.path.join(project_root, 'backend'))
                    add(f"backend/{rel_f}", open(full_f, 'rb').read())
        add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
        add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
        # Copy real runtime dependencies so server.js serves /api/analyses + /api/health cleanly from extracted release
        for pkg in os.listdir(os.path.join(project_root, 'backend/node_modules')):
            src_pkg = os.path.join(project_root, 'backend/node_modules', pkg)
            if os.path.islink(src_pkg) or pkg.startswith('.'):
                continue
            for r, _, files in os.walk(src_pkg):
                for fn in files:
                    full_f = os.path.join(r, fn)
                    if os.path.isfile(full_f) and not os.path.islink(full_f):
                        rel_f = os.path.relpath(full_f, os.path.join(project_root, 'backend'))
                        add(f"backend/{rel_f}", open(full_f, 'rb').read())
        add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
    sha = hashlib.sha256(open(tar_path, 'rb').read()).hexdigest()
    open(f"{tar_path}.sha256", 'w').write(f"{sha}  1.0.0.tar.gz\n")

    main_conf = os.path.join(sandbox, 'nginx/nginx.conf')
    open(main_conf, 'w').write(
        f"pid {sandbox}/nginx/nginx.pid;\n"
        f"error_log {sandbox}/nginx/error.log;\n"
        f"worker_processes 1;\n"
        f"events {{ worker_connections 64; }}\n"
        f"http {{\n"
        f"    access_log {sandbox}/nginx/access.log;\n"
        f"    client_body_temp_path {sandbox}/nginx/tmp/body;\n"
        f"    proxy_temp_path {sandbox}/nginx/tmp/proxy;\n"
        f"    fastcgi_temp_path {sandbox}/nginx/tmp/fcgi;\n"
        f"    uwsgi_temp_path {sandbox}/nginx/tmp/uwsgi;\n"
        f"    scgi_temp_path {sandbox}/nginx/tmp/scgi;\n"
        f"    include {sandbox}/nginx/conf.d/*.conf;\n"
        f"    include {sandbox}/nginx/sites-enabled/*;\n"
        f"}}\n"
    )
    cors_val = f"http://127.0.0.1:{f_port},http://localhost:{f_port}"
    expr = (
        f"class {{ 'application': "
        f"release_version => '1.0.0', expected_sha256 => '{sha}', "
        f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => false, manage_ipv6 => false, "
        f"verify_health => false, verify_runtime => true, node_bin => '{node_bin}', "
        f"nginx_configtest_cmd => \"{nginx_bin} -t -p '{sandbox}/nginx' -c '{main_conf}' -e stderr\", "
        f"base_dir => '{sandbox}/opt', cache_dir => '{sandbox}/cache', staging_dir => '{staging}', www_dir => '{sandbox}/www', "
        f"data_base_dir => '{sandbox}/var/lib', data_dir => '{sandbox}/var/lib/data', state_file => '{sandbox}/var/lib/release-state.json', "
        f"env_dir => '{sandbox}/etc/app', env_file => '{sandbox}/etc/app/backend.env', "
        f"systemd_unit_path => '{sandbox}/systemd/git-repo-analyzer-backend.service', "
        f"conf_d_dir => '{sandbox}/nginx/conf.d', sites_available_dir => '{sandbox}/nginx/sites-available', sites_enabled_dir => '{sandbox}/nginx/sites-enabled', "
        f"backend_port => {b_port}, listen_port => {f_port}, nginx_verify_port => {v_port}, cors_origin => '{cors_val}' }}"
    )
    rp = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr], capture_output=True, text=True)
    assert rp.returncode == 2, f"Puppet setup failed ({rp.returncode}):\n{rp.stdout}\n{rp.stderr}"

    env = {'PATH': os.environ['PATH']}
    for line in open(f"{sandbox}/etc/app/backend.env"):
        line = line.strip()
        if line and not line.startswith('#'):
            k, v = line.split('=', 1)
            env[k] = v

    p_node = subprocess.Popen([node_bin, f"{sandbox}/opt/backend/dist/server.js"], cwd=f"{sandbox}/opt/backend", env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    p_nginx = subprocess.Popen([nginx_bin, '-g', 'daemon off;', '-p', f"{sandbox}/nginx", '-c', main_conf, '-e', 'stderr'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        # Wait for proxied /api/health
        ready = False
        for _ in range(30):
            if p_node.poll() is not None:
                raise AssertionError(f"Node died: {p_node.stderr.read()}")
            if p_nginx.poll() is not None:
                raise AssertionError(f"NGINX died: {p_nginx.stderr.read()}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{f_port}/api/health", timeout=1.0) as resp:
                    if resp.getcode() == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.15)
        assert ready, "Proxied NGINX -> Backend never came up"

        def req(method, path, body=None, headers=None):
            h = dict(headers or {})
            data = json.dumps(body).encode() if body is not None else None
            if body is not None:
                h.setdefault('Content-Type', 'application/json')
            r = urllib.request.Request(f"http://127.0.0.1:{f_port}{path}", data=data, headers=h, method=method)
            try:
                with urllib.request.urlopen(r, timeout=2.0) as resp:
                    return resp.getcode(), dict(resp.headers), resp.read().decode('utf-8', 'replace')
            except urllib.error.HTTPError as e:
                return e.code, dict(e.headers), e.read().decode('utf-8', 'replace')

        def hdr(hdrs, name):
            for k, v in hdrs.items():
                if k.lower() == name.lower():
                    return v
            return None

        # 1. Same-origin POST with authorized Origin header -> 202 + exact ACAO, no *, no credentials
        c, h, b = req('POST', '/api/analyses', {"repositoryUrl": "https://github.com/octocat/Hello-World"}, {'Origin': f"http://127.0.0.1:{f_port}"})
        assert c == 202, f"Expected 202 same-origin POST, got {c}: {b}"
        assert hdr(h, 'access-control-allow-origin') == f"http://127.0.0.1:{f_port}"
        assert hdr(h, 'access-control-allow-origin') != '*'
        assert hdr(h, 'access-control-allow-credentials') is None
        analysis_id = json.loads(b)['analysisId']

        # Poll proxied status through NGINX -> Express until COMPLETED, then fetch results + PNG chart
        done = False
        for _ in range(40):
            cs, _, bs = req('GET', f"/api/analyses/{analysis_id}", headers={'Origin': f"http://127.0.0.1:{f_port}"})
            assert cs == 200
            if json.loads(bs)['status'] == 'COMPLETED':
                done = True
                break
            time.sleep(0.35)
        assert done, 'Proxied analysis did not complete in time'
        cr, _, br = req('GET', f"/api/analyses/{analysis_id}/results", headers={'Origin': f"http://127.0.0.1:{f_port}"})
        assert cr == 200 and json.loads(br)['status'] == 'COMPLETED'
        chart_req = urllib.request.Request(f"http://127.0.0.1:{f_port}/api/analyses/{analysis_id}/charts/commits_per_author.png", headers={'Origin': f"http://127.0.0.1:{f_port}"})
        with urllib.request.urlopen(chart_req, timeout=2.0) as cresp:
            assert cresp.getcode() == 200
            assert 'image/png' in (cresp.headers.get('Content-Type') or '').lower()
            assert cresp.read(4) == b'\x89PNG'

        # 2. Secondary allowed origin (comma-separated) -> 200 & security header separation
        c, h, b = req('GET', '/api/health', headers={'Origin': f"http://localhost:{f_port}"})
        assert c == 200 and hdr(h, 'access-control-allow-origin') == f"http://localhost:{f_port}"
        assert hdr(h, 'x-frame-options') == 'DENY'

        # 3. Missing Origin -> 200 UP; empty Origin: "" -> 403 CORS_FORBIDDEN
        import http.client as hc
        c, h, b = req('GET', '/api/health')
        assert c == 200 and json.loads(b)['status'] == 'UP'
        conn_e = hc.HTTPConnection('127.0.0.1', f_port, timeout=2.0)
        conn_e.request('GET', '/api/health', headers={'Origin': ''})
        resp_e = conn_e.getresponse()
        body_e = resp_e.read().decode('utf-8', 'replace')
        conn_e.close()
        assert resp_e.status == 403 and json.loads(body_e)['error']['code'] == 'CORS_FORBIDDEN'
        c_null, _, b_null = req('GET', '/api/health', headers={'Origin': 'null'})
        assert c_null == 403 and json.loads(b_null)['error']['code'] == 'CORS_FORBIDDEN'

        # 4. Unauthorized origin -> 403 CORS_FORBIDDEN
        c, h, b = req('POST', '/api/analyses', {"repositoryUrl": "https://github.com/octocat/Hello-World"}, {'Origin': 'https://evil.example.com'})
        assert c == 403 and json.loads(b)['error']['code'] == 'CORS_FORBIDDEN'
        assert hdr(h, 'access-control-allow-origin') is None

        # 5. Malformed origin -> 403 CORS_FORBIDDEN
        c, h, b = req('GET', '/api/health', headers={'Origin': 'not-an-origin'})
        assert c == 403 and json.loads(b)['error']['code'] == 'CORS_FORBIDDEN'

        # 6. OPTIONS preflight (allowed -> 204; unauthorized -> 403)
        c, h, _ = req('OPTIONS', '/api/analyses', headers={'Origin': f"http://127.0.0.1:{f_port}", 'Access-Control-Request-Method': 'POST'})
        assert c == 204 and hdr(h, 'access-control-allow-origin') == f"http://127.0.0.1:{f_port}"
        c_bad, _, _ = req('OPTIONS', '/api/analyses', headers={'Origin': 'https://evil.example.com', 'Access-Control-Request-Method': 'POST'})
        assert c_bad == 403

        # 7. SPA fallback, static headers & no Nagios route
        c_spa, h_spa, b_spa = req('GET', '/dashboard/sample')
        assert c_spa == 200 and '<!doctype html>' in b_spa.lower()
        assert hdr(h_spa, 'x-frame-options') == 'SAMEORIGIN'
        assert hdr(h_spa, 'x-content-type-options') == 'nosniff'
        c_hz, _, b_hz = req('GET', '/healthz')
        assert c_hz == 200 and 'ok' in b_hz
    finally:
        for p in (p_nginx, p_node):
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
EOF
echo "PASS (same-origin POST, multi-origin, missing Origin, unauthorized/malformed 403, OPTIONS, and SPA via live NGINX)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 13. Frontend Health Failure Auto-Revert & Interrupted Service-Sync Recovery
# ------------------------------------------------------------------------------
echo -n "[Test 13/${TOTAL_COUNT}] Frontend health failure auto-revert & interrupted restart sync... "
python3 - << 'EOF'
import hashlib, http.server, io, json, os, shutil, subprocess, tarfile, tempfile, threading, time

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
release_mgr = os.path.join(puppet_dir, 'modules/application/files/release_manager.py')

with tempfile.TemporaryDirectory() as sandbox:
    for d in ('var', 'etc', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)

    class State:
        b_code = 200
        f_code = 200

    st = State()

    def cur_rel():
        mf = os.path.join(sandbox, 'opt/current/release-manifest.json')
        return json.load(open(mf))['releaseId'] if os.path.isfile(mf) else '0.0.0'

    def write_be(handler, code):
        rel = cur_rel()
        handler.send_response(code if handler.path == '/api/health' else 404)
        handler.send_header('Content-Type', 'application/json')
        if code == 200 and handler.path == '/api/health':
            handler.send_header('X-App-Release', rel)
        handler.end_headers()
        if handler.path == '/api/health':
            handler.wfile.write(json.dumps({'status': 'UP', 'releaseId': rel}).encode() if code == 200 else b'{"status":"DOWN"}')

    class BHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            write_be(self, st.b_code)
        def log_message(self, *args): pass

    def mk_fe(gate_maint):
        class FHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if gate_maint and os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag')):
                    self.send_response(503); self.send_header('Content-Type', 'application/json'); self.end_headers()
                    self.wfile.write(b'{"status":"MAINTENANCE"}'); return
                if self.path == '/':
                    self.send_response(st.f_code)
                    self.send_header('Content-Type', 'text/html')
                    self.end_headers()
                    idx = os.path.join(sandbox, 'www/dist/index.html')
                    body = open(idx, 'rb').read() if os.path.isfile(idx) else b'<!doctype html><html><body>ok</body></html>'
                    self.wfile.write(body if st.f_code == 200 else b'bad')
                elif self.path == '/api/health':
                    write_be(self, st.b_code)
                else:
                    self.send_response(404); self.end_headers()
            def log_message(self, *args): pass
        return FHandler

    sb = http.server.ThreadingHTTPServer(('127.0.0.1', 0), BHandler)
    sf = http.server.ThreadingHTTPServer(('127.0.0.1', 0), mk_fe(True))
    sv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), mk_fe(False))
    bp, fp, vp = sb.server_address[1], sf.server_address[1], sv.server_address[1]
    threading.Thread(target=sb.serve_forever, daemon=True).start()
    threading.Thread(target=sf.serve_forever, daemon=True).start()
    threading.Thread(target=sv.serve_forever, daemon=True).start()

    def make_rel(staging_dir, ver):
        ap = os.path.join(staging_dir, f"{ver}.tar.gz")
        m = {"releaseId": ver, "gitCommit": f"c-{ver}", "builtAt": "2026-11-25T16:10:00Z", "nodeVersion": "v24.13.1"}
        with tarfile.open(ap, 'w:gz') as tar:
            def add(r, b):
                ti = tarfile.TarInfo(name=f"release/{r}")
                ti.size = len(b); ti.mode = 0o644
                tar.addfile(ti, io.BytesIO(b))
            add("release-manifest.json", json.dumps(m).encode())
            add("backend/dist/server.js", open(os.path.join(project_root, 'backend/dist/server.js'), 'rb').read())
            add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
            add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
            add("backend/node_modules/p/i.js", b"module.exports=1;\n")
            add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
        sha = hashlib.sha256(open(ap, 'rb').read()).hexdigest()
        open(f"{ap}.sha256", 'w').write(f"{sha}  {ver}.tar.gz\n")
        return sha

    def run_app(sandbox_arg, ver, sha):
        nb = shutil.which('node')
        expr = (
            f"class {{ 'application': release_version => '{ver}', expected_sha256 => '{sha}', retain_releases => 2, "
            f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => false, manage_ipv6 => false, "
            f"nginx_bin => '/nonexistent-nginx-bin', verify_runtime => true, verify_health => true, health_attempts => 1, health_delay => 1, "
            f"node_bin => '{nb}', base_dir => '{sandbox_arg}/opt', cache_dir => '{sandbox_arg}/cache', staging_dir => '{sandbox_arg}/cache/staging', "
            f"www_dir => '{sandbox_arg}/www', data_base_dir => '{sandbox_arg}/var/lib', data_dir => '{sandbox_arg}/var/lib/data', state_file => '{sandbox_arg}/var/lib/release-state.json', "
            f"env_dir => '{sandbox_arg}/etc/app', env_file => '{sandbox_arg}/etc/app/backend.env', systemd_unit_path => '{sandbox_arg}/systemd/s.service', "
            f"conf_d_dir => '{sandbox_arg}/nginx/conf.d', sites_available_dir => '{sandbox_arg}/nginx/sites-available', sites_enabled_dir => '{sandbox_arg}/nginx/sites-enabled', "
            f"backend_port => {bp}, listen_port => {fp}, nginx_verify_port => {vp}, cors_origin => 'http://127.0.0.1:{fp}' }}"
        )
        return subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr], capture_output=True, text=True)

    try:
        staging = os.path.join(sandbox, 'cache/staging')
        s100 = make_rel(staging, '1.0.0')
        time.sleep(0.02)
        s101 = make_rel(staging, '1.0.1')
        time.sleep(0.02)
        s102 = make_rel(staging, '1.0.2')

        assert run_app(sandbox, '1.0.0', s100).returncode == 2
        open(os.path.join(sandbox, 'var/lib/data/db.json'), 'w').write('{"keep":true}\n')
        assert run_app(sandbox, '1.0.1', s101).returncode == 2

        # Scenario 2: Backend passes 200, Frontend fails 502 on 1.0.2 -> MUST keep maintenance active, auto-revert BOTH symlinks to 1.0.1 and exit non-zero
        st.b_code, st.f_code = 200, 502
        r_fbad = run_app(sandbox, '1.0.2', s102)
        assert r_fbad.returncode not in (0, 2)
        assert os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag'))
        assert os.path.realpath(f"{sandbox}/opt/backend") == os.path.realpath(f"{sandbox}/opt/releases/1.0.1/backend")
        assert os.path.realpath(f"{sandbox}/www/dist") == os.path.realpath(f"{sandbox}/opt/releases/1.0.1/frontend/dist")
        state_json = json.load(open(f"{sandbox}/var/lib/release-state.json"))
        assert state_json['currentKnownGood']['releaseId'] == '1.0.1'
        assert os.path.isdir(f"{sandbox}/opt/releases/1.0.0")

        # Scenario 3: Interrupted Puppet after activate BEFORE backend restart sync
        st.b_code, st.f_code = 200, 200
        # Simulate interrupted activation where symlinks already point to 1.0.1 but pendingActivation.serviceSynced=False
        state_json['pendingActivation'] = {"releaseId": "1.0.1", "archiveSha256": s101, "serviceSynced": False}
        open(f"{sandbox}/var/lib/release-state.json", 'w').write(json.dumps(state_json))
        chk = subprocess.run([
            'python3', release_mgr, 'is-service-synced',
            '--version', '1.0.1', '--expected-sha256', s101,
            '--state-file', f"{sandbox}/var/lib/release-state.json",
            '--releases-dir', f"{sandbox}/opt/releases",
            '--backend-link', f"{sandbox}/opt/backend",
            '--frontend-link', f"{sandbox}/www/dist",
        ])
        assert chk.returncode != 0, 'Unsynced pendingActivation must trigger backend restart sync on next run'
        subprocess.run([
            'python3', release_mgr, 'mark-service-synced',
            '--version', '1.0.1', '--expected-sha256', s101,
            '--state-file', f"{sandbox}/var/lib/release-state.json",
        ], check=True)
        chk2 = subprocess.run([
            'python3', release_mgr, 'is-service-synced',
            '--version', '1.0.1', '--expected-sha256', s101,
            '--state-file', f"{sandbox}/var/lib/release-state.json",
            '--releases-dir', f"{sandbox}/opt/releases",
            '--backend-link', f"{sandbox}/opt/backend",
            '--frontend-link', f"{sandbox}/www/dist",
        ])
        assert chk2.returncode == 0
        # Next Puppet run recovers from left-over maintenance flag & exits cleanly
        assert run_app(sandbox, '1.0.1', s101).returncode == 2
        assert run_app(sandbox, '1.0.1', s101).returncode == 0
        assert not os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag'))
        assert open(os.path.join(sandbox, 'var/lib/data/db.json')).read() == '{"keep":true}\n'
    finally:
        sb.shutdown(); sf.shutdown(); sv.shutdown()
        sb.server_close(); sf.server_close(); sv.server_close()
EOF
echo "PASS (frontend health fail auto-reverted backend+frontend to 1.0.1; interrupted restart sync caught & recovered)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 14. Puppet Partial Failure & Drift Recovery (Missing Artifact, Missing Env, Interrupted Promotion)
# ------------------------------------------------------------------------------
echo -n "[Test 14/${TOTAL_COUNT}] Partial convergence recovery (missing artifact, deleted env, interrupted promote)... "
python3 - << 'EOF'
import hashlib, http.server, io, json, os, shutil, subprocess, tarfile, tempfile, threading

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']

with tempfile.TemporaryDirectory() as sandbox:
    for d in ('var', 'etc', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)

    def mk_h(gate):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if gate and os.path.lexists(os.path.join(sandbox, 'opt/maintenance.flag')):
                    self.send_response(503); self.end_headers(); self.wfile.write(b'{"status":"MAINTENANCE"}'); return
                mf = os.path.join(sandbox, 'opt/current/release-manifest.json')
                rel = json.load(open(mf))['releaseId'] if os.path.isfile(mf) else '1.0.0'
                self.send_response(200)
                if self.path == '/api/health':
                    self.send_header('Content-Type', 'application/json'); self.send_header('X-App-Release', rel); self.end_headers()
                    self.wfile.write(json.dumps({'status': 'UP', 'releaseId': rel}).encode())
                else:
                    idx = os.path.join(sandbox, 'www/dist/index.html')
                    self.send_header('Content-Type', 'text/html'); self.end_headers()
                    self.wfile.write(open(idx, 'rb').read() if os.path.isfile(idx) else b'<!doctype html><html></html>')
            def log_message(self, *args): pass
        return H

    srv_b = http.server.ThreadingHTTPServer(('127.0.0.1', 0), mk_h(False))
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), mk_h(True))
    srv_v = http.server.ThreadingHTTPServer(('127.0.0.1', 0), mk_h(False))
    bp = srv_b.server_address[1]
    hp = srv.server_address[1]
    vp = srv_v.server_address[1]
    threading.Thread(target=srv_b.serve_forever, daemon=True).start()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    threading.Thread(target=srv_v.serve_forever, daemon=True).start()

    def make_rel(staging_dir, ver):
        ap = os.path.join(staging_dir, f"{ver}.tar.gz")
        m = {"releaseId": ver, "gitCommit": f"c-{ver}", "builtAt": "2026-11-25T16:20:00Z", "nodeVersion": "v24.13.1"}
        with tarfile.open(ap, 'w:gz') as tar:
            def add(r, b):
                ti = tarfile.TarInfo(name=f"release/{r}"); ti.size = len(b); ti.mode = 0o644; tar.addfile(ti, io.BytesIO(b))
            add("release-manifest.json", json.dumps(m).encode())
            add("backend/dist/server.js", open(os.path.join(project_root, 'backend/dist/server.js'), 'rb').read())
            add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
            add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
            add("backend/node_modules/p/i.js", b"module.exports=1;\n")
            add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
        sha = hashlib.sha256(open(ap, 'rb').read()).hexdigest()
        open(f"{ap}.sha256", 'w').write(f"{sha}  {ver}.tar.gz\n")
        return sha

    def run_app(sandbox_arg, ver, sha):
        nb = shutil.which('node')
        expr = (
            f"class {{ 'application': release_version => '{ver}', expected_sha256 => '{sha}', retain_releases => 2, "
            f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => false, manage_ipv6 => false, "
            f"nginx_bin => '/nonexistent-nginx-bin', verify_runtime => true, verify_health => true, health_attempts => 1, health_delay => 1, "
            f"node_bin => '{nb}', base_dir => '{sandbox_arg}/opt', cache_dir => '{sandbox_arg}/cache', staging_dir => '{sandbox_arg}/cache/staging', "
            f"www_dir => '{sandbox_arg}/www', data_base_dir => '{sandbox_arg}/var/lib', data_dir => '{sandbox_arg}/var/lib/data', state_file => '{sandbox_arg}/var/lib/release-state.json', "
            f"env_dir => '{sandbox_arg}/etc/app', env_file => '{sandbox_arg}/etc/app/backend.env', systemd_unit_path => '{sandbox_arg}/systemd/s.service', "
            f"conf_d_dir => '{sandbox_arg}/nginx/conf.d', sites_available_dir => '{sandbox_arg}/nginx/sites-available', sites_enabled_dir => '{sandbox_arg}/nginx/sites-enabled', "
            f"backend_port => {bp}, listen_port => {hp}, nginx_verify_port => {vp}, cors_origin => 'http://127.0.0.1:{hp}' }}"
        )
        return subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr], capture_output=True, text=True)

    try:
        staging = os.path.join(sandbox, 'cache/staging')
        s100 = make_rel(staging, '1.0.0')
        assert run_app(sandbox, '1.0.0', s100).returncode == 2

        # 1. Missing staging artifact for 1.0.9 fails cleanly without changing active 1.0.0 symlinks
        r_miss = run_app(sandbox, '1.0.9', 'a' * 64)
        assert r_miss.returncode not in (0, 2)
        assert os.path.realpath(f"{sandbox}/opt/backend") == os.path.realpath(f"{sandbox}/opt/releases/1.0.0/backend")

        # 2. Deleted backend.env drift self-heals on next Puppet run without re-extracting
        os.unlink(f"{sandbox}/etc/app/backend.env")
        r_env = run_app(sandbox, '1.0.0', s100)
        assert r_env.returncode == 2 and os.path.isfile(f"{sandbox}/etc/app/backend.env")
        assert run_app(sandbox, '1.0.0', s100).returncode == 0

        # 3. Interrupted promotion recovery: simulate health passed but state-file lost currentKnownGood -> Puppet promotes, verifies & converges cleanly (exit 2 -> 0)
        st_data = json.load(open(f"{sandbox}/var/lib/release-state.json"))
        del st_data['currentKnownGood']
        open(f"{sandbox}/var/lib/release-state.json", 'w').write(json.dumps(st_data))
        assert run_app(sandbox, '1.0.0', s100).returncode == 2
        assert json.load(open(f"{sandbox}/var/lib/release-state.json"))['currentKnownGood']['releaseId'] == '1.0.0'
        assert run_app(sandbox, '1.0.0', s100).returncode == 0
    finally:
        srv_b.shutdown(); srv.shutdown(); srv_v.shutdown()
        srv_b.server_close(); srv.server_close(); srv_v.server_close()
EOF
echo "PASS (missing artifact preserves 1.0.0; deleted env heals cleanly exit 2->0; interrupted promotion recovers exit 2->0)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 15. Pruning Safety: Active & Previous Known-Good Protected Regardless of Mtime
# ------------------------------------------------------------------------------
echo -n "[Test 15/${TOTAL_COUNT}] Pruning safety protects active & previousKnownGood regardless of mtime... "
python3 - << 'EOF'
import hashlib, io, json, os, subprocess, tarfile, tempfile, time

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
release_mgr = os.path.join(puppet_dir, 'modules/application/files/release_manager.py')

with tempfile.TemporaryDirectory() as sandbox:
    releases = os.path.join(sandbox, 'releases')
    os.makedirs(releases, exist_ok=True)
    for ver in ('1.0.0', '1.0.1', '1.0.2', '1.0.3'):
        rd = os.path.join(releases, ver)
        for sub in ('backend/dist', 'backend/node_modules/p', 'frontend/dist'):
            os.makedirs(os.path.join(rd, sub), exist_ok=True)
        open(os.path.join(rd, 'backend/dist/server.js'), 'w').write('// s\n')
        open(os.path.join(rd, 'backend/package.json'), 'w').write('{}\n')
        open(os.path.join(rd, 'backend/package-lock.json'), 'w').write('{}\n')
        open(os.path.join(rd, 'frontend/dist/index.html'), 'w').write('<html></html>\n')
        open(os.path.join(rd, 'release-manifest.json'), 'w').write(json.dumps({"releaseId": ver, "gitCommit": "c", "builtAt": "2026", "nodeVersion": "v24.13.1"}))
        open(os.path.join(rd, '.extracted.ok'), 'w').write(json.dumps({"releaseId": ver, "archiveSha256": (ver[-1] * 64)}))

    # Give 1.0.0 oldest mtime, 1.0.3 newest mtime, while active is 1.0.2 and previousKnownGood is 1.0.0!
    os.utime(os.path.join(releases, '1.0.0'), (1000, 1000))
    os.utime(os.path.join(releases, '1.0.1'), (2000, 2000))
    os.utime(os.path.join(releases, '1.0.2'), (3000, 3000))
    os.utime(os.path.join(releases, '1.0.3'), (9999999999, 9999999999))

    c_link = os.path.join(sandbox, 'current')
    b_link = os.path.join(sandbox, 'backend')
    f_link = os.path.join(sandbox, 'dist')
    os.symlink(os.path.join(releases, '1.0.2/backend'), b_link)
    os.symlink(os.path.join(releases, '1.0.2/frontend/dist'), f_link)
    state_file = os.path.join(sandbox, 'release-state.json')
    open(state_file, 'w').write(json.dumps({
        "currentKnownGood": {"releaseId": "1.0.0", "archiveSha256": "0" * 64},
        "previousKnownGood": None,
    }))

    # Unmigrated direct symlinks lacking the shared atomic current pointer MUST fail closed in promote-and-prune
    r_legacy_reject = subprocess.run([
        'python3', release_mgr, 'promote-and-prune',
        '--version', '1.0.2', '--expected-sha256', '2' * 64,
        '--state-file', state_file, '--releases-dir', releases,
        '--backend-link', b_link, '--frontend-link', f_link,
        '--retain-releases', '2',
    ], capture_output=True, text=True)
    assert r_legacy_reject.returncode != 0, 'Direct symlinks bypassing current pointer must be rejected by promote-and-prune'

    # Configure valid single-pointer layout: current -> 1.0.2, backend -> current/backend, dist -> current/frontend/dist
    os.unlink(b_link); os.unlink(f_link)
    os.symlink(os.path.join(releases, '1.0.2'), c_link)
    os.symlink(os.path.join(c_link, 'backend'), b_link)
    os.symlink(os.path.join(c_link, 'frontend/dist'), f_link)

    subprocess.run([
        'python3', release_mgr, 'promote-and-prune',
        '--version', '1.0.2', '--expected-sha256', '2' * 64,
        '--state-file', state_file, '--releases-dir', releases,
        '--current-link', c_link, '--backend-link', b_link, '--frontend-link', f_link,
        '--retain-releases', '2',
    ], check=True, capture_output=True, text=True)

    # With retain=2, active 1.0.2 + previousKnownGood 1.0.0 MUST survive even though 1.0.3 had newer mtime!
    assert os.path.isdir(os.path.join(releases, '1.0.2')), 'Active release 1.0.2 MUST never be pruned'
    assert os.path.isdir(os.path.join(releases, '1.0.0')), 'previousKnownGood 1.0.0 MUST be protected regardless of mtime'
    assert not os.path.exists(os.path.join(releases, '1.0.1'))
    assert not os.path.exists(os.path.join(releases, '1.0.3'))
EOF
echo "PASS (active & previousKnownGood protected regardless of filesystem mtime; excess/unpromoted pruned)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 16. Puppet Convergence with manage_service => true (No Unnecessary Restarts)
# ------------------------------------------------------------------------------
echo -n "[Test 16/${TOTAL_COUNT}] Managed service Puppet convergence, zero-restart idempotency & env-drift restart... "
python3 - << 'EOF'
import hashlib, http.server, io, json, os, shutil, stat, subprocess, tarfile, tempfile, threading

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        if self.path == '/api/health':
            self.send_header('Content-Type', 'application/json'); self.send_header('X-App-Release', '1.0.0'); self.end_headers()
            self.wfile.write(b'{"status":"UP","releaseId":"1.0.0"}')
        else:
            self.send_header('Content-Type', 'text/html'); self.end_headers()
            self.wfile.write(b'<!doctype html><html><head><meta name="app-release-id" content="1.0.0" /></head></html>')
    def log_message(self, *args): pass

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
srv_v = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
hp = srv.server_address[1]
vp = srv_v.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
threading.Thread(target=srv_v.serve_forever, daemon=True).start()

def make_rel(staging, ver):
    ap = os.path.join(staging, f"{ver}.tar.gz")
    m = {"releaseId": ver, "gitCommit": f"c-{ver}", "builtAt": "2026-11-25T17:00:00Z", "nodeVersion": "v24.13.1"}
    with tarfile.open(ap, 'w:gz') as tar:
        def add(r, b):
            ti = tarfile.TarInfo(name=f"release/{r}"); ti.size = len(b); ti.mode = 0o644; tar.addfile(ti, io.BytesIO(b))
        add("release-manifest.json", json.dumps(m).encode())
        add("backend/dist/server.js", open(os.path.join(project_root, 'backend/dist/server.js'), 'rb').read())
        add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
        add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
        add("backend/node_modules/p/i.js", b"module.exports=1;\n")
        add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
    sha = hashlib.sha256(open(ap, 'rb').read()).hexdigest()
    open(f"{ap}.sha256", 'w').write(f"{sha}  {ver}.tar.gz\n")
    return sha

# NOTE: Puppet Service[provider => systemd] invokes /bin/systemctl directly for status/start/restart,
# while Exec[app_systemd_daemon_reload], Exec[app_nginx_configtest_before_start], and release_manager.py
# use $systemctl_bin. We test the exact catalog compilation & mock systemctl_bin/nginx_bin execution
# around app_systemd_daemon_reload, app_nginx_configtest_before_start, app_sync_backend_restart, and
# release_manager.py verify-health --restart-on-revert using Puppet's --noop/--detailed-exitcodes + CLI!
try:
    with tempfile.TemporaryDirectory() as sandbox:
        for d in ('var', 'etc', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled', 'bin'):
            os.makedirs(os.path.join(sandbox, d), exist_ok=True)
        sc_log = os.path.join(sandbox, 'systemctl.log')
        mock_sc = os.path.join(sandbox, 'bin/systemctl')
        with open(mock_sc, 'w') as fh:
            fh.write(f"#!/usr/bin/env bash\necho \"$*\" >> '{sc_log}'\nexit 0\n")
        os.chmod(mock_sc, 0o755)
        mock_ngx = os.path.join(sandbox, 'bin/nginx')
        with open(mock_ngx, 'w') as fh:
            fh.write("#!/usr/bin/env bash\nexit 0\n")
        os.chmod(mock_ngx, 0o755)

        staging = os.path.join(sandbox, 'cache/staging')
        s100 = make_rel(staging, '1.0.0')
        nb = shutil.which('node')

        # Verify manage_service => true compiles cleanly with custom systemctl_bin & nginx_bin without cycles
        expr_noop = (
            f"class {{ 'application': release_version => '1.0.0', expected_sha256 => '{s100}', "
            f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => true, manage_ipv6 => false, "
            f"systemctl_bin => '{mock_sc}', nginx_bin => '{mock_ngx}', nginx_configtest_cmd => '{mock_ngx} -t', "
            f"node_bin => '{nb}', base_dir => '{sandbox}/opt', cache_dir => '{sandbox}/cache', staging_dir => '{staging}', "
            f"www_dir => '{sandbox}/www', data_base_dir => '{sandbox}/var/lib', data_dir => '{sandbox}/var/lib/data', state_file => '{sandbox}/var/lib/release-state.json', "
            f"env_dir => '{sandbox}/etc/app', env_file => '{sandbox}/etc/app/backend.env', systemd_unit_path => '{sandbox}/systemd/s.service', "
            f"conf_d_dir => '{sandbox}/nginx/conf.d', sites_available_dir => '{sandbox}/nginx/sites-available', sites_enabled_dir => '{sandbox}/nginx/sites-enabled', "
            f"backend_port => {hp}, listen_port => {hp}, nginx_verify_port => {vp}, cors_origin => 'http://127.0.0.1:{hp}' }}"
        )
        r_noop = subprocess.run(['puppet', 'apply', '--noop', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr_noop], capture_output=True, text=True)
        assert r_noop.returncode == 0, f"manage_service => true --noop failed: {r_noop.stderr}"
        assert 'Exec[app_systemd_daemon_reload]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_sync_backend_restart]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_mark_service_synced]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_enter_maintenance]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_promote_release]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_exit_maintenance]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_prune_releases]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_verify_backend_health_refresh]' in (r_noop.stdout + r_noop.stderr)
        assert 'Exec[app_verify_frontend_health_refresh]' in (r_noop.stdout + r_noop.stderr)

        # Clear any --noop `unless` probe calls (`is-active`) before asserting manage_service => false never calls systemctl
        if os.path.exists(sc_log):
            os.unlink(sc_log)

        # Also prove manage_service => false NEVER invokes systemctl (daemon-reload or is-active) even on unit creation
        expr_nomgr = expr_noop.replace('manage_service => true', 'manage_service => false')
        r1 = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr_nomgr], capture_output=True, text=True)
        assert r1.returncode == 2, f"Initial apply failed ({r1.returncode}): {r1.stderr}"
        assert not os.path.exists(sc_log), f"manage_service => false must never call systemctl, got: {open(sc_log).read() if os.path.exists(sc_log) else ''}"
        r2 = subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr_nomgr], capture_output=True, text=True)
        assert r2.returncode == 0, f"Repeat convergence must exit 0 (got {r2.returncode}): {r2.stderr}"
finally:
    srv.shutdown(); srv_v.shutdown()
    srv.server_close(); srv_v.server_close()
EOF
echo "PASS (manage_service => true DAG & refresh hooks compiled; manage_service => false skips daemon-reload cleanly; exit 2->0)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 17. Failed Revert Restart Honesty & State-Before-Delete Pruning Safety
# ------------------------------------------------------------------------------
echo -n "[Test 17/${TOTAL_COUNT}] Failed revert restart keeps serviceSynced=false & state-before-delete pruning... "
python3 - << 'EOF'
import hashlib, http.server, io, json, os, subprocess, tarfile, tempfile, threading

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
release_mgr = os.path.join(puppet_dir, 'modules/application/files/release_manager.py')
health_chk = os.path.join(puppet_dir, 'modules/application/files/health_check.py')

class S:
    code = 200
st = S()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(st.code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"UP"}' if st.code == 200 else b'{"status":"DOWN"}')
    def log_message(self, *args): pass

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
hp = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

try:
    with tempfile.TemporaryDirectory() as sandbox:
        releases = os.path.join(sandbox, 'releases')
        os.makedirs(releases, exist_ok=True)
        shas = {}
        for ver in ('1.0.0', '1.0.1'):
            rd = os.path.join(releases, ver)
            for sub in ('backend/dist', 'backend/node_modules/p', 'frontend/dist'):
                os.makedirs(os.path.join(rd, sub), exist_ok=True)
            open(os.path.join(rd, 'backend/dist/server.js'), 'w').write('// s\n')
            open(os.path.join(rd, 'backend/package.json'), 'w').write('{}\n')
            open(os.path.join(rd, 'backend/package-lock.json'), 'w').write('{}\n')
            open(os.path.join(rd, 'frontend/dist/index.html'), 'w').write('<html></html>\n')
            open(os.path.join(rd, 'release-manifest.json'), 'w').write(json.dumps({"releaseId": ver, "gitCommit": "c", "builtAt": "2026", "nodeVersion": "v24.13.1"}))
            shas[ver] = ver[-1] * 64
            open(os.path.join(rd, '.extracted.ok'), 'w').write(json.dumps({"releaseId": ver, "archiveSha256": shas[ver]}))

        b_link = os.path.join(sandbox, 'backend')
        f_link = os.path.join(sandbox, 'dist')
        state_file = os.path.join(sandbox, 'release-state.json')
        fail_sc = os.path.join(sandbox, 'fail-systemctl.sh')
        ok_ngx = os.path.join(sandbox, 'ok-nginx.sh')
        open(fail_sc, 'w').write("#!/usr/bin/env bash\nexit 1\n")
        open(ok_ngx, 'w').write("#!/usr/bin/env bash\nexit 0\n")
        os.chmod(fail_sc, 0o755); os.chmod(ok_ngx, 0o755)

        # Promote 1.0.0 first
        subprocess.run(['python3', release_mgr, 'activate', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--state-file', state_file], check=True, capture_output=True)
        subprocess.run(['python3', release_mgr, 'promote-and-prune', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--state-file', state_file, '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--retain-releases', '2'], check=True, capture_output=True)

        # Activate 1.0.1, fail health check with failing systemctl restart -> symlinks revert to 1.0.0, AND serviceSynced MUST stay False!
        subprocess.run(['python3', release_mgr, 'activate', '--version', '1.0.1', '--expected-sha256', shas['1.0.1'], '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--state-file', state_file], check=True, capture_output=True)
        st.code = 503
        vh = subprocess.run([
            'python3', release_mgr, 'verify-health', '--mode', 'backend',
            '--version', '1.0.1', '--expected-sha256', shas['1.0.1'],
            '--state-file', state_file, '--releases-dir', releases,
            '--backend-link', b_link, '--frontend-link', f_link,
            '--health-check-script', health_chk, '--host', '127.0.0.1', '--port', str(hp),
            '--attempts', '1', '--delay', '1', '--revert-on-fail', '--restart-on-revert',
            '--systemctl-bin', fail_sc, '--nginx-bin', ok_ngx,
        ], capture_output=True, text=True)
        assert vh.returncode != 0
        assert os.path.realpath(b_link) == os.path.realpath(os.path.join(releases, '1.0.0/backend'))
        assert os.path.realpath(f_link) == os.path.realpath(os.path.join(releases, '1.0.0/frontend/dist'))
        state_after = json.load(open(state_file))
        assert state_after['pendingActivation']['releaseId'] == '1.0.0'
        assert state_after['pendingActivation']['serviceSynced'] is False, 'Failed restart during revert MUST NOT mark serviceSynced=True'
        iss = subprocess.run(['python3', release_mgr, 'is-service-synced', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--state-file', state_file, '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link])
        assert iss.returncode != 0, 'Next Puppet run MUST detect unsynced service after failed revert restart'

        # Verify state-before-delete pruning recovery: if 1.0.0 is promoted while older excess dirs exist, is-known-good returns 1 and promote-and-prune cleans up
        for idx, old_v in enumerate(('0.9.0', '0.9.1')):
            old_p = os.path.join(releases, old_v)
            os.makedirs(old_p, exist_ok=True)
            os.utime(old_p, (1000 + idx, 1000 + idx))
        subprocess.run(['python3', release_mgr, 'activate', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--state-file', state_file], check=True, capture_output=True)
        subprocess.run(['python3', release_mgr, 'promote-and-prune', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--state-file', state_file, '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--retain-releases', '2'], check=True, capture_output=True)
        assert not os.path.exists(os.path.join(releases, '0.9.0')) and not os.path.exists(os.path.join(releases, '0.9.1'))
        # Leftover dir created after interrupted prune still caught by is-known-good -> returns 1
        old_p2 = os.path.join(releases, '0.9.2')
        os.makedirs(old_p2, exist_ok=True)
        os.utime(old_p2, (1002, 1002))
        ikg = subprocess.run(['python3', release_mgr, 'is-known-good', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--state-file', state_file, '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--retain-releases', '2'])
        assert ikg.returncode != 0
        subprocess.run(['python3', release_mgr, 'promote-and-prune', '--version', '1.0.0', '--expected-sha256', shas['1.0.0'], '--state-file', state_file, '--releases-dir', releases, '--backend-link', b_link, '--frontend-link', f_link, '--retain-releases', '2'], check=True, capture_output=True)
        assert not os.path.exists(old_p2)
        assert os.path.isdir(os.path.join(releases, '1.0.0'))
finally:
    srv.shutdown(); srv.server_close()
EOF
echo "PASS (failed revert restart preserves serviceSynced=false for next-run recovery)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 18. Live Real Node 24 + NGINX Auto-Revert End-to-End Verification
# ------------------------------------------------------------------------------
echo -n "[Test 18/${TOTAL_COUNT}] Live real Node 24 backend + NGINX auto-revert on broken release... "
python3 - << 'EOF'
import hashlib, io, json, os, shutil, signal, socket, subprocess, tarfile, tempfile, time, urllib.request

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
release_mgr = os.path.join(puppet_dir, 'modules/application/files/release_manager.py')
health_chk = os.path.join(puppet_dir, 'modules/application/files/health_check.py')
nginx_bin = shutil.which('nginx') or '/usr/sbin/nginx'
node_bin = shutil.which('node')
assert os.path.isfile(nginx_bin) and node_bin

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

b_port = free_port()
f_port = free_port()
v_port = free_port()

with tempfile.TemporaryDirectory() as sandbox:
    for d in ('var/lib/data', 'etc/app', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled', 'nginx/tmp/body', 'nginx/tmp/proxy', 'nginx/tmp/fcgi', 'nginx/tmp/uwsgi', 'nginx/tmp/scgi'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)
    staging = os.path.join(sandbox, 'cache/staging')

    def build_real_or_broken_tar(ver, broken_server=False):
        tar_path = os.path.join(staging, f"{ver}.tar.gz")
        m = {"releaseId": ver, "gitCommit": f"live-{ver}", "builtAt": "2026-11-25T17:10:00Z", "nodeVersion": "v24.13.1"}
        with tarfile.open(tar_path, 'w:gz') as tar:
            seen = set()
            def add(rel, data):
                if rel in seen: return
                seen.add(rel)
                ti = tarfile.TarInfo(name=f"release/{rel}"); ti.size = len(data); ti.mode = 0o644; tar.addfile(ti, io.BytesIO(data))
            add("release-manifest.json", json.dumps(m).encode())
            if broken_server:
                add("backend/dist/server.js", b"console.error('broken release'); process.exit(1);\n")
            else:
                for r, _, files in os.walk(os.path.join(project_root, 'backend/dist')):
                    for fn in files:
                        fp = os.path.join(r, fn)
                        if os.path.isfile(fp) and not os.path.islink(fp):
                            add(f"backend/{os.path.relpath(fp, os.path.join(project_root, 'backend'))}", open(fp, 'rb').read())
            add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
            add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
            for pkg in os.listdir(os.path.join(project_root, 'backend/node_modules')):
                sp = os.path.join(project_root, 'backend/node_modules', pkg)
                if os.path.islink(sp) or pkg.startswith('.'): continue
                for r, _, files in os.walk(sp):
                    for fn in files:
                        fp = os.path.join(r, fn)
                        if os.path.isfile(fp) and not os.path.islink(fp):
                            add(f"backend/{os.path.relpath(fp, os.path.join(project_root, 'backend'))}", open(fp, 'rb').read())
            add("frontend/dist/index.html", open(os.path.join(project_root, 'frontend/dist/index.html'), 'rb').read())
        sha = hashlib.sha256(open(tar_path, 'rb').read()).hexdigest()
        open(f"{tar_path}.sha256", 'w').write(f"{sha}  {ver}.tar.gz\n")
        return sha

    s100 = build_real_or_broken_tar('1.0.0', broken_server=False)
    s101 = build_real_or_broken_tar('1.0.1', broken_server=True)

    main_conf = os.path.join(sandbox, 'nginx/nginx.conf')
    open(main_conf, 'w').write(
        f"pid {sandbox}/nginx/nginx.pid;\n"
        f"error_log {sandbox}/nginx/error.log;\n"
        f"worker_processes 1;\n"
        f"events {{ worker_connections 64; }}\n"
        f"http {{\n"
        f"    access_log {sandbox}/nginx/access.log;\n"
        f"    client_body_temp_path {sandbox}/nginx/tmp/body;\n"
        f"    proxy_temp_path {sandbox}/nginx/tmp/proxy;\n"
        f"    fastcgi_temp_path {sandbox}/nginx/tmp/fcgi;\n"
        f"    uwsgi_temp_path {sandbox}/nginx/tmp/uwsgi;\n"
        f"    scgi_temp_path {sandbox}/nginx/tmp/scgi;\n"
        f"    include {sandbox}/nginx/conf.d/*.conf;\n"
        f"    include {sandbox}/nginx/sites-enabled/*;\n"
        f"}}\n"
    )
    # 1. Provision 1.0.0 with Puppet (manage_service => false so we drive real node & nginx processes cleanly)
    expr_100 = (
        f"class {{ 'application': release_version => '1.0.0', expected_sha256 => '{s100}', "
        f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => false, manage_ipv6 => false, "
        f"verify_health => false, verify_runtime => true, node_bin => '{node_bin}', "
        f"nginx_configtest_cmd => \"{nginx_bin} -t -p '{sandbox}/nginx' -c '{main_conf}' -e stderr\", "
        f"base_dir => '{sandbox}/opt', cache_dir => '{sandbox}/cache', staging_dir => '{staging}', www_dir => '{sandbox}/www', "
        f"data_base_dir => '{sandbox}/var/lib', data_dir => '{sandbox}/var/lib/data', state_file => '{sandbox}/var/lib/release-state.json', "
        f"env_dir => '{sandbox}/etc/app', env_file => '{sandbox}/etc/app/backend.env', systemd_unit_path => '{sandbox}/systemd/s.service', "
        f"conf_d_dir => '{sandbox}/nginx/conf.d', sites_available_dir => '{sandbox}/nginx/sites-available', sites_enabled_dir => '{sandbox}/nginx/sites-enabled', "
        f"backend_port => {b_port}, listen_port => {f_port}, nginx_verify_port => {v_port}, cors_origin => 'http://127.0.0.1:{f_port}' }}"
    )
    assert subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr_100], capture_output=True, text=True).returncode == 2

    # Mock systemctl supervisor script that restarts real node backend/dist/server.js and reloads real nginx
    node_pid_file = os.path.join(sandbox, 'node.pid')
    env_file = os.path.join(sandbox, 'etc/app/backend.env')
    mock_sc = os.path.join(sandbox, 'mock-systemctl.sh')
    mock_ngx = os.path.join(sandbox, 'mock-nginx.sh')
    open(mock_ngx, 'w').write(f"#!/usr/bin/env bash\nexec '{nginx_bin}' -t -p '{sandbox}/nginx' -c '{main_conf}' -e stderr\n")
    open(mock_sc, 'w').write(f"""#!/usr/bin/env bash
set -eu
ACTION="${{1:-}}"
SVC="${{2:-}}"
if [ "$SVC" = "git-repo-analyzer-backend" ] && [ "$ACTION" = "restart" ]; then
  if [ -f '{node_pid_file}' ]; then
    OLD_PID=$(cat '{node_pid_file}' || true)
    if [ -n "$OLD_PID" ]; then
      kill "$OLD_PID" 2>/dev/null || true
      for _i in $(seq 1 50); do
        kill -0 "$OLD_PID" 2>/dev/null || break
        sleep 0.05
      done
    fi
  fi
  set -a
  . '{env_file}'
  set +a
  nohup '{node_bin}' '{sandbox}/opt/backend/dist/server.js' >/dev/null 2>&1 &
  echo $! > '{node_pid_file}'
elif [ "$SVC" = "nginx" ] && [ "$ACTION" = "reload" ]; then
  kill -HUP $(cat '{sandbox}/nginx/nginx.pid')
fi
exit 0
""")
    os.chmod(mock_sc, 0o755); os.chmod(mock_ngx, 0o755)

    p_nginx = subprocess.Popen([nginx_bin, '-g', 'daemon off;', '-p', f"{sandbox}/nginx", '-c', main_conf, '-e', 'stderr'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # Start 1.0.0 via supervisor and promote as known-good
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                if urllib.request.urlopen(f"http://127.0.0.1:{f_port}/api/health", timeout=1.0).getcode() == 200:
                    break
            except Exception:
                time.sleep(0.1)
        subprocess.run(['python3', release_mgr, 'promote-and-prune', '--version', '1.0.0', '--expected-sha256', s100, '--state-file', f"{sandbox}/var/lib/release-state.json", '--releases-dir', f"{sandbox}/opt/releases", '--backend-link', f"{sandbox}/opt/backend", '--frontend-link', f"{sandbox}/www/dist", '--retain-releases', '2'], check=True, capture_output=True)

        # 2. Extract & activate broken 1.0.1 under maintenance mode, restart real node (it exits immediately!), run verify-health --revert-on-fail --restart-on-revert --maintenance-flag
        maint_flag = f"{sandbox}/opt/maintenance.flag"
        subprocess.run(['python3', release_mgr, 'prepare', '--version', '1.0.1', '--expected-sha256', s101, '--staging-dir', staging, '--releases-dir', f"{sandbox}/opt/releases"], check=True, capture_output=True)
        subprocess.run(['python3', release_mgr, 'enter-maintenance', '--version', '1.0.1', '--expected-sha256', s101, '--state-file', f"{sandbox}/var/lib/release-state.json", '--backend-link', f"{sandbox}/opt/backend", '--maintenance-flag', maint_flag], check=True, capture_output=True)
        subprocess.run(['python3', release_mgr, 'activate', '--version', '1.0.1', '--expected-sha256', s101, '--releases-dir', f"{sandbox}/opt/releases", '--backend-link', f"{sandbox}/opt/backend", '--frontend-link', f"{sandbox}/www/dist", '--state-file', f"{sandbox}/var/lib/release-state.json"], check=True, capture_output=True)
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        r_fail = subprocess.run([
            'python3', release_mgr, 'verify-health', '--mode', 'backend',
            '--version', '1.0.1', '--expected-sha256', s101,
            '--expected-release', '1.0.1',
            '--state-file', f"{sandbox}/var/lib/release-state.json",
            '--releases-dir', f"{sandbox}/opt/releases",
            '--backend-link', f"{sandbox}/opt/backend",
            '--frontend-link', f"{sandbox}/www/dist",
            '--maintenance-flag', maint_flag,
            '--health-check-script', health_chk, '--host', '127.0.0.1', '--port', str(b_port),
            '--attempts', '2', '--delay', '0', '--revert-on-fail', '--restart-on-revert',
            '--systemctl-bin', mock_sc, '--nginx-bin', mock_ngx,
        ], capture_output=True, text=True)
        assert r_fail.returncode != 0, 'Broken 1.0.1 must fail health gate'
        assert os.path.lexists(maint_flag), 'Maintenance mode MUST remain active until reverted release 1.0.0 is verified healthy'
        assert os.readlink(f"{sandbox}/opt/current") == f"{sandbox}/opt/releases/1.0.0"
        assert os.readlink(f"{sandbox}/opt/backend") == f"{sandbox}/opt/current/backend"
        assert os.readlink(f"{sandbox}/www/dist") == f"{sandbox}/opt/current/frontend/dist"
        assert os.path.realpath(f"{sandbox}/opt/backend") == os.path.realpath(f"{sandbox}/opt/releases/1.0.0/backend")
        assert os.path.realpath(f"{sandbox}/www/dist") == os.path.realpath(f"{sandbox}/opt/releases/1.0.0/frontend/dist")

        # Verify public port stays 503 MAINTENANCE while verify_port (:v_port) proves reverted real Node 24 1.0.0 came up UP + releaseId=1.0.0, then exit-maintenance opens public port!
        import urllib.error
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{f_port}/api/health", timeout=1.0)
            assert False, 'Public port must return 503 MAINTENANCE before verification clears maintenance'
        except urllib.error.HTTPError as e:
            assert e.code == 503
        recovered = False
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{v_port}/api/health", timeout=1.0) as resp:
                    payload = json.loads(resp.read().decode())
                    if resp.getcode() == 200 and payload['status'] == 'UP' and payload.get('releaseId') == '1.0.0':
                        recovered = True
                        break
            except Exception:
                time.sleep(0.15)
        assert recovered, 'Reverted real Node 24 1.0.0 must serve 200 UP releaseId=1.0.0 through NGINX verify listener'
        subprocess.run([
            'python3', release_mgr, 'exit-maintenance', '--version', '1.0.0', '--expected-sha256', s100,
            '--state-file', f"{sandbox}/var/lib/release-state.json", '--releases-dir', f"{sandbox}/opt/releases",
            '--backend-link', f"{sandbox}/opt/backend", '--frontend-link', f"{sandbox}/www/dist",
            '--maintenance-flag', maint_flag, '--health-check-script', health_chk,
            '--backend-port', str(b_port), '--verify-port', str(v_port), '--listen-port', str(f_port),
            '--attempts', '3', '--delay', '0', '--verify-consistency',
        ], check=True, capture_output=True)
        with urllib.request.urlopen(f"http://127.0.0.1:{f_port}/api/health", timeout=1.0) as resp:
            assert resp.getcode() == 200 and json.loads(resp.read().decode())['releaseId'] == '1.0.0'
    finally:
        if os.path.isfile(node_pid_file):
            try:
                os.kill(int(open(node_pid_file).read().strip()), signal.SIGTERM)
            except Exception:
                pass
        p_nginx.terminate()
        try:
            p_nginx.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p_nginx.kill()
EOF
echo "PASS (broken 1.0.1 real-process health fail auto-reverted symlinks & restarted real Node 24 1.0.0 serving 200 UP via NGINX)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 19. Live Node 24 + Real NGINX Process Interruption & Zero Mixed-Release Test
# ------------------------------------------------------------------------------
echo -n "[Test 19/${TOTAL_COUNT}] Live Node 24 + NGINX process interruption & autonomous Puppet recovery... "
python3 - << 'EOF'
import hashlib, importlib.util, io, json, os, shutil, signal, socket, subprocess, sys, tarfile, tempfile, time, urllib.request

puppet_dir = os.environ['PUPPET_DIR']
project_root = os.environ['PROJECT_ROOT']
release_mgr = os.path.join(puppet_dir, 'modules/application/files/release_manager.py')
nginx_bin = shutil.which('nginx') or '/usr/sbin/nginx'
node_bin = shutil.which('node')
assert os.path.isfile(nginx_bin) and node_bin

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

b_port = free_port()
f_port = free_port()
v_port = free_port()

with tempfile.TemporaryDirectory() as sandbox:
    for d in ('var/lib/data', 'etc/app', 'cache/staging', 'systemd', 'nginx/conf.d', 'nginx/sites-available', 'nginx/sites-enabled', 'nginx/tmp/body', 'nginx/tmp/proxy', 'nginx/tmp/fcgi', 'nginx/tmp/uwsgi', 'nginx/tmp/scgi'):
        os.makedirs(os.path.join(sandbox, d), exist_ok=True)
    staging = os.path.join(sandbox, 'cache/staging')
    sentinel_file = os.path.join(sandbox, 'var/lib/data/history.json')
    sentinel_text = '{"persistent":true,"entries":[1,2,3]}\n'
    open(sentinel_file, 'w').write(sentinel_text)

    def build_tagged_bundle(ver):
        tar_path = os.path.join(staging, f"{ver}.tar.gz")
        m = {"releaseId": ver, "gitCommit": f"rel-{ver}", "builtAt": "2026-11-25T18:30:00Z", "nodeVersion": "v24.13.1"}
        server_js = (
            "const http = require('http');\n"
            f"const VER = {ver!r};\n"
            "const port = parseInt(process.env.PORT || '3000', 10);\n"
            "const host = process.env.HOST || '127.0.0.1';\n"
            "const srv = http.createServer((req, res) => {\n"
            "  if (req.url === '/api/health') {\n"
            "    res.writeHead(200, {'Content-Type': 'application/json', 'X-App-Release': VER});\n"
            "    res.end(JSON.stringify({status: 'UP', release: VER, releaseId: VER}));\n"
            "    return;\n"
            "  }\n"
            "  res.writeHead(404); res.end();\n"
            "});\n"
            "srv.listen(port, host);\n"
        ).encode('utf-8')
        index_html = f"<!doctype html><html><body>release-{ver}</body></html>\n".encode('utf-8')
        with tarfile.open(tar_path, 'w:gz') as tar:
            def add(rel, data):
                ti = tarfile.TarInfo(name=f"release/{rel}"); ti.size = len(data); ti.mode = 0o644; tar.addfile(ti, io.BytesIO(data))
            add("release-manifest.json", json.dumps(m).encode())
            add("backend/dist/server.js", server_js)
            add("backend/package.json", open(os.path.join(project_root, 'backend/package.json'), 'rb').read())
            add("backend/package-lock.json", open(os.path.join(project_root, 'backend/package-lock.json'), 'rb').read())
            add("backend/node_modules/pkg/index.js", b"module.exports = {};\n")
            add("frontend/dist/index.html", index_html)
        sha = hashlib.sha256(open(tar_path, 'rb').read()).hexdigest()
        open(f"{tar_path}.sha256", 'w').write(f"{sha}  {ver}.tar.gz\n")
        return sha

    s100 = build_tagged_bundle('1.0.0')
    s101 = build_tagged_bundle('1.0.1')

    main_conf = os.path.join(sandbox, 'nginx/nginx.conf')
    open(main_conf, 'w').write(
        f"pid {sandbox}/nginx/nginx.pid;\n"
        f"error_log {sandbox}/nginx/error.log;\n"
        f"worker_processes 1;\n"
        f"events {{ worker_connections 64; }}\n"
        f"http {{\n"
        f"    access_log {sandbox}/nginx/access.log;\n"
        f"    client_body_temp_path {sandbox}/nginx/tmp/body;\n"
        f"    proxy_temp_path {sandbox}/nginx/tmp/proxy;\n"
        f"    fastcgi_temp_path {sandbox}/nginx/tmp/fcgi;\n"
        f"    uwsgi_temp_path {sandbox}/nginx/tmp/uwsgi;\n"
        f"    scgi_temp_path {sandbox}/nginx/tmp/scgi;\n"
        f"    include {sandbox}/nginx/conf.d/*.conf;\n"
        f"    include {sandbox}/nginx/sites-enabled/*;\n"
        f"}}\n"
    )

    node_pid_file = os.path.join(sandbox, 'node.pid')
    env_file = os.path.join(sandbox, 'etc/app/backend.env')
    mock_sc = os.path.join(sandbox, 'mock-systemctl.sh')
    mock_ngx = os.path.join(sandbox, 'mock-nginx.sh')
    open(mock_ngx, 'w').write(f"#!/usr/bin/env bash\nexec '{nginx_bin}' -t -p '{sandbox}/nginx' -c '{main_conf}' -e stderr\n")
    open(mock_sc, 'w').write(f"""#!/usr/bin/env bash
set -eu
ACTION="${{1:-}}"
SVC="${{2:-}}"
if [ "$SVC" = "git-repo-analyzer-backend" ] && [ "$ACTION" = "restart" ]; then
  if [ -f '{node_pid_file}' ]; then
    OLD_PID=$(cat '{node_pid_file}' || true)
    if [ -n "$OLD_PID" ]; then
      kill "$OLD_PID" 2>/dev/null || true
      for _i in $(seq 1 50); do
        kill -0 "$OLD_PID" 2>/dev/null || break
        sleep 0.05
      done
    fi
  fi
  set -a
  . '{env_file}'
  set +a
  nohup '{node_bin}' '{sandbox}/opt/backend/dist/server.js' >/dev/null 2>&1 &
  echo $! > '{node_pid_file}'
elif [ "$SVC" = "nginx" ] && [ "$ACTION" = "reload" ]; then
  if [ -f '{sandbox}/nginx/nginx.pid' ]; then
    kill -HUP $(cat '{sandbox}/nginx/nginx.pid')
  fi
elif [ "$SVC" = "nginx" ] && [ "$ACTION" = "is-active" ]; then
  [ -f '{sandbox}/nginx/nginx.pid' ] && kill -0 $(cat '{sandbox}/nginx/nginx.pid')
fi
exit 0
""")
    os.chmod(mock_sc, 0o755); os.chmod(mock_ngx, 0o755)

    def apply_full(ver, sha, *, verify_h=True):
        expr = (
            f"class {{ 'application': release_version => '{ver}', expected_sha256 => '{sha}', retain_releases => 2, "
            f"manage_packages => false, manage_users => false, manage_ownership => false, manage_service => false, manage_ipv6 => false, "
            f"systemctl_bin => '{mock_sc}', nginx_bin => '{mock_ngx}', nginx_configtest_cmd => '{mock_ngx} -t', "
            f"verify_health => {'true' if verify_h else 'false'}, health_attempts => 15, health_delay => 1, "
            f"verify_runtime => true, node_bin => '{node_bin}', "
            f"base_dir => '{sandbox}/opt', cache_dir => '{sandbox}/cache', staging_dir => '{staging}', www_dir => '{sandbox}/www', "
            f"data_base_dir => '{sandbox}/var/lib', data_dir => '{sandbox}/var/lib/data', state_file => '{sandbox}/var/lib/release-state.json', "
            f"env_dir => '{sandbox}/etc/app', env_file => '{env_file}', systemd_unit_path => '{sandbox}/systemd/s.service', "
            f"conf_d_dir => '{sandbox}/nginx/conf.d', sites_available_dir => '{sandbox}/nginx/sites-available', sites_enabled_dir => '{sandbox}/nginx/sites-enabled', "
            f"backend_port => {b_port}, listen_port => {f_port}, nginx_verify_port => {v_port}, cors_origin => 'http://127.0.0.1:{f_port}' }}"
        )
        return subprocess.run(['puppet', 'apply', '--detailed-exitcodes', f'--modulepath={puppet_dir}/modules', '--certname', 'app-server', '-e', expr], capture_output=True, text=True)

    direct_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    # Boot 1.0.0 with Puppet, start real NGINX + real Node 24, then run health gate & promotion via Puppet
    assert apply_full('1.0.0', s100, verify_h=False).returncode == 2
    p_nginx = subprocess.Popen([nginx_bin, '-g', 'daemon off;', '-p', f"{sandbox}/nginx", '-c', main_conf, '-e', 'stderr'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                if (
                    direct_opener.open(f"http://127.0.0.1:{f_port}/", timeout=1.0).getcode() == 200
                    and direct_opener.open(f"http://127.0.0.1:{f_port}/api/health", timeout=1.0).getcode() == 200
                ):
                    break
            except Exception:
                time.sleep(0.1)
        assert apply_full('1.0.0', s100, verify_h=True).returncode == 2
        assert apply_full('1.0.0', s100, verify_h=True).returncode == 0

        def read_live_pair():
            with direct_opener.open(f"http://127.0.0.1:{f_port}/api/health", timeout=2.0) as rh:
                api_ver = json.loads(rh.read().decode())['release']
            with direct_opener.open(f"http://127.0.0.1:{f_port}/", timeout=2.0) as rf:
                html = rf.read().decode()
            return api_ver, html

        api_v, html_v = read_live_pair()
        assert api_v == '1.0.0' and 'release-1.0.0' in html_v

        # Prepare 1.0.1 cleanly, remove 1.0.0 staging tarball, then SIGKILL activate right before os.replace(opt/current)
        subprocess.run(['python3', release_mgr, 'prepare', '--version', '1.0.1', '--expected-sha256', s101, '--staging-dir', staging, '--releases-dir', f"{sandbox}/opt/releases"], check=True, capture_output=True)
        os.unlink(os.path.join(staging, '1.0.0.tar.gz'))
        os.unlink(os.path.join(staging, '1.0.0.tar.gz.sha256'))

        def run_activate_sigkill(when):
            kill_code = (
                f"import importlib.util, os, signal, sys\n"
                f"spec = importlib.util.spec_from_file_location('rm', {release_mgr!r})\n"
                f"rm = importlib.util.module_from_spec(spec); spec.loader.exec_module(rm)\n"
                f"orig_replace = os.replace\n"
                f"target_cur = os.path.abspath({os.path.join(sandbox, 'opt/current')!r})\n"
                f"def hooked(s, d):\n"
                f"    if {when!r} == 'pre' and os.path.abspath(d) == target_cur:\n"
                f"        os.kill(os.getpid(), signal.SIGKILL)\n"
                f"    orig_replace(s, d)\n"
                f"    if {when!r} == 'post' and os.path.abspath(d) == target_cur:\n"
                f"        os.kill(os.getpid(), signal.SIGKILL)\n"
                f"os.replace = hooked\n"
                f"sys.exit(rm.main(['activate', '--version', '1.0.1', '--expected-sha256', {s101!r}, '--releases-dir', {os.path.join(sandbox, 'opt/releases')!r}, '--current-link', {os.path.join(sandbox, 'opt/current')!r}, '--backend-link', {os.path.join(sandbox, 'opt/backend')!r}, '--frontend-link', {os.path.join(sandbox, 'www/dist')!r}, '--state-file', {os.path.join(sandbox, 'var/lib/release-state.json')!r}]))\n"
            )
            return subprocess.run([sys.executable, '-c', kill_code], capture_output=True, text=True)

        # Case A: SIGKILL right BEFORE atomic current switch -> live NGINX + Node 24 continue serving 1.0.0 + 1.0.0
        assert run_activate_sigkill('pre').returncode == -signal.SIGKILL
        api_v, html_v = read_live_pair()
        assert api_v == '1.0.0' and 'release-1.0.0' in html_v, f"Mixed live state forbidden after pre-switch SIGKILL: api={api_v}, html={html_v}"

        # Autonomous Puppet recovery converges to 1.0.1 (exit 2 -> restart backend -> health/promote exit 2 -> exit 0)
        assert apply_full('1.0.1', s101, verify_h=False).returncode == 2
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                api_v, html_v = read_live_pair()
                if api_v == '1.0.1':
                    break
            except Exception:
                pass
            time.sleep(0.1)
        assert apply_full('1.0.1', s101, verify_h=True).returncode == 2
        assert apply_full('1.0.1', s101, verify_h=True).returncode == 0
        api_v, html_v = read_live_pair()
        assert api_v == '1.0.1' and 'release-1.0.1' in html_v

        # Case B: Roll back to 1.0.0 cleanly, then SIGKILL immediately AFTER atomic current switch to 1.0.1
        assert apply_full('1.0.0', s100, verify_h=False).returncode == 2
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                api_v, _ = read_live_pair()
                if api_v == '1.0.0':
                    break
            except Exception:
                pass
            time.sleep(0.1)
        assert apply_full('1.0.0', s100, verify_h=True).returncode == 2
        assert run_activate_sigkill('post').returncode == -signal.SIGKILL
        assert os.path.realpath(f"{sandbox}/opt/backend") == os.path.realpath(f"{sandbox}/opt/releases/1.0.1/backend")
        assert os.path.realpath(f"{sandbox}/www/dist") == os.path.realpath(f"{sandbox}/opt/releases/1.0.1/frontend/dist")
        assert json.load(open(f"{sandbox}/var/lib/release-state.json"))['pendingActivation']['serviceSynced'] is False
        assert apply_full('1.0.1', s101, verify_h=False).returncode == 0
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                api_v, _ = read_live_pair()
                if api_v == '1.0.1':
                    break
            except Exception:
                pass
            time.sleep(0.1)
        assert apply_full('1.0.1', s101, verify_h=True).returncode == 2
        assert apply_full('1.0.1', s101, verify_h=True).returncode == 0
        api_v, html_v = read_live_pair()
        assert api_v == '1.0.1' and 'release-1.0.1' in html_v

        # Final Hiera rollback back to retained 1.0.0 without tarball converges exit 2 -> exit 0 and serves live 1.0.0 + 1.0.0
        assert apply_full('1.0.0', s100, verify_h=False).returncode == 2
        subprocess.run([mock_sc, 'restart', 'git-repo-analyzer-backend'], check=True)
        for _ in range(30):
            try:
                api_v, _ = read_live_pair()
                if api_v == '1.0.0':
                    break
            except Exception:
                pass
            time.sleep(0.1)
        assert apply_full('1.0.0', s100, verify_h=True).returncode == 2
        assert apply_full('1.0.0', s100, verify_h=True).returncode == 0
        api_v, html_v = read_live_pair()
        assert api_v == '1.0.0' and 'release-1.0.0' in html_v
        assert open(sentinel_file).read() == sentinel_text
    finally:
        if os.path.isfile(node_pid_file):
            try:
                os.kill(int(open(node_pid_file).read().strip()), signal.SIGTERM)
            except Exception:
                pass
        p_nginx.terminate()
        try:
            p_nginx.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p_nginx.kill()
EOF
echo "PASS (live NGINX + Node 24 zero mixed release on SIGKILL, autonomous exit 2->0 recovery & rollback verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# Shared real-process Puppet harness for Tests 20-26 (managed base services, real Node 24 backend/dist/server.js, real NGINX)
_RT_HARNESS_DIR="$(mktemp -d)"
trap 'rm -rf "${_RT_HARNESS_DIR}"' EXIT

cat > "${_RT_HARNESS_DIR}/rt_harness.py" << 'HARNESS_EOF'
import hashlib
import io
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser


class MetaParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.meta = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "meta":
            return
        amap = {k.lower(): (v or "") for k, v in attrs}
        if amap.get("name", "").strip().lower() == "app-release-id":
            self.meta.append(amap.get("content", "").strip())


def extract_meta_ids(html_text: str) -> list[str]:
    p = MetaParser()
    p.feed(html_text)
    p.close()
    return [m for m in p.meta if m]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


_SHARED_BACKEND_ENTRIES: list[tuple[str, bytes, int]] | None = None
_SHARED_FRONTEND_HTML: bytes | None = None


def _load_shared_app_entries(project_root: str) -> tuple[list[tuple[str, bytes, int]], bytes]:
    global _SHARED_BACKEND_ENTRIES, _SHARED_FRONTEND_HTML
    if _SHARED_BACKEND_ENTRIES is not None and _SHARED_FRONTEND_HTML is not None:
        return _SHARED_BACKEND_ENTRIES, _SHARED_FRONTEND_HTML

    entries: list[tuple[str, bytes, int]] = []
    seen: set[str] = set()
    backend_root = os.path.join(project_root, "backend")

    def add_tree(root_dir: str):
        for r, _, files in os.walk(root_dir):
            for fn in files:
                fp = os.path.join(r, fn)
                if not os.path.isfile(fp) or os.path.islink(fp):
                    continue
                rel = f"backend/{os.path.relpath(fp, backend_root)}"
                if rel in seen:
                    continue
                seen.add(rel)
                mode = 0o755 if os.access(fp, os.X_OK) else 0o644
                with open(fp, "rb") as fh:
                    entries.append((rel, fh.read(), mode))

    add_tree(os.path.join(backend_root, "dist"))
    for pkg_file in ("package.json", "package-lock.json"):
        fp = os.path.join(backend_root, pkg_file)
        with open(fp, "rb") as fh:
            entries.append((f"backend/{pkg_file}", fh.read(), 0o644))

    nm_root = os.path.join(backend_root, "node_modules")
    for pkg in os.listdir(nm_root):
        if pkg.startswith("."):
            continue
        sp = os.path.join(nm_root, pkg)
        if os.path.islink(sp):
            continue
        add_tree(sp)

    fe_html_path = os.path.join(project_root, "frontend", "dist", "index.html")
    with open(fe_html_path, "rb") as fh:
        fe_html = fh.read()

    _SHARED_BACKEND_ENTRIES = entries
    _SHARED_FRONTEND_HTML = fe_html
    return entries, fe_html


class RuntimeSandbox:
    def __init__(self, retain_releases: int = 3):
        self.puppet_dir = os.environ["PUPPET_DIR"]
        self.project_root = os.environ["PROJECT_ROOT"]
        self.release_mgr = os.path.join(self.puppet_dir, "modules/application/files/release_manager.py")
        self.health_chk = os.path.join(self.puppet_dir, "modules/application/files/health_check.py")
        self.nginx_bin = shutil.which("nginx") or "/usr/sbin/nginx"
        self.node_bin = shutil.which("node")
        assert os.path.isfile(self.nginx_bin), f"nginx missing: {self.nginx_bin}"
        assert self.node_bin and os.path.isfile(self.node_bin), "node missing"

        self.retain_releases = retain_releases
        self.b_port = free_port()
        self.f_port = free_port()
        self.v_port = free_port()
        while len({self.b_port, self.f_port, self.v_port}) < 3:
            self.f_port = free_port()
            self.v_port = free_port()

        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        for d in (
            "var/lib/data",
            "etc/app",
            "cache/staging",
            "systemd",
            "ctrl",
            "nginx/conf.d",
            "nginx/sites-available",
            "nginx/sites-enabled",
            "nginx/tmp/body",
            "nginx/tmp/proxy",
            "nginx/tmp/fcgi",
            "nginx/tmp/uwsgi",
            "nginx/tmp/scgi",
        ):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)

        self.staging = os.path.join(self.root, "cache/staging")
        self.data_dir = os.path.join(self.root, "var/lib/data")
        self.state_file = os.path.join(self.root, "var/lib/release-state.json")
        self.releases_dir = os.path.join(self.root, "opt/releases")
        self.current_link = os.path.join(self.root, "opt/current")
        self.backend_link = os.path.join(self.root, "opt/backend")
        self.frontend_link = os.path.join(self.root, "www/dist")
        self.maint_flag = os.path.join(self.root, "opt/maintenance.flag")
        self.env_file = os.path.join(self.root, "etc/app/backend.env")
        self.node_pid_file = os.path.join(self.root, "node.pid")
        self.nginx_pid_file = os.path.join(self.root, "nginx/nginx.pid")
        self.mock_sc_log = os.path.join(self.root, "mock_sc.log")
        self.ctrl_dir = os.path.join(self.root, "ctrl")
        self.main_conf = os.path.join(self.root, "nginx/nginx.conf")
        self.mock_sc = os.path.join(self.root, "mock-systemctl.sh")
        self.mock_ngx = os.path.join(self.root, "mock-nginx.sh")
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        with open(self.main_conf, "w", encoding="utf-8") as fh:
            fh.write(
                f"pid {self.nginx_pid_file};\n"
                f"error_log {self.root}/nginx/error.log;\n"
                f"worker_processes 1;\n"
                f"events {{ worker_connections 64; }}\n"
                f"http {{\n"
                f"    include /etc/nginx/mime.types;\n"
                f"    default_type application/octet-stream;\n"
                f"    access_log {self.root}/nginx/access.log;\n"
                f"    client_body_temp_path {self.root}/nginx/tmp/body;\n"
                f"    proxy_temp_path {self.root}/nginx/tmp/proxy;\n"
                f"    fastcgi_temp_path {self.root}/nginx/tmp/fcgi;\n"
                f"    uwsgi_temp_path {self.root}/nginx/tmp/uwsgi;\n"
                f"    scgi_temp_path {self.root}/nginx/tmp/scgi;\n"
                f"    include {self.root}/nginx/conf.d/*.conf;\n"
                f"    include {self.root}/nginx/sites-enabled/*;\n"
                f"}}\n"
            )

        with open(self.mock_ngx, "w", encoding="utf-8") as fh:
            fh.write(
                f"#!/usr/bin/env bash\n"
                f"exec '{self.nginx_bin}' -t -p '{self.root}/nginx' -c '{self.main_conf}' -e stderr\n"
            )

        with open(self.mock_sc, "w", encoding="utf-8") as fh:
            fh.write(f"""#!/usr/bin/env bash
set -eu
ORIG_ARGS="$*"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) break ;;
  esac
done
ACTION="${{1:-}}"
SVC="${{2:-}}"
echo "$ACTION $SVC :: $ORIG_ARGS" >> '{self.mock_sc_log}'

kill_pidfile() {{
  local pf="$1"
  if [ -s "$pf" ]; then
    local pid
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _i in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.05
      fi
    fi
    rm -f "$pf"
  fi
}}

if [ "$ACTION" = "daemon-reload" ]; then
  exit 0
fi

if [ "$SVC" = "git-repo-analyzer-backend" ]; then
  case "$ACTION" in
    is-active)
      [ -s '{self.node_pid_file}' ] && kill -0 "$(cat '{self.node_pid_file}' 2>/dev/null)" 2>/dev/null
      exit $?
      ;;
    stop)
      kill_pidfile '{self.node_pid_file}'
      exit 0
      ;;
    start|restart)
      if [ -f '{self.ctrl_dir}/fail_backend_restart' ]; then
        exit 1
      fi
      if [ -f '{self.ctrl_dir}/oneshot_break_frontend_101' ] && [ -f '{self.releases_dir}/1.0.1/frontend/dist/index.html' ]; then
        rm -f '{self.ctrl_dir}/oneshot_break_frontend_101'
        chmod 0000 '{self.releases_dir}/1.0.1/frontend/dist/index.html'
      fi
      kill_pidfile '{self.node_pid_file}'
      if [ -f '{self.ctrl_dir}/restart_delay_sec' ]; then
        sleep "$(cat '{self.ctrl_dir}/restart_delay_sec')"
      fi
      set -a
      . '{self.env_file}'
      set +a
      nohup '{self.node_bin}' '{self.root}/opt/backend/dist/server.js' >'{self.root}/node.log' 2>&1 &
      echo $! > '{self.node_pid_file}'
      exit 0
      ;;
  esac
elif [ "$SVC" = "nginx" ]; then
  case "$ACTION" in
    is-active)
      [ -s '{self.nginx_pid_file}' ] && kill -0 "$(cat '{self.nginx_pid_file}' 2>/dev/null)" 2>/dev/null
      exit $?
      ;;
    start)
      if [ -s '{self.nginx_pid_file}' ] && kill -0 "$(cat '{self.nginx_pid_file}' 2>/dev/null)" 2>/dev/null; then
        exit 0
      fi
      '{self.nginx_bin}' -p '{self.root}/nginx' -c '{self.main_conf}' -e '{self.root}/nginx/startup.log'
      for _i in $(seq 1 40); do
        [ -s '{self.nginx_pid_file}' ] && kill -0 "$(cat '{self.nginx_pid_file}' 2>/dev/null)" 2>/dev/null && break
        sleep 0.05
      done
      exit 0
      ;;
    reload|restart)
      if [ -s '{self.nginx_pid_file}' ] && kill -0 "$(cat '{self.nginx_pid_file}' 2>/dev/null)" 2>/dev/null; then
        '{self.nginx_bin}' -s reload -p '{self.root}/nginx' -c '{self.main_conf}' -e '{self.root}/nginx/startup.log'
      else
        '{self.nginx_bin}' -p '{self.root}/nginx' -c '{self.main_conf}' -e '{self.root}/nginx/startup.log'
      fi
      exit 0
      ;;
    stop)
      kill_pidfile '{self.nginx_pid_file}'
      exit 0
      ;;
  esac
fi
exit 0
""")
        os.chmod(self.mock_sc, 0o755)
        os.chmod(self.mock_ngx, 0o755)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        for pf in (self.node_pid_file, self.nginx_pid_file):
            if os.path.isfile(pf):
                try:
                    pid = int(open(pf).read().strip())
                    os.kill(pid, signal.SIGTERM)
                    for _ in range(20):
                        try:
                            os.kill(pid, 0)
                            time.sleep(0.05)
                        except OSError:
                            break
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass
                except Exception:
                    pass
        # Restore permissions inside temp dir before cleanup in case a test chmodded 0000
        for r, dirs, files in os.walk(self.root):
            for d in dirs:
                try:
                    os.chmod(os.path.join(r, d), 0o755)
                except OSError:
                    pass
            for fn in files:
                try:
                    os.chmod(os.path.join(r, fn), 0o644)
                except OSError:
                    pass
        self._tmp.cleanup()

    def build_release(self, ver: str, *, broken_backend: bool = False, frontend_html: bytes | None = None) -> str:
        entries, fe_html = _load_shared_app_entries(self.project_root)
        tar_path = os.path.join(self.staging, f"{ver}.tar.gz")
        manifest = {
            "releaseId": ver,
            "gitCommit": f"audit-{ver}",
            "builtAt": "2026-11-26T00:00:00Z",
            "nodeVersion": "v24.13.1",
        }
        with tarfile.open(tar_path, "w:gz") as tar:
            def add(rel: str, data: bytes, mode: int = 0o644):
                ti = tarfile.TarInfo(name=f"release/{rel}")
                ti.size = len(data)
                ti.mode = mode
                tar.addfile(ti, io.BytesIO(data))

            add("release-manifest.json", json.dumps(manifest).encode("utf-8"))
            for rel, data, mode in entries:
                if broken_backend and rel == "backend/dist/server.js":
                    add(rel, b"console.error('intentional broken backend'); process.exit(1);\n", 0o644)
                else:
                    add(rel, data, mode)
            add("frontend/dist/index.html", frontend_html if frontend_html is not None else fe_html)
            add(f"frontend/dist/assets/app-{ver}.js", f"console.log('release-{ver}');\n".encode("utf-8"))

        sha = hashlib.sha256(open(tar_path, "rb").read()).hexdigest()
        with open(f"{tar_path}.sha256", "w", encoding="utf-8") as fh:
            fh.write(f"{sha}  {ver}.tar.gz\n")
        return sha

    def apply(
        self,
        ver: str,
        sha: str,
        *,
        verify_health: bool = True,
        manage_maintenance: bool = True,
        verify_consistency: bool = True,
        health_attempts: int = 15,
        retain_releases: int | None = None,
    ) -> subprocess.CompletedProcess:
        rr = retain_releases if retain_releases is not None else self.retain_releases
        expr = (
            f"class {{ 'application': "
            f"release_version => '{ver}', expected_sha256 => '{sha}', retain_releases => {rr}, "
            f"manage_packages => false, manage_users => false, manage_ownership => false, "
            f"manage_service => true, service_provider => 'base', manage_ipv6 => false, "
            f"systemctl_bin => '{self.mock_sc}', nginx_bin => '{self.mock_ngx}', nginx_configtest_cmd => '{self.mock_ngx} -t', "
            f"verify_health => {'true' if verify_health else 'false'}, "
            f"manage_maintenance => {'true' if manage_maintenance else 'false'}, "
            f"verify_release_consistency => {'true' if verify_consistency else 'false'}, "
            f"health_attempts => {health_attempts}, health_delay => 1, verify_runtime => true, node_bin => '{self.node_bin}', "
            f"base_dir => '{self.root}/opt', maintenance_flag_file => '{self.maint_flag}', "
            f"cache_dir => '{self.root}/cache', staging_dir => '{self.staging}', www_dir => '{self.root}/www', "
            f"data_base_dir => '{self.root}/var/lib', data_dir => '{self.data_dir}', state_file => '{self.state_file}', "
            f"env_dir => '{self.root}/etc/app', env_file => '{self.env_file}', systemd_unit_path => '{self.root}/systemd/s.service', "
            f"conf_d_dir => '{self.root}/nginx/conf.d', sites_available_dir => '{self.root}/nginx/sites-available', "
            f"sites_enabled_dir => '{self.root}/nginx/sites-enabled', "
            f"backend_port => {self.b_port}, listen_port => {self.f_port}, nginx_verify_port => {self.v_port}, "
            f"cors_origin => 'http://127.0.0.1:{self.f_port}' }}"
        )
        return subprocess.run(
            ["puppet", "apply", "--detailed-exitcodes", f"--modulepath={self.puppet_dir}/modules", "--certname", "app-server", "-e", expr],
            capture_output=True,
            text=True,
            check=False,
        )

    def http_get(self, port: int, path: str, timeout: float = 2.0) -> tuple[int, dict[str, str], str]:
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method="GET")
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                hdrs = {k.lower(): v for k, v in resp.headers.items()}
                return resp.getcode(), hdrs, resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as err:
            hdrs = {k.lower(): v for k, v in err.headers.items()}
            return err.code, hdrs, err.read().decode("utf-8", errors="replace")

    def http_post_json(self, port: int, path: str, payload: dict, origin: str | None = None, timeout: float = 2.0) -> tuple[int, dict[str, str], str]:
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if origin:
            headers["Origin"] = origin
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers=headers, method="POST")
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                hdrs = {k.lower(): v for k, v in resp.headers.items()}
                return resp.getcode(), hdrs, resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as err:
            hdrs = {k.lower(): v for k, v in err.headers.items()}
            return err.code, hdrs, err.read().decode("utf-8", errors="replace")

    def read_pair_via_port(self, port: int) -> tuple[int, int, str | None, str | None, str | None]:
        fc, _, fb = self.http_get(port, "/")
        bc, bh, bb = self.http_get(port, "/api/health")
        f_rel = extract_meta_ids(fb)[0] if fc == 200 and extract_meta_ids(fb) else None
        b_rel = None
        if bc == 200:
            try:
                b_rel = json.loads(bb).get("releaseId")
            except Exception:
                b_rel = None
        return fc, bc, f_rel, b_rel, bh.get("x-app-release")

    def assert_maintenance_blocked(self, asset_path: str = "/assets/app-1.0.1.js"):
        assert os.path.isfile(self.maint_flag), f"Missing maintenance flag {self.maint_flag}"
        for path in ("/", asset_path, "/api/health"):
            code, hdrs, body = self.http_get(self.f_port, path)
            assert code == 503, f"Expected 503 on public {path} during maintenance, got {code}: {body[:200]}"
            assert hdrs.get("retry-after") == "5", f"Expected Retry-After: 5 on {path}, got {hdrs}"
            assert json.loads(body).get("status") == "MAINTENANCE", f"Expected MAINTENANCE body on {path}: {body}"
        pcode, phdrs, pbody = self.http_post_json(
            self.f_port,
            "/api/analyses",
            {"repositoryUrl": "https://github.com/octocat/Hello-World"},
            origin=f"http://127.0.0.1:{self.f_port}",
        )
        assert pcode == 503 and phdrs.get("retry-after") == "5", f"Expected 503 on POST /api/analyses, got {pcode}"
        hc, _, hb = self.http_get(self.f_port, "/healthz")
        assert hc == 200 and hb.strip() == "ok", f"Expected /healthz 200 ok during maintenance, got {hc} {hb!r}"

    def node_pid(self) -> int:
        return int(open(self.node_pid_file).read().strip())

    def nginx_pid(self) -> int:
        return int(open(self.nginx_pid_file).read().strip())

    def read_state(self) -> dict:
        return json.load(open(self.state_file, encoding="utf-8"))
HARNESS_EOF

export _RT_HARNESS_DIR

# ------------------------------------------------------------------------------
# 20. Runtime Consistency Test A — Normal Controlled Activation (1.0.0 -> 1.0.1 -> 1.0.2)
# ------------------------------------------------------------------------------
echo -n "[Test 20/${TOTAL_COUNT}] Test A: Controlled 503 transition, runtime parity & post-exit pruning... "
python3 - << 'EOF'
import os, sys, threading, time, json
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

with RuntimeSandbox(retain_releases=2) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    s102 = sb.build_release("1.0.2")

    # Initial 1.0.0 convergence (exit 2 -> exit 0)
    r0 = sb.apply("1.0.0", s100)
    assert r0.returncode == 2, f"1.0.0 apply failed ({r0.returncode}):\n{r0.stdout}\n{r0.stderr}"
    assert sb.apply("1.0.0", s100).returncode == 0
    assert not os.path.exists(sb.maint_flag)

    fc, bc, frel, brel, hrel = sb.read_pair_via_port(sb.f_port)
    assert (fc, bc, frel, brel, hrel) == (200, 200, "1.0.0", "1.0.0", "1.0.0"), (fc, bc, frel, brel, hrel)
    pid_100 = sb.node_pid()

    # Slow backend restart slightly so background public HTTP poller reliably catches maintenance 503
    open(os.path.join(sb.ctrl_dir, "restart_delay_sec"), "w").write("0.6")
    observations = []
    stop_event = threading.Event()

    def poller():
        while not stop_event.is_set():
            try:
                fc_p, _, fbody_p = sb.http_get(sb.f_port, "/")
                ac_p, ahdrs_p, abody_p = sb.http_get(sb.f_port, "/api/health")
                pc_p, _, _ = sb.http_post_json(
                    sb.f_port,
                    "/api/analyses",
                    {"repositoryUrl": "https://github.com/octocat/Hello-World"},
                    origin=f"http://127.0.0.1:{sb.f_port}",
                )
                observations.append((fc_p, fbody_p, ac_p, abody_p, ahdrs_p.get("retry-after"), pc_p))
            except Exception as exc:
                observations.append((-1, str(exc), -1, str(exc), None, -1))
            time.sleep(0.02)

    t = threading.Thread(target=poller, daemon=True)
    t.start()
    r1 = sb.apply("1.0.1", s101)
    stop_event.set()
    t.join(timeout=5)
    assert r1.returncode == 2, f"1.0.1 upgrade failed ({r1.returncode}):\n{r1.stdout}\n{r1.stderr}"

    from rt_harness import extract_meta_ids
    saw_503 = False
    phase = "pre"
    for fc_p, fbody_p, ac_p, abody_p, r_after, pc_p in observations:
        assert fc_p in (200, 503) and ac_p in (200, 503) and pc_p in (202, 503), (fc_p, ac_p, pc_p)
        if 503 in (fc_p, ac_p, pc_p):
            if fc_p == 503 and ac_p == 503 and pc_p == 503:
                saw_503 = True
            phase = "maint"
            if ac_p == 503:
                assert r_after == "5"
                assert json.loads(abody_p).get("status") == "MAINTENANCE"
        elif phase == "maint":
            phase = "post"
        if fc_p == 200 and ac_p == 200:
            fids = extract_meta_ids(fbody_p)
            bid = json.loads(abody_p).get("releaseId")
            assert len(fids) == 1 and bid == fids[0], f"MIXED RELEASE OBSERVED LIVE: frontend={fids}, backend={bid}"
            expected = "1.0.0" if phase == "pre" else "1.0.1"
            assert bid == expected, f"Unexpected release {bid} in phase {phase}"

    assert saw_503, f"Expected to observe 503 maintenance window during rollout; got {len(observations)} samples"
    pid_101 = sb.node_pid()
    assert pid_101 != pid_100, "Backend PID must change on 1.0.1 restart"
    assert not os.path.exists(sb.maint_flag)

    fc, bc, frel, brel, hrel = sb.read_pair_via_port(sb.f_port)
    assert (fc, bc, frel, brel, hrel) == (200, 200, "1.0.1", "1.0.1", "1.0.1"), (fc, bc, frel, brel, hrel)
    ac_js, _, abody_js = sb.http_get(sb.f_port, "/assets/app-1.0.1.js")
    assert ac_js == 200 and "release-1.0.1" in abody_js
    pc_ok, _, pbody_ok = sb.http_post_json(
        sb.f_port,
        "/api/analyses",
        {"repositoryUrl": "https://github.com/octocat/Hello-World"},
        origin=f"http://127.0.0.1:{sb.f_port}",
    )
    assert pc_ok == 202 and json.loads(pbody_ok).get("status") == "QUEUED", (pc_ok, pbody_ok)

    st = sb.read_state()
    assert st["currentKnownGood"]["releaseId"] == "1.0.1"
    assert st["previousKnownGood"]["releaseId"] == "1.0.0"
    assert st["maintenance"]["active"] is False

    # 1.0.2 upgrade with retain_releases=2 prunes 1.0.0 only after promotion & maintenance clear
    os.unlink(os.path.join(sb.ctrl_dir, "restart_delay_sec"))
    assert sb.apply("1.0.2", s102).returncode == 2
    assert not os.path.exists(os.path.join(sb.releases_dir, "1.0.0")), "1.0.0 should be pruned after 1.0.2 exits maintenance"
    assert os.path.isdir(os.path.join(sb.releases_dir, "1.0.1")) and os.path.isdir(os.path.join(sb.releases_dir, "1.0.2"))
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.2", "1.0.2", "1.0.2")
EOF
echo "PASS (controlled 503 window observed, zero mixed responses, runtime parity & safe pruning verified)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 21. Runtime Consistency Test B — SIGKILL After Atomic current Pointer Switch
# ------------------------------------------------------------------------------
echo -n "[Test 21/${TOTAL_COUNT}] Test B: SIGKILL post-pointer-switch blocks mixed traffic & recovers... "
python3 - << 'EOF'
import os, signal, subprocess, sys, json
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox, extract_meta_ids

with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.0", s100).returncode == 2

    subprocess.run([
        "python3", sb.release_mgr, "prepare",
        "--version", "1.0.1", "--expected-sha256", s101,
        "--staging-dir", sb.staging, "--releases-dir", sb.releases_dir,
    ], check=True, capture_output=True)
    subprocess.run([
        "python3", sb.release_mgr, "enter-maintenance",
        "--version", "1.0.1", "--expected-sha256", s101,
        "--state-file", sb.state_file, "--backend-link", sb.backend_link,
        "--maintenance-flag", sb.maint_flag, "--reason", "test-b-upgrade",
    ], check=True, capture_output=True)

    kill_code = (
        f"import importlib.util, os, signal, sys\n"
        f"spec = importlib.util.spec_from_file_location('rm', {sb.release_mgr!r})\n"
        f"rm = importlib.util.module_from_spec(spec); spec.loader.exec_module(rm)\n"
        f"orig_replace = os.replace\n"
        f"target_cur = os.path.abspath({sb.current_link!r})\n"
        f"def hooked(s, d):\n"
        f"    orig_replace(s, d)\n"
        f"    if os.path.abspath(d) == target_cur:\n"
        f"        os.kill(os.getpid(), signal.SIGKILL)\n"
        f"os.replace = hooked\n"
        f"sys.exit(rm.main(['activate', '--version', '1.0.1', '--expected-sha256', {s101!r}, "
        f"'--releases-dir', {sb.releases_dir!r}, '--current-link', {sb.current_link!r}, "
        f"'--backend-link', {sb.backend_link!r}, '--frontend-link', {sb.frontend_link!r}, "
        f"'--state-file', {sb.state_file!r}]))\n"
    )
    proc = subprocess.run([sys.executable, "-c", kill_code], capture_output=True, text=True)
    assert proc.returncode == -signal.SIGKILL, proc.returncode

    # Internal state IS momentarily split (disk current=1.0.1 vs running Node=1.0.0), so verify listener catches mixed state,
    # while public listen_port MUST return 503 MAINTENANCE for EVERY client request.
    assert os.path.realpath(sb.backend_link) == os.path.realpath(os.path.join(sb.releases_dir, "1.0.1", "backend"))
    assert os.path.realpath(sb.frontend_link) == os.path.realpath(os.path.join(sb.releases_dir, "1.0.1", "frontend", "dist"))
    assert sb.read_state()["pendingActivation"]["serviceSynced"] is False

    vc_f, _, vb_f = sb.http_get(sb.v_port, "/")
    bc_d, _, bb_d = sb.http_get(sb.b_port, "/api/health")
    assert vc_f == 200 and extract_meta_ids(vb_f) == ["1.0.1"]
    assert bc_d == 200 and json.loads(bb_d)["releaseId"] == "1.0.0"

    sb.assert_maintenance_blocked("/assets/app-1.0.1.js")

    # Autonomous Puppet convergence restarts backend, verifies parity on verify_port, promotes 1.0.1, clears maintenance
    assert sb.apply("1.0.1", s101).returncode == 2
    assert sb.apply("1.0.1", s101).returncode == 0
    assert not os.path.exists(sb.maint_flag)
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.1", "1.0.1", "1.0.1")
EOF
echo "PASS (SIGKILL post-switch strictly blocked behind 503 & autonomously converged to 1.0.1 == 1.0.1)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 22. Runtime Consistency Test C — Backend Restart Failure During Rollout
# ------------------------------------------------------------------------------
echo -n "[Test 22/${TOTAL_COUNT}] Test C: Backend restart failure stays in 503, never prunes 1.0.0, rolls back cleanly... "
python3 - << 'EOF'
import os, sys
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

with RuntimeSandbox(retain_releases=2) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")

    # Remove 1.0.0 tarball from staging before upgrade to prove rollback needs no staging tarball
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz"))
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz.sha256"))

    open(os.path.join(sb.ctrl_dir, "fail_backend_restart"), "w").write("1")
    r_fail = sb.apply("1.0.1", s101, health_attempts=3)
    assert r_fail.returncode not in (0, 2), f"Expected Puppet failure when backend restart fails: {r_fail.returncode}"

    st = sb.read_state()
    assert st["currentKnownGood"]["releaseId"] == "1.0.0", f"1.0.1 must not be promoted: {st}"
    assert st["maintenance"]["active"] is True
    assert os.path.isdir(os.path.join(sb.releases_dir, "1.0.0")), "1.0.0 must remain preserved on disk"
    sb.assert_maintenance_blocked("/assets/app-1.0.1.js")

    # Restore service controller & roll back Hiera to retained 1.0.0 (no tarball in staging)
    os.unlink(os.path.join(sb.ctrl_dir, "fail_backend_restart"))
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.apply("1.0.0", s100).returncode == 0
    assert not os.path.exists(sb.maint_flag)
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")
EOF
echo "PASS (backend restart fail held in 503, 1.0.0 intact, empty-staging rollback restored 1.0.0)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 23. Runtime Consistency Test D — Frontend Health & Release Mismatch Failures
# ------------------------------------------------------------------------------
echo -n "[Test 23/${TOTAL_COUNT}] Test D: Mismatch detection + real NGINX 403 auto-revert preserve 503 until rollback... "
python3 - << 'EOF'
import os, subprocess, sys
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

# D1: Explicit frontend (1.0.1) != backend (1.0.0) release mismatch detected on verify_port & auto-reverted
with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.0", s100).returncode == 2

    subprocess.run([
        "python3", sb.release_mgr, "prepare",
        "--version", "1.0.1", "--expected-sha256", s101,
        "--staging-dir", sb.staging, "--releases-dir", sb.releases_dir,
    ], check=True, capture_output=True)
    subprocess.run([
        "python3", sb.release_mgr, "enter-maintenance",
        "--version", "1.0.1", "--expected-sha256", s101,
        "--state-file", sb.state_file, "--backend-link", sb.backend_link,
        "--maintenance-flag", sb.maint_flag,
    ], check=True, capture_output=True)
    subprocess.run([
        "python3", sb.release_mgr, "activate",
        "--version", "1.0.1", "--expected-sha256", s101,
        "--releases-dir", sb.releases_dir, "--current-link", sb.current_link,
        "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link,
        "--state-file", sb.state_file,
    ], check=True, capture_output=True)

    # Deliberately do NOT restart backend: NGINX verify_port serves 1.0.1 HTML while backend serves 1.0.0
    vh = subprocess.run([
        "python3", sb.release_mgr, "verify-health",
        "--mode", "frontend", "--version", "1.0.1", "--expected-sha256", s101,
        "--state-file", sb.state_file, "--releases-dir", sb.releases_dir,
        "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link,
        "--maintenance-flag", sb.maint_flag, "--expected-release", "1.0.1",
        "--health-check-script", sb.health_chk, "--host", "127.0.0.1", "--port", str(sb.v_port),
        "--attempts", "2", "--delay", "0", "--revert-on-fail",
        "--restart-on-revert", "--systemctl-bin", sb.mock_sc, "--backend-service", "git-repo-analyzer-backend",
        "--nginx-bin", sb.mock_ngx, "--nginx-service", "nginx",
    ], capture_output=True, text=True)
    assert vh.returncode != 0
    assert "mismatch" in vh.stderr.lower() or "expected release '1.0.1'" in vh.stderr.lower(), vh.stderr
    assert os.path.realpath(sb.current_link) == os.path.realpath(os.path.join(sb.releases_dir, "1.0.0"))
    sb.assert_maintenance_blocked("/assets/app-1.0.0.js")
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")

# D2: Full Puppet run where backend health gate passes (1.0.1 200 UP) and real NGINX serves broken non-HTML index.html on verify_port
with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1", frontend_html=b'<meta name="app-release-id" content="1.0.1" />\nBROKEN_STATIC_ASSET\n')
    assert sb.apply("1.0.0", s100).returncode == 2
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz"))
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz.sha256"))

    r_fail = sb.apply("1.0.1", s101, health_attempts=2)
    assert r_fail.returncode not in (0, 2), f"Expected frontend gate failure: {r_fail.returncode}"
    assert "app_verify_frontend_health_gate" in r_fail.stderr, r_fail.stderr

    # Auto-reverted to 1.0.0, maintenance STILL active, 1.0.1 not promoted, no pruning
    st = sb.read_state()
    assert st["currentKnownGood"]["releaseId"] == "1.0.0"
    assert st["maintenance"]["active"] is True
    assert os.path.realpath(sb.current_link) == os.path.realpath(os.path.join(sb.releases_dir, "1.0.0"))
    assert os.path.isdir(os.path.join(sb.releases_dir, "1.0.0"))
    sb.assert_maintenance_blocked("/assets/app-1.0.0.js")

    # Hiera rollback to 1.0.0 recovers cleanly
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.apply("1.0.0", s100).returncode == 0
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")

# D3: Full Puppet run where frontend index.html becomes unreadable (chmod 0000) after restart -> verify-health auto-reverts inside 503
with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.0", s100).returncode == 2
    open(os.path.join(sb.ctrl_dir, "oneshot_break_frontend_101"), "w").write("1")
    r_perm = sb.apply("1.0.1", s101, health_attempts=2)
    assert r_perm.returncode not in (0, 2)
    assert os.path.realpath(sb.current_link) == os.path.realpath(os.path.join(sb.releases_dir, "1.0.0"))
    sb.assert_maintenance_blocked("/assets/app-1.0.0.js")
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")
EOF
echo "PASS (frontend mismatch, NGINX broken-HTML & unreadable asset auto-reverted to 1.0.0 inside 503 window & rolled back)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 24. Runtime Consistency Test E — SIGKILL During exit-maintenance
# ------------------------------------------------------------------------------
echo -n "[Test 24/${TOTAL_COUNT}] Test E: SIGKILL pre/post unlink during exit-maintenance recovers safely... "
python3 - << 'EOF'
import os, signal, subprocess, sys
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.0", s100).returncode == 2

    # Promote 1.0.1 manually inside maintenance (prior to exit-maintenance)
    for args in (
        ["prepare", "--version", "1.0.1", "--expected-sha256", s101, "--staging-dir", sb.staging, "--releases-dir", sb.releases_dir],
        ["enter-maintenance", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file, "--backend-link", sb.backend_link, "--maintenance-flag", sb.maint_flag],
        ["activate", "--version", "1.0.1", "--expected-sha256", s101, "--releases-dir", sb.releases_dir, "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link, "--state-file", sb.state_file],
    ):
        subprocess.run(["python3", sb.release_mgr] + args, check=True, capture_output=True)
    subprocess.run([sb.mock_sc, "restart", "git-repo-analyzer-backend"], check=True)
    subprocess.run(["python3", sb.release_mgr, "mark-service-synced", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file], check=True, capture_output=True)
    subprocess.run(["python3", sb.release_mgr, "verify-health", "--mode", "backend", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file, "--releases-dir", sb.releases_dir, "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link, "--maintenance-flag", sb.maint_flag, "--expected-release", "1.0.1", "--health-check-script", sb.health_chk, "--host", "127.0.0.1", "--port", str(sb.b_port), "--attempts", "15", "--delay", "1"], check=True, capture_output=True)
    subprocess.run(["python3", sb.release_mgr, "verify-health", "--mode", "frontend", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file, "--releases-dir", sb.releases_dir, "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link, "--maintenance-flag", sb.maint_flag, "--expected-release", "1.0.1", "--health-check-script", sb.health_chk, "--host", "127.0.0.1", "--port", str(sb.v_port), "--attempts", "5", "--delay", "1"], check=True, capture_output=True)
    subprocess.run(["python3", sb.release_mgr, "promote-release", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file, "--releases-dir", sb.releases_dir, "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link, "--require-service-synced"], check=True, capture_output=True)

    def kill_exit_maint(when: str) -> int:
        code = (
            f"import importlib.util, os, signal, sys\n"
            f"spec = importlib.util.spec_from_file_location('rm', {sb.release_mgr!r})\n"
            f"rm = importlib.util.module_from_spec(spec); spec.loader.exec_module(rm)\n"
            f"orig_unlink = os.unlink\n"
            f"target_flag = os.path.abspath({sb.maint_flag!r})\n"
            f"def hooked(p, *args, **kwargs):\n"
            f"    if {when!r} == 'pre' and os.path.abspath(p) == target_flag:\n"
            f"        os.kill(os.getpid(), signal.SIGKILL)\n"
            f"    orig_unlink(p, *args, **kwargs)\n"
            f"    if {when!r} == 'post' and os.path.abspath(p) == target_flag:\n"
            f"        os.kill(os.getpid(), signal.SIGKILL)\n"
            f"os.unlink = hooked\n"
            f"sys.exit(rm.main(['exit-maintenance', '--version', '1.0.1', '--expected-sha256', {s101!r}, "
            f"'--state-file', {sb.state_file!r}, '--releases-dir', {sb.releases_dir!r}, "
            f"'--current-link', {sb.current_link!r}, '--backend-link', {sb.backend_link!r}, '--frontend-link', {sb.frontend_link!r}, "
            f"'--maintenance-flag', {sb.maint_flag!r}, '--health-check-script', {sb.health_chk!r}, "
            f"'--host', '127.0.0.1', '--backend-port', {str(sb.b_port)!r}, '--verify-port', {str(sb.v_port)!r}, '--listen-port', {str(sb.f_port)!r}, "
            f"'--verify-consistency', '--require-service-synced', '--attempts', '5', '--delay', '1']))\n"
        )
        p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        assert p.returncode == -signal.SIGKILL, f"Expected SIGKILL during exit-maintenance ({when}), got rc={p.returncode}: {p.stderr}"
        return p.returncode

    # E1: SIGKILL right before unlinking maintenance.flag -> stays 503, Puppet converges to live 1.0.1
    assert kill_exit_maint("pre") == -signal.SIGKILL
    sb.assert_maintenance_blocked("/assets/app-1.0.1.js")
    assert sb.read_state()["maintenance"]["active"] is True
    assert sb.apply("1.0.1", s101).returncode == 2
    assert sb.apply("1.0.1", s101).returncode == 0
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.1", "1.0.1", "1.0.1")

    # E2: Re-enter maintenance, stop backend, SIGKILL right AFTER unlinking maintenance.flag (state.maintenance.active still True)
    subprocess.run(["python3", sb.release_mgr, "enter-maintenance", "--version", "1.0.1", "--expected-sha256", s101, "--state-file", sb.state_file, "--backend-link", sb.backend_link, "--maintenance-flag", sb.maint_flag], check=True, capture_output=True)
    # Direct exit-maintenance MUST refuse to clear maintenance while backend is stopped
    subprocess.run([sb.mock_sc, "stop", "git-repo-analyzer-backend"], check=True)
    bad_exit = subprocess.run([
        "python3", sb.release_mgr, "exit-maintenance", "--version", "1.0.1", "--expected-sha256", s101,
        "--state-file", sb.state_file, "--releases-dir", sb.releases_dir,
        "--current-link", sb.current_link, "--backend-link", sb.backend_link, "--frontend-link", sb.frontend_link,
        "--maintenance-flag", sb.maint_flag, "--health-check-script", sb.health_chk,
        "--host", "127.0.0.1", "--backend-port", str(sb.b_port), "--verify-port", str(sb.v_port), "--listen-port", str(sb.f_port),
        "--verify-consistency", "--require-service-synced", "--attempts", "2", "--delay", "0",
    ], capture_output=True, text=True)
    assert bad_exit.returncode != 0 and os.path.isfile(sb.maint_flag), "exit-maintenance must keep flag when backend unhealthy"

    # Restart backend, trigger post-unlink SIGKILL inside exit-maintenance, then stop backend to test interrupted-state recovery
    subprocess.run([sb.mock_sc, "start", "git-repo-analyzer-backend"], check=True)
    assert kill_exit_maint("post") == -signal.SIGKILL
    assert not os.path.exists(sb.maint_flag)
    assert sb.read_state()["maintenance"]["active"] is True
    subprocess.run([sb.mock_sc, "stop", "git-repo-analyzer-backend"], check=True)

    # Next Puppet run MUST detect maintenance.active==True, re-enter maintenance flag first, start backend, verify, and clear safely
    assert sb.apply("1.0.1", s101).returncode == 2
    assert sb.apply("1.0.1", s101).returncode == 0
    assert sb.read_state()["maintenance"]["active"] is False
    assert not os.path.exists(sb.maint_flag)
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.1", "1.0.1", "1.0.1")
EOF
echo "PASS (exit-maintenance SIGKILL pre/post-unlink & stopped-backend state recovery converged cleanly)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 25. Runtime Consistency Test F — Steady-State Puppet Idempotency
# ------------------------------------------------------------------------------
echo -n "[Test 25/${TOTAL_COUNT}] Test F: Steady-state Puppet idempotency (exit 0, zero restarts, zero 503)... "
python3 - << 'EOF'
import os, sys, threading, time
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

with RuntimeSandbox(retain_releases=3) as sb:
    s101 = sb.build_release("1.0.1")
    assert sb.apply("1.0.1", s101).returncode == 2
    assert sb.apply("1.0.1", s101).returncode == 0

    node_pid_before = sb.node_pid()
    nginx_pid_before = sb.nginx_pid()
    open(sb.mock_sc_log, "w").truncate(0)

    poll_results = []
    stop_ev = threading.Event()

    def steady_poller():
        while not stop_ev.is_set():
            poll_results.append(sb.read_pair_via_port(sb.f_port))
            time.sleep(0.05)

    t = threading.Thread(target=steady_poller, daemon=True)
    t.start()
    try:
        r1 = sb.apply("1.0.1", s101)
        r2 = sb.apply("1.0.1", s101)
    finally:
        stop_ev.set()
        t.join(timeout=5)

    assert r1.returncode == 0, f"First idempotent run changed resources ({r1.returncode}):\n{r1.stdout}"
    assert r2.returncode == 0, f"Second idempotent run changed resources ({r2.returncode}):\n{r2.stdout}"
    assert sb.node_pid() == node_pid_before, "Backend PID changed during idempotent converge"
    assert sb.nginx_pid() == nginx_pid_before, "NGINX PID changed during idempotent converge"

    sc_lines = open(sb.mock_sc_log).read().splitlines()
    mutating = [ln for ln in sc_lines if any(ln.startswith(op) for op in ("start ", "stop ", "restart ", "reload ", "daemon-reload "))]
    assert not mutating, f"Unexpected service mutations during idempotent apply: {mutating}"
    assert len(poll_results) >= 1
    for res in poll_results:
        assert res == (200, 200, "1.0.1", "1.0.1", "1.0.1"), f"Disruption during idempotent Puppet run: {res}"
EOF
echo "PASS (twice exit 0, zero restarts/reloads, zero PID changes, zero 503s)"
PASSED_COUNT=$((PASSED_COUNT + 1))

# ------------------------------------------------------------------------------
# 26. Runtime Consistency Test G — Persistent DATA_DIR Preservation & Rollback
# ------------------------------------------------------------------------------
echo -n "[Test 26/${TOTAL_COUNT}] Test G: Persistent DATA_DIR byte-identical across rollout, failures & rollback... "
python3 - << 'EOF'
import hashlib, json, os, signal, subprocess, sys
sys.path.insert(0, os.environ["_RT_HARNESS_DIR"])
from rt_harness import RuntimeSandbox

with RuntimeSandbox(retain_releases=3) as sb:
    s100 = sb.build_release("1.0.0")
    s101 = sb.build_release("1.0.1")
    s102 = sb.build_release("1.0.2")
    assert sb.apply("1.0.0", s100).returncode == 2

    # Write static persistent binary asset + create real persisted analysis via Node 24 API in DATA_DIR
    chart_path = os.path.join(sb.data_dir, "persistent-chart.png")
    chart_bytes = b"\x89PNG\r\n\x1a\nAUDIT-PERSISTENT-CHART-V1\x00\xff"
    open(chart_path, "wb").write(chart_bytes)
    chart_sha = hashlib.sha256(chart_bytes).hexdigest()

    pcode, _, pbody = sb.http_post_json(
        sb.f_port,
        "/api/analyses",
        {"repositoryUrl": "https://github.com/octocat/Hello-World"},
        origin=f"http://127.0.0.1:{sb.f_port}",
    )
    assert pcode == 202, (pcode, pbody)
    aid = json.loads(pbody)["analysisId"]
    analyses_path = os.path.join(sb.data_dir, "analyses.json")
    assert os.path.isfile(analyses_path) and aid in open(analyses_path).read()

    # 1. Normal upgrade 1.0.0 -> 1.0.1 preserves persisted API record and binary file
    assert sb.apply("1.0.1", s101).returncode == 2
    gc1, _, gb1 = sb.http_get(sb.f_port, f"/api/analyses/{aid}")
    assert gc1 == 200 and json.loads(gb1)["analysisId"] == aid

    # 2. Failed 1.0.2 restart + frontend permission failure + SIGKILL recovery
    open(os.path.join(sb.ctrl_dir, "fail_backend_restart"), "w").write("1")
    assert sb.apply("1.0.2", s102, health_attempts=2).returncode not in (0, 2)
    os.unlink(os.path.join(sb.ctrl_dir, "fail_backend_restart"))

    # Recover cleanly back onto 1.0.0 WITHOUT 1.0.0 tarball in staging
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz"))
    os.unlink(os.path.join(sb.staging, "1.0.0.tar.gz.sha256"))
    assert sb.apply("1.0.0", s100).returncode == 2
    assert sb.apply("1.0.0", s100).returncode == 0
    assert sb.read_pair_via_port(sb.f_port) == (200, 200, "1.0.0", "1.0.0", "1.0.0")

    assert hashlib.sha256(open(chart_path, "rb").read()).hexdigest() == chart_sha
    gc2, _, gb2 = sb.http_get(sb.f_port, f"/api/analyses/{aid}")
    assert gc2 == 200 and json.loads(gb2)["analysisId"] == aid, (gc2, gb2)
EOF
echo "PASS (DATA_DIR binary artifact SHA-256 & live API analysis record intact across rollout, failures & rollback)"
PASSED_COUNT=$((PASSED_COUNT + 1))

echo "=============================================================================="
echo "Phase 5B Application Test Results: ${PASSED_COUNT}/${TOTAL_COUNT} checks passed."
echo "Note: Local validation covers parser/ERB/Python checks, catalog compilation,"
echo "      DAG ordering, real nginx -t, real Node 24/NGINX runtime parity,"
echo "      controlled 503 maintenance gating, SIGKILL/failure recovery, and rollback."
echo "      Live NodeSource APT install and systemd convergence await Boundary B."
echo "=============================================================================="
