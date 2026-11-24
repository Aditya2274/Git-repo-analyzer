# ==============================================================================
# Class: nagios::server
# Purpose: Installs Nagios Core packages without premature startup, manages
#          authoritative configuration, validates config, and manages nagios4.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios::server (
  String[1]        $package_name    = 'nagios4',
  String[1]        $service_name    = 'nagios4',
  Array[String[1]] $plugin_packages = [
    'monitoring-plugins-basic',
  ],
  String[1]        $config_dir      = '/etc/nagios4',
  String[1]        $conf_d_dir      = '/etc/nagios4/conf.d',
  String[1]        $admin_user      = 'nagiosadmin',
  Boolean          $manage_service  = true,
) {
  if ! defined(Class['nagios::install_guard']) {
    class { 'nagios::install_guard':
      target_packages => [$package_name] + $plugin_packages,
    }
  }

  package { $package_name:
    ensure  => present,
    require => Exec['nagios_enable_policy_rc_d'],
  }

  package { $plugin_packages:
    ensure  => present,
    require => Exec['nagios_enable_policy_rc_d'],
  }

  Exec['nagios_enable_policy_rc_d']
  -> Package[$package_name]
  -> Exec['nagios_disable_policy_rc_d']

  Exec['nagios_enable_policy_rc_d']
  -> Package[$plugin_packages]
  -> Exec['nagios_disable_policy_rc_d']

  file { $config_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0755',
    require => [
      Package[$package_name],
      Exec['nagios_disable_policy_rc_d'],
    ],
  }

  file { "${config_dir}/nagios.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/nagios.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/cgi.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/cgi.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/resource.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0640',
    content => template('nagios/resource.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  contain nagios::objects

  Package[$package_name]
  -> Exec['nagios_disable_policy_rc_d']
  -> File[$config_dir]
  -> [
    File["${config_dir}/nagios.cfg"],
    File["${config_dir}/cgi.cfg"],
    File["${config_dir}/resource.cfg"],
  ]
  -> Class['nagios::objects']
  -> Exec['nagios4_configtest']
  -> Service[$service_name]

  # Pre-reload configuration validation (runs whenever managed Nagios files change)
  exec { 'nagios4_configtest':
    command     => '/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg',
    path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    refreshonly => true,
    onlyif      => '/usr/bin/test -x /usr/sbin/nagios4',
    notify      => Service[$service_name],
  }

  # Pre-start safety gate: ensures validation ALWAYS runs whenever nagios4
  # is currently inactive (e.g., first install or retry after failed configtest).
  if $manage_service {
    exec { 'nagios4_configtest_before_start':
      command => '/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg',
      path    => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
      onlyif  => '/usr/bin/test -x /usr/sbin/nagios4',
      unless  => "/usr/bin/systemctl is-active --quiet ${service_name}",
      require => [
        File["${config_dir}/nagios.cfg"],
        File["${config_dir}/cgi.cfg"],
        File["${config_dir}/resource.cfg"],
        Class['nagios::objects'],
      ],
      before  => Service[$service_name],
    }
  }

  $service_ensure = $manage_service ? {
    true    => 'running',
    default => undef,
  }

  $base_service_require = [
    Package[$package_name],
    Exec['nagios_disable_policy_rc_d'],
    File["${config_dir}/nagios.cfg"],
    File["${config_dir}/cgi.cfg"],
    File["${config_dir}/resource.cfg"],
    Exec['nagios4_configtest'],
  ]

  $service_require = $manage_service ? {
    true    => $base_service_require + [Exec['nagios4_configtest_before_start']],
    default => $base_service_require,
  }

  service { $service_name:
    ensure     => $service_ensure,
    enable     => $manage_service,
    hasstatus  => true,
    hasrestart => true,
    require    => $service_require,
  }
}
