# ==============================================================================
# Class: nagios::server
# Purpose: Installs Nagios Core packages, manages authoritative configuration,
#          and manages the nagios4 service daemon with pre-start validation.
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
  package { $package_name:
    ensure => present,
  }

  package { $plugin_packages:
    ensure => present,
  }

  file { $config_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0755',
    require => Package[$package_name],
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
  -> File[$config_dir]
  -> Class['nagios::objects']
  -> Exec['nagios4_configtest']
  -> Service[$service_name]

  # Pre-start and pre-reload configuration validation
  exec { 'nagios4_configtest':
    command     => '/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg',
    path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    refreshonly => true,
    onlyif      => '/usr/bin/test -x /usr/sbin/nagios4',
    notify      => Service[$service_name],
  }

  $service_ensure = $manage_service ? {
    true    => 'running',
    default => undef,
  }

  service { $service_name:
    ensure     => $service_ensure,
    enable     => $manage_service,
    hasstatus  => true,
    hasrestart => true,
    require    => [
      Package[$package_name],
      File["${config_dir}/nagios.cfg"],
      File["${config_dir}/cgi.cfg"],
      File["${config_dir}/resource.cfg"],
      Exec['nagios4_configtest'],
    ],
  }
}
