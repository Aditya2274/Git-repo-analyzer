# ==============================================================================
# Class: common
# Purpose: Baseline system configuration and steady-state Puppet Agent service
#          management across all three EC2 nodes in the fleet.
# Fleet Targets:
#   1. puppet-server (EC2 1) - Baseline packages, timezone, and local puppet agent
#   2. app-server    (EC2 2) - Baseline packages, timezone, and local puppet agent
#   3. cicd-server   (EC2 3) - Baseline packages, timezone, and local puppet agent
# Handover Boundary:
#   - Ansible bootstraps OS, swap, hosts, and performs Phase 4.5 CA enrollment.
#   - Puppet common module assumes exclusive steady-state desired-state ownership
#     of packages, timezone, and the 'puppet' service (without touching 'puppetserver').
# ==============================================================================
class common (
  Array[String[1]] $packages             = [
    'curl',
    'wget',
    'git',
    'htop',
    'unzip',
    'tar',
    'jq',
    'ca-certificates',
  ],
  String[1]        $timezone             = 'UTC',
  Boolean          $manage_puppet_agent  = true,
  String[1]        $puppet_agent_service = 'puppet',
) {
  # 1. Base package baseline (declarative state)
  package { $packages:
    ensure => present,
  }

  # 2. Timezone configuration (/etc/timezone and /etc/localtime symlink)
  file { '/etc/timezone':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "${timezone}\n",
    require => Package[$packages],
  }

  file { '/etc/localtime':
    ensure  => link,
    target  => "/usr/share/zoneinfo/${timezone}",
    force   => true,
    require => File['/etc/timezone'],
  }

  # 3. Steady-State Puppet Agent Service Management
  # Following successful Checkpoint 4.5 enrollment and handover, Puppet assumes
  # exclusive steady-state ownership of its own daemon ('puppet.service').
  # On puppet-server, this manages the local agent daemon alongside puppetserver.service
  # without modifying or restarting the Clojure/JVM puppet master daemon.
  if $manage_puppet_agent {
    service { $puppet_agent_service:
      ensure     => running,
      enable     => true,
      hasstatus  => true,
      hasrestart => true,
      require    => File['/etc/localtime'],
    }
  }
}
