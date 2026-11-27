# ==============================================================================
# Class: application
# Purpose: Top-level orchestrator for Phase 5B application deployment on
#          app-server (EC2 2):
#          - Node.js 24 LTS runtime (application::nodejs)
#          - Checksum/manifest-verified immutable release staging (application::release)
#          - Express backend systemd unit & backend.env (application::backend)
#          - Post-backend loopback health verification
#          - Production NGINX SPA + /api/ reverse proxy (application::nginx)
#          - Post-frontend loopback health gate & safe release pruning/promotion
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class application (
  Boolean                               $enforce_node               = true,
  Optional[String[1]]                   $release_version            = undef,
  Optional[String[1]]                   $expected_sha256            = undef,
  Boolean                               $require_release            = false,
  Integer[2, 20]                        $retain_releases            = 3,
  Integer[24, 24]                       $node_major                 = 24,
  Boolean                               $manage_packages            = true,
  Boolean                               $verify_runtime             = true,
  Boolean                               $manage_users               = true,
  Boolean                               $manage_ownership           = true,
  Boolean                               $manage_service             = true,
  Boolean                               $manage_ipv6                = true,
  Boolean                               $verify_health              = true,
  Boolean                               $verify_api_proxy           = true,
  Boolean                               $manage_maintenance         = true,
  Boolean                               $verify_release_consistency = true,
  Integer[1, 30]                        $health_attempts            = 5,
  Integer[1, 10]                        $health_delay               = 1,
  Enum['127.0.0.1']                     $health_host                = '127.0.0.1',
  String[1]                             $base_dir                   = '/opt/git-repo-analyzer',
  Optional[String[1]]                   $maintenance_flag_file      = undef,
  String[1]                             $cache_dir                  = '/var/cache/git-repo-analyzer',
  String[1]                             $staging_dir                = '/var/cache/git-repo-analyzer/staging',
  String[1]                             $www_dir                    = '/var/www/git-repo-analyzer',
  String[1]                             $data_base_dir              = '/var/lib/git-repo-analyzer',
  String[1]                             $data_dir                   = '/var/lib/git-repo-analyzer/data',
  String[1]                             $state_file                 = '/var/lib/git-repo-analyzer/release-state.json',
  String[1]                             $env_dir                    = '/etc/git-repo-analyzer',
  String[1]                             $env_file                   = '/etc/git-repo-analyzer/backend.env',
  String[1]                             $systemd_unit_path          = '/etc/systemd/system/git-repo-analyzer-backend.service',
  String[1]                             $service_name               = 'git-repo-analyzer-backend',
  String[1]                             $backend_user               = 'gitrepo',
  String[1]                             $backend_group              = 'gitrepo',
  String[1]                             $frontend_owner             = 'root',
  String[1]                             $frontend_group             = 'www-data',
  String[1]                             $staging_owner              = 'ubuntu',
  String[1]                             $staging_group              = 'ubuntu',
  String[1]                             $node_bin                   = '/usr/bin/node',
  String[1]                             $python_bin                 = '/usr/bin/python3',
  String[1]                             $nginx_bin                  = '/usr/sbin/nginx',
  Optional[String[1]]                   $nginx_configtest_cmd       = undef,
  String[1]                             $systemctl_bin              = '/bin/systemctl',
  Enum['systemd', 'base']               $service_provider           = 'systemd',
  String[1]                             $conf_d_dir                 = '/etc/nginx/conf.d',
  String[1]                             $sites_available_dir        = '/etc/nginx/sites-available',
  String[1]                             $sites_enabled_dir          = '/etc/nginx/sites-enabled',
  String[1]                             $nginx_site_name            = 'git-repo-analyzer',
  String[1]                             $nginx_service              = 'nginx',
  Enum['production', 'development', 'test'] $node_env               = 'production',
  Enum['127.0.0.1', '::1', 'localhost'] $backend_host               = '127.0.0.1',
  Integer[1, 65535]                     $backend_port               = 3000,
  Integer[1, 65535]                     $listen_port                = 80,
  Optional[Integer[1, 65535]]           $nginx_verify_port          = 8081,
  String                                $cors_origin                = '',
  Boolean                               $enforce_production_cors    = true,
  Boolean                               $ssrf_check_dns             = true,
  Integer[5000, 3600000]                $analysis_timeout_ms        = 600000,
  Integer[10, 60000]                    $poll_interval_ms           = 1500,
  Boolean                               $jenkins_mock_mode          = true,
  String                                $jenkins_url                = '',
  String                                $jenkins_user               = '',
  Variant[Sensitive[String], String]    $jenkins_api_token          = '',
  Pattern[/^[A-Za-z0-9._-]+$/]         $jenkins_job_name           = 'git-repo-analyzer',
  Integer[500, 60000]                   $jenkins_request_timeout_ms = 5000,
) {
  if $enforce_node and $trusted['certname'] != '' and $trusted['certname'] != 'app-server' {
    fail("Class application is strictly restricted to app-server; attempted inclusion on '${trusted['certname']}'")
  }

  $release_active = ($release_version != undef and $expected_sha256 != undef)
  $effective_maintenance_flag = $maintenance_flag_file ? {
    undef   => "${base_dir}/maintenance.flag",
    default => $maintenance_flag_file,
  }
  $effective_manage_maintenance = ($release_active and $verify_health and $manage_maintenance)

  if $effective_manage_maintenance and $nginx_verify_port == undef {
    fail('Class application requires nginx_verify_port when both verify_health and manage_maintenance are enabled')
  }

  class { 'application::nodejs':
    node_major      => $node_major,
    manage_packages => $manage_packages,
    verify_runtime  => $verify_runtime,
    node_bin        => $node_bin,
  }

  class { 'application::release':
    version               => $release_version,
    expected_sha256       => $expected_sha256,
    require_release       => $require_release,
    base_dir              => $base_dir,
    cache_dir             => $cache_dir,
    staging_dir           => $staging_dir,
    www_dir               => $www_dir,
    state_file            => $state_file,
    retain_releases       => $retain_releases,
    staging_owner         => $staging_owner,
    staging_group         => $staging_group,
    backend_group         => $backend_group,
    frontend_owner        => $frontend_owner,
    frontend_group        => $frontend_group,
    manage_ownership      => $manage_ownership,
    manage_maintenance    => $effective_manage_maintenance,
    maintenance_flag_file => $effective_maintenance_flag,
    python_bin            => $python_bin,
  }

  class { 'application::backend':
    release_active             => $release_active,
    manage_users               => $manage_users,
    manage_ownership           => $manage_ownership,
    manage_service             => $manage_service,
    backend_user               => $backend_user,
    backend_group              => $backend_group,
    base_dir                   => $base_dir,
    data_base_dir              => $data_base_dir,
    data_dir                   => $data_dir,
    env_dir                    => $env_dir,
    env_file                   => $env_file,
    systemd_unit_path          => $systemd_unit_path,
    service_name               => $service_name,
    node_bin                   => $node_bin,
    systemctl_bin              => $systemctl_bin,
    service_provider           => $service_provider,
    node_env                   => $node_env,
    port                       => $backend_port,
    host                       => $backend_host,
    cors_origin                => $cors_origin,
    enforce_production_cors    => $enforce_production_cors,
    ssrf_check_dns             => $ssrf_check_dns,
    analysis_timeout_ms        => $analysis_timeout_ms,
    poll_interval_ms           => $poll_interval_ms,
    jenkins_mock_mode          => $jenkins_mock_mode,
    jenkins_url                => $jenkins_url,
    jenkins_user               => $jenkins_user,
    jenkins_api_token          => $jenkins_api_token,
    jenkins_job_name           => $jenkins_job_name,
    jenkins_request_timeout_ms => $jenkins_request_timeout_ms,
  }

  class { 'application::nginx':
    release_active        => $release_active,
    manage_package        => $manage_packages,
    manage_service        => $manage_service,
    manage_ownership      => $manage_ownership,
    manage_ipv6           => $manage_ipv6,
    nginx_service         => $nginx_service,
    conf_d_dir            => $conf_d_dir,
    sites_available_dir   => $sites_available_dir,
    sites_enabled_dir     => $sites_enabled_dir,
    site_name             => $nginx_site_name,
    www_dir               => $www_dir,
    maintenance_flag_file => $effective_maintenance_flag,
    listen_port           => $listen_port,
    nginx_verify_port     => $nginx_verify_port,
    backend_port          => $backend_port,
    nginx_bin             => $nginx_bin,
    nginx_configtest_cmd  => $nginx_configtest_cmd,
    systemctl_bin         => $systemctl_bin,
    service_provider      => $service_provider,
  }

  Class['application::nodejs']
  -> Class['application::release']
  -> Class['application::backend']

  if $release_active and $verify_health {
    $releases_dir = "${base_dir}/releases"
    $bin_dir = "${base_dir}/bin"
    $release_manager_path = "${bin_dir}/release_manager.py"
    $health_check_path = "${bin_dir}/health_check.py"
    $current_active_link = "${base_dir}/current"
    $backend_active_link = "${base_dir}/backend"
    $frontend_active_link = "${www_dir}/dist"

    $skip_proxy_flag = $verify_api_proxy ? {
      true    => '',
      default => ' --skip-api-proxy',
    }
    $consistency_flag = $verify_release_consistency ? {
      true    => " --expected-release '${release_version}'",
      default => '',
    }
    $exit_consistency_flag = $verify_release_consistency ? {
      true    => ' --verify-consistency',
      default => '',
    }
    $maint_flag_arg = $manage_maintenance ? {
      true    => " --maintenance-flag '${effective_maintenance_flag}'",
      default => '',
    }
    $sync_flag = $manage_service ? {
      true    => ' --require-service-synced',
      default => '',
    }
    $health_chown_flags = $manage_ownership ? {
      true    => " --chown --frontend-owner '${frontend_owner}' --frontend-group '${frontend_group}'",
      default => '',
    }
    $revert_service_flags = $manage_service ? {
      true    => " --restart-on-revert --systemctl-bin '${systemctl_bin}' --backend-service '${service_name}' --nginx-bin '${nginx_bin}' --nginx-service '${nginx_service}'",
      default => '',
    }
    $frontend_probe_port = $manage_maintenance ? {
      true    => $nginx_verify_port,
      default => $listen_port,
    }
    $known_good_check = "${python_bin} ${release_manager_path} is-known-good --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${maint_flag_arg}${sync_flag} --retain-releases ${retain_releases}"
    $promoted_check = "${python_bin} ${release_manager_path} is-promoted --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${sync_flag}"
    $maintenance_clear_check = "${python_bin} ${release_manager_path} is-maintenance-clear --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}' --maintenance-flag '${effective_maintenance_flag}'${sync_flag}"
    $pruned_check = "${python_bin} ${release_manager_path} is-pruned --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${maint_flag_arg}${sync_flag} --retain-releases ${retain_releases}"

    if $manage_service {
      $restart_sync_check = "${python_bin} ${release_manager_path} is-service-synced --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'"

      exec { 'app_sync_backend_restart':
        command => '/bin/true',
        unless  => $restart_sync_check,
        path    => ['/bin', '/usr/bin', '/sbin', '/sbin'],
        require => Class['application::release'],
        notify  => Service[$service_name],
        before  => Service[$service_name],
      }

      exec { 'app_mark_service_synced':
        command   => "${python_bin} ${release_manager_path} mark-service-synced --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}'",
        unless    => $restart_sync_check,
        path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
        logoutput => on_failure,
        require   => Service[$service_name],
        before    => Exec['app_verify_backend_health_gate'],
      }
    }

    exec { 'app_verify_backend_health_gate':
      command   => "${python_bin} ${release_manager_path} verify-health --mode backend --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${maint_flag_arg}${consistency_flag} --health-check-script '${health_check_path}' --python-bin '${python_bin}' --host '${health_host}' --port ${backend_port} --attempts ${health_attempts} --delay ${health_delay} --revert-on-fail${revert_service_flags}${health_chown_flags}",
      unless    => $known_good_check,
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => Class['application::backend'],
      before    => Class['application::nginx'],
    }

    exec { 'app_verify_frontend_health_gate':
      command   => "${python_bin} ${release_manager_path} verify-health --mode frontend --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${maint_flag_arg}${consistency_flag} --health-check-script '${health_check_path}' --python-bin '${python_bin}' --host '${health_host}' --port ${frontend_probe_port}${skip_proxy_flag} --attempts ${health_attempts} --delay ${health_delay} --revert-on-fail${revert_service_flags}${health_chown_flags}",
      unless    => $known_good_check,
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => [
        Class['application::nginx'],
        Exec['app_verify_backend_health_gate'],
      ],
    }

    exec { 'app_promote_release':
      command   => "${python_bin} ${release_manager_path} promote-release --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${sync_flag}",
      unless    => $promoted_check,
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => [
        Exec['app_verify_backend_health_gate'],
        Exec['app_verify_frontend_health_gate'],
      ],
    }

    if $manage_maintenance {
      exec { 'app_exit_maintenance':
        command   => "${python_bin} ${release_manager_path} exit-maintenance --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}' --maintenance-flag '${effective_maintenance_flag}' --health-check-script '${health_check_path}' --python-bin '${python_bin}' --host '${health_host}' --backend-port ${backend_port} --verify-port ${nginx_verify_port} --listen-port ${listen_port}${skip_proxy_flag}${exit_consistency_flag}${sync_flag} --attempts ${health_attempts} --delay ${health_delay}",
        unless    => $maintenance_clear_check,
        path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
        logoutput => on_failure,
        require   => Exec['app_promote_release'],
      }

      $prune_requires = [
        Exec['app_promote_release'],
        Exec['app_exit_maintenance'],
      ]
    } else {
      $prune_requires = [
        Exec['app_promote_release'],
      ]
    }

    exec { 'app_prune_releases':
      command   => "${python_bin} ${release_manager_path} prune-releases --version '${release_version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'${maint_flag_arg}${sync_flag} --retain-releases ${retain_releases}",
      unless    => $pruned_check,
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => $prune_requires,
    }

    if $manage_service {
      exec { 'app_verify_backend_health_refresh':
        command     => "${python_bin} ${health_check_path} backend --host '${health_host}' --port ${backend_port}${consistency_flag} --attempts ${health_attempts} --delay ${health_delay}",
        refreshonly => true,
        onlyif      => $known_good_check,
        path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
        logoutput   => on_failure,
        subscribe   => Service[$service_name],
        require     => Exec['app_verify_backend_health_gate'],
        before      => Class['application::nginx'],
      }

      $refresh_before = $manage_maintenance ? {
        true    => Exec['app_exit_maintenance'],
        default => Exec['app_promote_release'],
      }

      exec { 'app_verify_frontend_health_refresh':
        command     => "${python_bin} ${health_check_path} frontend --host '${health_host}' --port ${listen_port}${skip_proxy_flag}${consistency_flag} --attempts ${health_attempts} --delay ${health_delay}",
        refreshonly => true,
        onlyif      => $known_good_check,
        path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
        logoutput   => on_failure,
        subscribe   => Service[$nginx_service],
        require     => [
          Exec['app_verify_frontend_health_gate'],
          Exec['app_verify_backend_health_refresh'],
        ],
        before      => $refresh_before,
      }
    }
  } else {
    Class['application::backend']
    -> Class['application::nginx']
  }
}
