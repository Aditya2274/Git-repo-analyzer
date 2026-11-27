# ==============================================================================
# Class: nagios
# Purpose: Top-level orchestrator for Nagios Core monitoring server.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios (
  Boolean           $manage_service            = true,
  Boolean           $manage_web                = true,
  Boolean           $enforce_node              = true,
  Optional[Boolean] $enforce_production_secret = undef,
) {
  # Node targeting guard: nagios must run exclusively on app-server
  if $enforce_node and $trusted['certname'] != '' and $trusted['certname'] != 'app-server' {
    fail("Class nagios is strictly restricted to app-server; attempted inclusion on '${trusted['certname']}'")
  }

  $guard_packages = $manage_web ? {
    true    => ['nagios4', 'monitoring-plugins-basic', 'apache2', 'apache2-utils'],
    default => ['nagios4', 'monitoring-plugins-basic'],
  }

  class { 'nagios::install_guard':
    target_packages => $guard_packages,
  }

  class { 'nagios::server':
    manage_service => $manage_service,
  }

  if $manage_web {
    if $enforce_production_secret != undef {
      class { 'nagios::web':
        manage_service            => $manage_service,
        enforce_production_secret => $enforce_production_secret,
      }
    } else {
      class { 'nagios::web':
        manage_service => $manage_service,
      }
    }

    # Explicit cross-class ordering enforcing exact first-install sequence:
    # Step 1 (all packages under startup suppression -> guard cleanup)
    # -> Steps 2-4 (Nagios dirs, config, objects)
    # -> Steps 5-6 (Apache config & htpasswd)
    # -> Steps 7-8 (config validations) -> Step 9 (services)
    Package['nagios4']
    -> Package['apache2']
    -> Exec['nagios_disable_policy_rc_d']

    Package['monitoring-plugins-basic']
    -> Package['apache2']

    Package['apache2-utils']
    -> Exec['nagios_disable_policy_rc_d']
  }
}
