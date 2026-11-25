# ==============================================================================
# Class: application::nginx
# Purpose: Transfers steady-state NGINX ownership on EC2 2 to Puppet, deploys
#          the production SPA + /api/ reverse proxy virtual host, disables the
#          baseline default site on release activation, validates nginx -t, and
#          manages nginx.service without touching Apache (127.0.0.1:8080) or /nagios.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class application::nginx (
  Boolean                     $release_active        = false,
  Boolean                     $manage_package        = true,
  Boolean                     $manage_service        = true,
  Boolean                     $manage_ownership      = true,
  Boolean                     $manage_ipv6           = true,
  String[1]                   $nginx_package         = 'nginx',
  String[1]                   $nginx_service         = 'nginx',
  String[1]                   $conf_d_dir            = '/etc/nginx/conf.d',
  String[1]                   $sites_available_dir   = '/etc/nginx/sites-available',
  String[1]                   $sites_enabled_dir     = '/etc/nginx/sites-enabled',
  String[1]                   $site_name             = 'git-repo-analyzer',
  String[1]                   $www_dir               = '/var/www/git-repo-analyzer',
  String[1]                   $maintenance_flag_file = '/opt/git-repo-analyzer/maintenance.flag',
  Integer[1, 65535]           $listen_port           = 80,
  Optional[Integer[1, 65535]] $nginx_verify_port     = 8081,
  Integer[1, 65535]           $backend_port          = 3000,
  Enum['127.0.0.1']           $backend_host          = '127.0.0.1',
  String[1]                   $nginx_bin             = '/usr/sbin/nginx',
  Optional[String[1]]         $nginx_configtest_cmd  = undef,
  String[1]                   $systemctl_bin         = '/bin/systemctl',
  Enum['systemd', 'base']     $service_provider      = 'systemd',
) {
  if $maintenance_flag_file !~ /^\// or $maintenance_flag_file =~ /[\r\n\0"']/ {
    fail("Invalid application::nginx maintenance_flag_file '${maintenance_flag_file}': must be a safe absolute path")
  }

  if $nginx_verify_port != undef {
    if $nginx_verify_port == $listen_port or $nginx_verify_port == $backend_port or $nginx_verify_port == 8080 {
      fail("application::nginx nginx_verify_port (${nginx_verify_port}) must not collide with listen_port (${listen_port}), backend_port (${backend_port}), or Nagios loopback port 8080")
    }
  }
  $effective_configtest_cmd = $nginx_configtest_cmd ? {
    undef   => "${nginx_bin} -t",
    default => $nginx_configtest_cmd,
  }
  $frontend_active_link = "${www_dir}/dist"
  $site_conf_path = "${sites_available_dir}/${site_name}"
  $site_enabled_path = "${sites_enabled_dir}/${site_name}"
  $default_enabled_path = "${sites_enabled_dir}/default"
  $security_conf_path = "${conf_d_dir}/security.conf"

  $file_owner = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $file_group = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }

  if $manage_package and ! defined(Package[$nginx_package]) {
    package { $nginx_package:
      ensure => present,
    }
  }

  $pkg_require = $manage_package ? {
    true    => Package[$nginx_package],
    default => undef,
  }

  file { $security_conf_path:
    ensure  => file,
    owner   => $file_owner,
    group   => $file_group,
    mode    => '0644',
    content => "server_tokens off;\n",
    require => $pkg_require,
    notify  => Exec['app_nginx_configtest'],
  }

  file { $site_conf_path:
    ensure  => file,
    owner   => $file_owner,
    group   => $file_group,
    mode    => '0644',
    content => template('application/nginx_git_repo_analyzer.conf.erb'),
    require => $pkg_require,
    notify  => Exec['app_nginx_configtest'],
  }

  if $release_active {
    file { $site_enabled_path:
      ensure  => link,
      target  => $site_conf_path,
      require => File[$site_conf_path],
      notify  => Exec['app_nginx_configtest'],
    }

    file { $default_enabled_path:
      ensure  => absent,
      require => $pkg_require,
      notify  => Exec['app_nginx_configtest'],
    }
  }

  $service_notify = ($manage_service and $release_active) ? {
    true    => Service[$nginx_service],
    default => undef,
  }

  $nginx_configtest_subscribes = ($release_active and defined(Exec['app_activate_release'])) ? {
    true    => Exec['app_activate_release'],
    default => undef,
  }

  exec { 'app_nginx_configtest':
    command     => $effective_configtest_cmd,
    refreshonly => true,
    onlyif      => "/usr/bin/test -x '${nginx_bin}'",
    path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    logoutput   => on_failure,
    subscribe   => $nginx_configtest_subscribes,
    notify      => $service_notify,
  }

  if $manage_service {
    exec { 'app_nginx_configtest_before_start':
      command   => $effective_configtest_cmd,
      onlyif    => "/usr/bin/test -x '${nginx_bin}'",
      unless    => "${systemctl_bin} is-active --quiet '${nginx_service}'",
      path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
      logoutput => on_failure,
      require => [
        File[$security_conf_path],
        File[$site_conf_path],
      ],
      before  => Service[$nginx_service],
    }

    if $service_provider == 'systemd' {
      service { $nginx_service:
        ensure     => running,
        enable     => true,
        provider   => 'systemd',
        hasstatus  => true,
        hasrestart => true,
        require    => [
          Exec['app_nginx_configtest'],
          Exec['app_nginx_configtest_before_start'],
        ],
      }
    } else {
      service { $nginx_service:
        ensure   => running,
        provider => 'base',
        status   => "${systemctl_bin} is-active '${nginx_service}'",
        start    => "${systemctl_bin} start '${nginx_service}'",
        stop     => "${systemctl_bin} stop '${nginx_service}'",
        restart  => "${systemctl_bin} reload '${nginx_service}'",
        require  => [
          Exec['app_nginx_configtest'],
          Exec['app_nginx_configtest_before_start'],
        ],
      }
    }

    if $release_active {
      File[$site_enabled_path] -> Exec['app_nginx_configtest_before_start']
      File[$default_enabled_path] -> Exec['app_nginx_configtest_before_start']
    }
  }
}
