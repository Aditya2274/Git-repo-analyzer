# ==============================================================================
# Class: nagios::server
# Purpose: Installs Nagios Core packages and manages the nagios4 service daemon.
# ==============================================================================
class nagios::server (
  String[1]        $package_name    = 'nagios4',
  String[1]        $service_name    = 'nagios4',
  Array[String[1]] $plugin_packages = [
    'monitoring-plugins-basic',
  ],
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
