# ==============================================================================
# Class: nagios::objects
# Purpose: Manages host, service, command, and contact definitions for Nagios.
# ==============================================================================
class nagios::objects (
  String[1] $config_dir = '/etc/nagios4/conf.d',
) {
  # Hosts and services configuration directories and files
  # Will be fully populated in Checkpoint 5A.4
}
