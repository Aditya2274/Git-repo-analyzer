# ==============================================================================
# Class: nrpe::client
# Purpose: Installs the check_nrpe plugin for Nagios check execution.
# ==============================================================================
class nrpe::client (
  String[1] $plugin_package  = 'nagios-nrpe-plugin',
  String[1] $check_nrpe_path = '/usr/lib/nagios/plugins/check_nrpe',
) {
  package { $plugin_package:
    ensure => present,
  }
}
