# ==============================================================================
# Class: nrpe::server
# Purpose: Installs, configures, and manages nagios-nrpe-server on monitored target nodes.
# Fleet Targets:
#   - Node 1: puppet-server (Dedicated Puppet Server & CA)
#   - Node 3: cicd-server   (CI/CD Pipeline & Docker Analysis Host)
# Note: Nagios Core runs exclusively on app-server; monitored nodes run nrpe::server.
# ==============================================================================
class nrpe::server (
  String[1]                  $package_name       = 'nagios-nrpe-server',
  String[1]                  $service_name       = 'nagios-nrpe-server',
  Array[String[1]]           $plugin_packages    = ['monitoring-plugins-basic'],
  String[1]                  $config_file        = '/etc/nagios/nrpe.cfg',
  String[1]                  $include_dir        = '/etc/nagios/nrpe.d',
  String[1]                  $pid_file           = '/run/nagios/nrpe.pid',
  String[1]                  $nrpe_user          = 'nagios',
  String[1]                  $nrpe_group         = 'nagios',
  Integer[1, 65535]          $server_port        = 5666,
  Optional[String[1]]        $server_address     = undef,
  Array[String[1]]           $allowed_hosts      = ['127.0.0.1', '::1', 'app-server'],
  Integer[0, 1]              $dont_blame_nrpe    = 0,
  Integer[1, 3600]           $command_timeout    = 60,
  Integer[1, 3600]           $connection_timeout = 300,
  Hash[String[1], String[1]] $commands           = {
    'check_users'        => '/usr/lib/nagios/plugins/check_users -w 5 -c 10',
    'check_load'         => '/usr/lib/nagios/plugins/check_load -r -w .15,.10,.05 -c .30,.25,.20',
    'check_disk'         => '/usr/lib/nagios/plugins/check_disk -w 20% -c 10% -p /',
    'check_zombie_procs' => '/usr/lib/nagios/plugins/check_procs -w 5 -c 10 -s Z',
    'check_total_procs'  => '/usr/lib/nagios/plugins/check_procs -w 150 -c 200',
    'check_puppetserver' => '/usr/lib/nagios/plugins/check_puppetserver.sh',
    'check_jenkins'      => '/usr/lib/nagios/plugins/check_jenkins.sh',
    'check_docker'       => '/usr/lib/nagios/plugins/check_docker.sh',
  },
) {
  # ----------------------------------------------------------------------------
  # 1. Package Installation
  # ----------------------------------------------------------------------------
  package { $package_name:
    ensure => present,
  }

  package { $plugin_packages:
    ensure => present,
  }

  # ----------------------------------------------------------------------------
  # 2. Directory Structure Setup
  # ----------------------------------------------------------------------------
  if ! defined(File['/etc/nagios']) {
    file { '/etc/nagios':
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      require => Package[$package_name],
    }
  }

  if ! defined(File[$include_dir]) {
    file { $include_dir:
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      require => File['/etc/nagios'],
    }
  }

  if ! defined(File['/usr/lib/nagios/plugins']) {
    file { '/usr/lib/nagios/plugins':
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      require => Package[$plugin_packages],
    }
  }

  # ----------------------------------------------------------------------------
  # 3. Custom Monitoring Check Scripts
  # ----------------------------------------------------------------------------
  file { '/usr/lib/nagios/plugins/check_jenkins.sh':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    source  => 'puppet:///modules/nrpe/check_jenkins.sh',
    require => [
      File['/usr/lib/nagios/plugins'],
      Package[$plugin_packages],
    ],
  }

  file { '/usr/lib/nagios/plugins/check_docker.sh':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    source  => 'puppet:///modules/nrpe/check_docker.sh',
    require => [
      File['/usr/lib/nagios/plugins'],
      Package[$plugin_packages],
    ],
  }

  file { '/usr/lib/nagios/plugins/check_puppetserver.sh':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    source  => 'puppet:///modules/nrpe/check_puppetserver.sh',
    require => [
      File['/usr/lib/nagios/plugins'],
      Package[$plugin_packages],
    ],
  }

  # ----------------------------------------------------------------------------
  # 4. Authoritative NRPE Configuration File (/etc/nagios/nrpe.cfg)
  # ----------------------------------------------------------------------------
  file { $config_file:
    ensure       => file,
    owner        => 'root',
    group        => 'root',
    mode         => '0644',
    content      => template('nrpe/nrpe.cfg.erb'),
    validate_cmd => '/usr/bin/awk \'/^[[:space:]]*(#|$)/ {next} /=/ {found++; next} {exit 1} END {exit (found >= 5 ? 0 : 1)}\' %',
    require      => [
      Package[$package_name],
      File['/etc/nagios'],
      File[$include_dir],
    ],
    notify       => Service[$service_name],
  }

  # ----------------------------------------------------------------------------
  # 5. Service Management
  # ----------------------------------------------------------------------------
  service { $service_name:
    ensure     => running,
    enable     => true,
    hasstatus  => true,
    hasrestart => true,
    require    => [
      Package[$package_name],
      File[$config_file],
    ],
  }
}
