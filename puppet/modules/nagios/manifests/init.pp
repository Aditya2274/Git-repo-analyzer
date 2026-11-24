# ==============================================================================
# Class: nagios
# Purpose: Top-level orchestrator for Nagios Core monitoring server.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios (
  Boolean $manage_service            = true,
  Boolean $manage_web                = true,
  Boolean $enforce_node              = true,
  Boolean $enforce_production_secret = false,
) {
  # Node targeting guard: nagios must run exclusively on app-server
  if $enforce_node and $trusted['certname'] != '' and $trusted['certname'] != 'app-server' {
    fail("Class nagios is strictly restricted to app-server; attempted inclusion on '${trusted['certname']}'")
  }

  class { 'nagios::server':
    manage_service => $manage_service,
  }

  if $manage_web {
    Class['nagios::server']
    -> class { 'nagios::web':
      manage_service            => $manage_service,
      enforce_production_secret => $enforce_production_secret,
    }
  }
}
