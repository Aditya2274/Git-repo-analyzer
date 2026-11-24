# ==============================================================================
# Class: nrpe::server
# Purpose: Installs, configures, and manages nagios-nrpe-server on monitored target nodes.
# Fleet Targets:
#   - Node 1: puppet-server (Dedicated Puppet Server & CA) -> check_puppetserver
#   - Node 3: cicd-server   (CI/CD Pipeline & Docker Host) -> check_jenkins, check_docker
# Note: Nagios Core runs exclusively on app-server; monitored nodes run nrpe::server.
# ==============================================================================
class nrpe::server (
  String[1]                            $package_name       = 'nagios-nrpe-server',
  String[1]                            $service_name       = 'nagios-nrpe-server',
  Enum['running', 'stopped']           $service_ensure     = 'running',
  Boolean                              $service_enable     = true,
  Array[String[1]]                     $plugin_packages    = ['monitoring-plugins-basic'],
  String[1]                            $config_file        = '/etc/nagios/nrpe.cfg',
  String[1]                            $include_dir        = '/etc/nagios/nrpe.d',
  String[1]                            $pid_file           = '/run/nagios/nrpe.pid',
  String[1]                            $nrpe_user          = 'nagios',
  String[1]                            $nrpe_group         = 'nagios',
  Integer[1, 65535]                    $server_port        = 5666,
  Optional[String[1]]                  $server_address     = undef,
  Array[String[1]]                     $allowed_hosts      = ['127.0.0.1', '::1', 'app-server'],
  Integer[0, 1]                        $dont_blame_nrpe    = 0,
  Integer[1, 3600]                     $command_timeout    = 60,
  Integer[1, 3600]                     $connection_timeout = 300,
  Optional[Hash[String[1], String[1]]] $commands           = undef,
  Optional[Array[String[1]]]           $custom_plugins     = undef,
) {
  # ----------------------------------------------------------------------------
  # 1. Command & Custom Plugin Node Targeting
  # ----------------------------------------------------------------------------
  # Baseline system monitoring checks common to all monitored fleet nodes
  $base_commands = {
    'check_users'        => '/usr/lib/nagios/plugins/check_users -w 5 -c 10',
    'check_load'         => '/usr/lib/nagios/plugins/check_load -r -w .15,.10,.05 -c .30,.25,.20',
    'check_disk'         => '/usr/lib/nagios/plugins/check_disk -w 20% -c 10% -p /',
    'check_zombie_procs' => '/usr/lib/nagios/plugins/check_procs -w 5 -c 10 -s Z',
    'check_total_procs'  => '/usr/lib/nagios/plugins/check_procs -w 150 -c 200',
  }

  # Node-specific checks: assign check_puppetserver only to puppet-server,
  # and check_jenkins/check_docker only to cicd-server
  case $trusted['certname'] {
    'puppet-server': {
      $default_node_commands = {
        'check_puppetserver' => '/usr/lib/nagios/plugins/check_puppetserver.sh',
      }
      $default_plugins = ['check_puppetserver.sh']
    }
    'cicd-server': {
      $default_node_commands = {
        'check_jenkins' => '/usr/lib/nagios/plugins/check_jenkins.sh',
        'check_docker'  => '/usr/lib/nagios/plugins/check_docker.sh',
      }
      $default_plugins = ['check_jenkins.sh', 'check_docker.sh']
    }
    default: {
      # Unrecognized certname: no node-specific custom checks are assigned by default.
      # Only baseline system checks are configured unless explicitly overridden via parameters.
      $default_node_commands = {}
      $default_plugins       = []
    }
  }

  $effective_commands = $commands ? {
    undef   => $base_commands + $default_node_commands,
    default => $commands,
  }

  $effective_plugins = $custom_plugins ? {
    undef   => $default_plugins,
    default => $custom_plugins,
  }

  # ----------------------------------------------------------------------------
  # 2. Package Installation
  # ----------------------------------------------------------------------------
  package { $package_name:
    ensure => present,
  }

  package { $plugin_packages:
    ensure => present,
  }

  # ----------------------------------------------------------------------------
  # 3. Directory Structure Setup
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
  # 4. Custom Monitoring Check Scripts (Targeted Node Deployment)
  # ----------------------------------------------------------------------------
  if 'check_jenkins.sh' in $effective_plugins {
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
      before  => Service[$service_name],
    }
  }

  if 'check_docker.sh' in $effective_plugins {
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
      before  => Service[$service_name],
    }
  }

  if 'check_puppetserver.sh' in $effective_plugins {
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
      before  => Service[$service_name],
    }
  }

  # ----------------------------------------------------------------------------
  # 5. Authoritative NRPE Configuration File (/etc/nagios/nrpe.cfg)
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
  # 6. Service Management
  # ----------------------------------------------------------------------------
  service { $service_name:
    ensure     => $service_ensure,
    enable     => $service_enable,
    hasstatus  => true,
    hasrestart => true,
    require    => [
      Package[$package_name],
      Package[$plugin_packages],
      File[$config_file],
    ],
  }
}
