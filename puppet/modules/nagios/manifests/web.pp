# ==============================================================================
# Class: nagios::web
# Purpose: Configures Apache loopback virtual host (127.0.0.1:8080) and HTTP
#          Basic Authentication for Nagios Core administration.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios::web (
  String[1]        $apache_package             = 'apache2',
  String[1]        $apache_service             = 'apache2',
  Array[String[1]] $utils_packages             = ['apache2-utils'],
  Integer[1,65535] $listen_port                = 8080,
  String[1]        $bind_address               = '127.0.0.1',
  String[1]        $admin_user                 = 'nagiosadmin',
  String[1]        $admin_password_hash        = '$apr1$demo$hashedpassword',
  String[1]        $htpasswd_file              = '/etc/nagios4/htpasswd.users',
  Boolean          $manage_service             = true,
  Boolean          $enforce_production_secret  = false,
) {
  # Secret guardrails
  if $enforce_production_secret and $admin_password_hash == '$apr1$demo$hashedpassword' {
    fail("Production deployment rejected: nagios::web::admin_password_hash contains the insecure placeholder credential. Supply an authentic password hash.")
  }

  if $admin_password_hash == '$apr1$demo$hashedpassword' {
    notify { 'nagios_placeholder_credential_warning':
      message  => 'SECURITY WARNING: Nagios web admin is configured with a demo/placeholder password hash. Replace nagios::web::admin_password_hash with a secure hash before production deployment.',
      loglevel => 'warning',
    }
  }

  package { $apache_package:
    ensure => present,
  }

  package { $utils_packages:
    ensure => present,
  }

  if ! defined(File['/etc/nagios4']) {
    file { '/etc/nagios4':
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
  }

  # Ensure Apache listens strictly on loopback port
  file { '/etc/apache2/ports.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('nagios/ports.conf.erb'),
    require => Package[$apache_package],
    notify  => Exec['apache2_configtest'],
  }

  # Deploy Nagios loopback virtual host
  file { '/etc/apache2/sites-available/nagios.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('nagios/apache_nagios.conf.erb'),
    require => Package[$apache_package],
    notify  => Exec['apache2_configtest'],
  }

  # Enable Nagios site
  file { '/etc/apache2/sites-enabled/nagios.conf':
    ensure  => link,
    target  => '/etc/apache2/sites-available/nagios.conf',
    require => File['/etc/apache2/sites-available/nagios.conf'],
    notify  => Exec['apache2_configtest'],
  }

  # Disable default Apache site to prevent port or document root conflicts
  file { '/etc/apache2/sites-enabled/000-default.conf':
    ensure  => absent,
    require => Package[$apache_package],
    notify  => Exec['apache2_configtest'],
  }

  # Deploy htpasswd file with strict permissions (0640, root:www-data)
  file { $htpasswd_file:
    ensure  => file,
    owner   => 'root',
    group   => 'www-data',
    mode    => '0640',
    content => "${admin_user}:${admin_password_hash}\n",
    require => [
      Package[$apache_package],
      File['/etc/nagios4'],
    ],
    notify  => Exec['apache2_configtest'],
  }

  # Pre-start Apache configuration validation
  exec { 'apache2_configtest':
    command     => '/usr/sbin/apache2ctl configtest',
    path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    refreshonly => true,
    onlyif      => '/usr/bin/test -x /usr/sbin/apache2ctl',
    notify      => Service[$apache_service],
    before      => Service[$apache_service],
  }

  $service_ensure = $manage_service ? {
    true    => 'running',
    default => undef,
  }

  service { $apache_service:
    ensure     => $service_ensure,
    enable     => $manage_service,
    hasstatus  => true,
    hasrestart => true,
    require    => [
      Package[$apache_package],
      File['/etc/apache2/ports.conf'],
      File['/etc/apache2/sites-available/nagios.conf'],
      File[$htpasswd_file],
      Exec['apache2_configtest'],
    ],
  }
}
