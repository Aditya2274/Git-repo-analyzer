# ==============================================================================
# Class: application::backend
# Purpose: Provisions dedicated gitrepo system account, persistent analysis
#          DATA_DIR, hardened /etc/git-repo-analyzer/backend.env (0640),
#          systemd service unit, and managed backend service lifecycle.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class application::backend (
  Boolean                               $release_active              = false,
  Boolean                               $manage_users                = true,
  Boolean                               $manage_ownership            = true,
  Boolean                               $manage_service              = true,
  String[1]                             $backend_user                = 'gitrepo',
  String[1]                             $backend_group               = 'gitrepo',
  String[1]                             $base_dir                    = '/opt/git-repo-analyzer',
  String[1]                             $data_base_dir               = '/var/lib/git-repo-analyzer',
  String[1]                             $data_dir                    = '/var/lib/git-repo-analyzer/data',
  String[1]                             $env_dir                     = '/etc/git-repo-analyzer',
  String[1]                             $env_file                    = '/etc/git-repo-analyzer/backend.env',
  String[1]                             $systemd_unit_path           = '/etc/systemd/system/git-repo-analyzer-backend.service',
  String[1]                             $service_name                = 'git-repo-analyzer-backend',
  String[1]                             $node_bin                    = '/usr/bin/node',
  String[1]                             $systemctl_bin               = '/bin/systemctl',
  Enum['systemd', 'base']               $service_provider            = 'systemd',
  Enum['production', 'development', 'test'] $node_env                = 'production',
  Integer[1, 65535]                     $port                        = 3000,
  Enum['127.0.0.1', '::1', 'localhost'] $host                        = '127.0.0.1',
  String                                $cors_origin                 = '',
  Boolean                               $enforce_production_cors     = true,
  Boolean                               $ssrf_check_dns              = true,
  Integer[5000, 3600000]                $analysis_timeout_ms         = 600000,
  Integer[10, 60000]                    $poll_interval_ms            = 1500,
  Boolean                               $jenkins_mock_mode           = true,
  String                                $jenkins_url                 = '',
  String                                $jenkins_user                = '',
  Variant[Sensitive[String], String]    $jenkins_api_token           = '',
  Pattern[/^[A-Za-z0-9._-]+$/]         $jenkins_job_name            = 'git-repo-analyzer',
  Integer[500, 60000]                   $jenkins_request_timeout_ms  = 5000,
) {
  if $node_env == 'production' and !$ssrf_check_dns {
    fail('application::backend requires SSRF_CHECK_DNS=true when NODE_ENV=production')
  }

  $raw_jenkins_api_token = $jenkins_api_token =~ Sensitive ? {
    true    => $jenkins_api_token.unwrap,
    default => $jenkins_api_token,
  }

  [
    $cors_origin,
    $jenkins_url,
    $jenkins_user,
    $raw_jenkins_api_token,
    $jenkins_job_name,
    $data_base_dir,
    $data_dir,
    $env_dir,
    $env_file,
    $systemd_unit_path,
  ].each |$val| {
    if $val =~ /[\r\n\0]/ {
      fail('application::backend environment values must not contain CR/LF or NUL characters')
    }
  }

  [
    $data_base_dir,
    $data_dir,
    $env_dir,
    $env_file,
    $systemd_unit_path,
  ].each |$abs_path| {
    if $abs_path !~ /^\// {
      fail("application::backend path '${abs_path}' must be an absolute path")
    }
  }

  $trimmed_cors_input = strip($cors_origin)
  if $cors_origin != '' {
    if $trimmed_cors_input == '' or $trimmed_cors_input =~ /(?:^,|,$|,,)/ {
      fail("Invalid application::backend cors_origin '${cors_origin}': empty origin entry or stray comma is not permitted")
    }
    $normalized_cors_list = split($trimmed_cors_input, ',').map |$raw_origin| {
      $trimmed_origin = strip($raw_origin)
      if $trimmed_origin !~ /^https?:\/\/[A-Za-z0-9][A-Za-z0-9.\-]*(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?$/ {
        fail("Invalid application::backend cors_origin entry '${trimmed_origin}': expected comma-separated http/https origins with valid ports (1-65535) and no path/query/fragment/credentials/wildcard")
      }
      $trimmed_origin
    }
    $normalized_cors_origin = join($normalized_cors_list, ',')
  } else {
    $normalized_cors_origin = ''
  }

  if $release_active and $node_env == 'production' and $enforce_production_cors and $normalized_cors_origin == '' {
    fail('application::backend requires non-empty cors_origin when release_active is true in production (same-origin browser POST requests send an Origin header; set enforce_production_cors => false only for non-browser loopback testing)')
  }

  if $jenkins_url != '' and $jenkins_url !~ /^https?:\/\/[A-Za-z0-9][A-Za-z0-9.\-]*(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(?:\/[^\s]*)?$/ {
    fail("Invalid application::backend jenkins_url '${jenkins_url}': expected valid http or https URL")
  }

  if !$jenkins_mock_mode {
    if $jenkins_url == '' or $jenkins_user == '' or $raw_jenkins_api_token == '' {
      fail('application::backend requires jenkins_url, jenkins_user, and jenkins_api_token when jenkins_mock_mode is false')
    }
    if $raw_jenkins_api_token =~ /(?i)(CHANGE_ME|PLACEHOLDER|DUMMY|TODO|your[-_]?(jenkins[-_]?)?token)/ {
      fail('application::backend rejected placeholder jenkins_api_token in live Jenkins mode')
    }
  }

  $backend_active_link = "${base_dir}/backend"

  $dir_root_owner = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $dir_data_owner = $manage_ownership ? {
    true    => $backend_user,
    default => undef,
  }
  $dir_group = $manage_ownership ? {
    true    => $backend_group,
    default => undef,
  }
  $root_group = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }

  if $manage_users {
    group { $backend_group:
      ensure => present,
      system => true,
    }

    user { $backend_user:
      ensure     => present,
      gid        => $backend_group,
      system     => true,
      home       => '/nonexistent',
      managehome => false,
      shell      => '/usr/sbin/nologin',
      comment    => 'Git Repository Analyzer Backend Service',
      require    => Group[$backend_group],
    }

    $user_require = [Group[$backend_group], User[$backend_user]]
  } else {
    $user_require = undef
  }

  file { $data_base_dir:
    ensure  => directory,
    owner   => $dir_root_owner,
    group   => $dir_group,
    mode    => '0750',
    require => $user_require,
  }

  file { $data_dir:
    ensure  => directory,
    owner   => $dir_data_owner,
    group   => $dir_group,
    mode    => '0750',
    require => File[$data_base_dir],
  }

  file { $env_dir:
    ensure  => directory,
    owner   => $dir_root_owner,
    group   => $dir_group,
    mode    => '0750',
    require => $user_require,
  }

  file { $env_file:
    ensure    => file,
    owner     => $dir_root_owner,
    group     => $dir_group,
    mode      => '0640',
    show_diff => false,
    content   => template('application/backend.env.erb'),
    require   => File[$env_dir],
  }

  $systemd_unit_notify = $manage_service ? {
    true    => Exec['app_systemd_daemon_reload'],
    default => undef,
  }

  file { $systemd_unit_path:
    ensure  => file,
    owner   => $dir_root_owner,
    group   => $root_group,
    mode    => '0644',
    content => template('application/git-repo-analyzer-backend.service.erb'),
    notify  => $systemd_unit_notify,
  }

  if $manage_service {
    exec { 'app_systemd_daemon_reload':
      command     => "${systemctl_bin} daemon-reload",
      refreshonly => true,
      path        => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }

    if $release_active {
      exec { 'app_verify_backend_entrypoint':
        command => "/bin/sh -c 'echo \"Missing backend entrypoint at ${backend_active_link}/dist/server.js\" >&2; exit 1'",
        unless  => "/usr/bin/test -f '${backend_active_link}/dist/server.js'",
        path    => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      }

      $backend_subscribes = defined(Exec['app_activate_release']) ? {
        true    => [
          File[$env_file],
          File[$systemd_unit_path],
          Exec['app_activate_release'],
        ],
        default => [
          File[$env_file],
          File[$systemd_unit_path],
        ],
      }

      if $service_provider == 'systemd' {
        service { $service_name:
          ensure     => running,
          enable     => true,
          provider   => 'systemd',
          hasstatus  => true,
          hasrestart => true,
          require    => [
            File[$data_dir],
            File[$env_file],
            File[$systemd_unit_path],
            Exec['app_systemd_daemon_reload'],
            Exec['app_verify_backend_entrypoint'],
          ],
          subscribe  => $backend_subscribes,
        }
      } else {
        service { $service_name:
          ensure    => running,
          provider  => 'base',
          status    => "${systemctl_bin} is-active '${service_name}'",
          start     => "${systemctl_bin} start '${service_name}'",
          stop      => "${systemctl_bin} stop '${service_name}'",
          restart   => "${systemctl_bin} restart '${service_name}'",
          require   => [
            File[$data_dir],
            File[$env_file],
            File[$systemd_unit_path],
            Exec['app_systemd_daemon_reload'],
            Exec['app_verify_backend_entrypoint'],
          ],
          subscribe => $backend_subscribes,
        }
      }

      Exec['app_systemd_daemon_reload'] ~> Service[$service_name]
    } else {
      if $service_provider == 'systemd' {
        service { $service_name:
          ensure   => stopped,
          enable   => false,
          provider => 'systemd',
          require  => [
            File[$systemd_unit_path],
            Exec['app_systemd_daemon_reload'],
          ],
        }
      } else {
        service { $service_name:
          ensure   => stopped,
          provider => 'base',
          status   => "${systemctl_bin} is-active '${service_name}'",
          start    => "${systemctl_bin} start '${service_name}'",
          stop     => "${systemctl_bin} stop '${service_name}'",
          restart  => "${systemctl_bin} restart '${service_name}'",
          require  => [
            File[$systemd_unit_path],
            Exec['app_systemd_daemon_reload'],
          ],
        }
      }
    }
  }
}
