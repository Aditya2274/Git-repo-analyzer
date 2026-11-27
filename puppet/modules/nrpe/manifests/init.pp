# ==============================================================================
# Class: nrpe
# Purpose: Top-level wrapper for NRPE module. Selects server or client role.
# ==============================================================================
class nrpe (
  Enum['server', 'client', 'none'] $role = 'none',
) {
  case $role {
    'server': {
      include nrpe::server
    }
    'client': {
      include nrpe::client
    }
    default: {
      # Do not include either by default
    }
  }
}
