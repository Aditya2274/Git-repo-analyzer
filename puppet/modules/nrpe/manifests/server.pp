# ==============================================================================
# Class: nrpe::server
# Purpose: Installs and manages nagios-nrpe-server on monitored target nodes.
# ==============================================================================
class nrpe::server (
  String[1]        $package_name    = 'nagios-nrpe-server',
  String[1]        $service_name    = 'nagios-nrpe-server',
  Array[String[1]] $plugin_packages = ['monitoring-plugins-basic'],
  Integer[1,65535] $server_port     = 5666,
  Array[String[1]] $allowed_hosts   = ['127.0.0.1', '::1', 'puppet-server', 'app-server'],
  Integer[0, 1]    $dont_blame_nrpe = 0,
) {
  package { $package_name:
    ensure => present,
  }

  package { $plugin_packages:
    ensure => present,
  }

  service { $service_name:
    ensure     => running,
    enable     => true,
    hasstatus  => true,
    hasrestart => true,
    require    => Package[$package_name],
  }
}
