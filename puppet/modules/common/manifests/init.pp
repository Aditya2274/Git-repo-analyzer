# ==============================================================================
# Class: common
# Purpose: Baseline system configuration and steady-state Puppet Agent service
#          management across all three EC2 nodes in the fleet.
# ==============================================================================
class common (
  Array[String[1]] $packages             = [
    'curl',
    'git',
    'htop',
    'unzip',
    'tar',
    'jq',
  ],
  String[1]        $timezone             = 'UTC',
  Boolean          $manage_puppet_agent  = true,
  String[1]        $puppet_agent_service = 'puppet',
) {
  # Base package baseline (declarative state)
  package { $packages:
    ensure => present,
  }

  # Timezone configuration
  file { '/etc/timezone':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "${timezone}\n",
  }

  # Steady-State Puppet Agent Service Management
  # Following successful Checkpoint 4.5 enrollment and handover, Puppet assumes
  # exclusive steady-state ownership of its own daemon.
  if $manage_puppet_agent {
    service { $puppet_agent_service:
      ensure     => running,
      enable     => true,
      hasstatus  => true,
      hasrestart => true,
    }
  }
}
