# ==============================================================================
# Class: nagios
# Purpose: Top-level orchestrator for Nagios Core monitoring server.
# ==============================================================================
class nagios (
  Boolean $manage_service = true,
  Boolean $manage_web     = true,
) {
  class { 'nagios::server': }
  -> class { 'nagios::objects': }

  if $manage_web {
    Class['nagios::server'] -> class { 'nagios::web': }
  }
}
