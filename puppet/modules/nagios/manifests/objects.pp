# ==============================================================================
# Class: nagios::objects
# Purpose: Manages host, service, command, and contact definitions for Nagios.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios::objects (
  String[1]        $config_dir          = '/etc/nagios4/conf.d',
  Integer[1, 300]  $check_nrpe_timeout  = 30,
  String[1]        $contact_email       = 'root@localhost',
) {
  file { $config_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0755',
    require => Package['nagios4'],
  }

  file { "${config_dir}/timeperiods.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/objects/timeperiods.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/commands.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/objects/commands.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/contacts.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/objects/contacts.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/hosts.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/objects/hosts.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }

  file { "${config_dir}/services.cfg":
    ensure  => file,
    owner   => 'root',
    group   => 'nagios',
    mode    => '0644',
    content => template('nagios/objects/services.cfg.erb'),
    require => File[$config_dir],
    notify  => Exec['nagios4_configtest'],
  }
}
