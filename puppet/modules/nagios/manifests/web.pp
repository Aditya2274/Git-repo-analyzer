# ==============================================================================
# Class: nagios::web
# Purpose: Configures Apache loopback virtual host (127.0.0.1:8080) and basic auth.
# ==============================================================================
class nagios::web (
  String[1]        $apache_package  = 'apache2',
  String[1]        $apache_service  = 'apache2',
  Array[String[1]] $utils_packages  = ['apache2-utils'],
  Integer[1,65535] $listen_port     = 8080,
  String[1]        $bind_address    = '127.0.0.1',
  String[1]        $admin_user      = 'nagiosadmin',
  String[1]        $htpasswd_file   = '/etc/nagios4/htpasswd.users',
) {
  package { $apache_package:
    ensure => present,
  }

  package { $utils_packages:
    ensure => present,
  }

  service { $apache_service:
    ensure     => running,
    enable     => true,
    hasstatus  => true,
    hasrestart => true,
    require    => Package[$apache_package],
  }
}
