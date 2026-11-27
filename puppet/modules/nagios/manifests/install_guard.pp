# ==============================================================================
# Class: nagios::install_guard
# Purpose: Manages a narrowly scoped, temporary /usr/sbin/policy-rc.d lifecycle
#          around Nagios Core and Apache2 package installation on Ubuntu 24.04.
# Target: app-server (EC2 2) exclusively.
#
# Lifecycle:
#   1. Preflight & setup (nagios_enable_policy_rc_d): Executes whenever any
#      target package is not yet installed:
#        - No policy exists: atomically installs a Puppet-marked policy-rc.d
#          (0755) + active Puppet PID file.
#        - Puppet-marked policy exists: inspects recorded PID lifecycle; fails
#          if another live Puppet process holds it, or refreshes if stale.
#        - Administrator-managed policy exists (regular file or symlink without
#          Puppet marker): NEVER executed, inferred from, modified, renamed, or
#          deleted. Fails closed before any package installation with a clear
#          diagnostic instructing the operator to resolve it manually.
#   2. Package install: Puppet-managed guard returns 101 strictly for nagios4
#      and apache2 while parent Puppet PID is live (unrelated services exit 0;
#      crashed Puppet exits fail-open cleanly).
#   3. Post-install cleanup (nagios_disable_policy_rc_d): Explicitly removes
#      only the Puppet-marked policy-rc.d and PID file once packages finish.
#      Never overwrites, modifies, or deletes an administrator-managed policy.
#   4. Steady-state idempotency: Once target packages are installed and no
#      marker remains, neither exec runs on subsequent Puppet runs.
# ==============================================================================
class nagios::install_guard (
  Array[String[1]] $target_packages = [
    'nagios4',
    'monitoring-plugins-basic',
    'apache2',
    'apache2-utils',
  ],
  Array[String[1]] $suppressed_services = [
    'nagios4',
    'apache2',
  ],
  String[1]        $policy_file = '/usr/sbin/policy-rc.d',
  String[1]        $pid_file    = '/run/puppet-nagios-pkg-install.pid',
  String[1]        $marker      = 'PUPPET-MANAGED-TEMP-POLICY-RC-D: git-repo-analyzer-nagios',
) {
  $pkg_list = $target_packages.reduce('') |$memo, $pkg| {
    $memo ? {
      ''      => $pkg,
      default => "${memo} ${pkg}",
    }
  }

  $all_installed_cmd = "for pkg in ${pkg_list}; do /usr/bin/dpkg-query -W -f='\${Status}' \"\$pkg\" 2>/dev/null | /usr/bin/grep -qx 'install ok installed' || exit 1; done"

  exec { 'nagios_enable_policy_rc_d':
    command   => template('nagios/enable_policy_rc_d.sh.erb'),
    provider  => 'shell',
    path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    unless    => $all_installed_cmd,
    logoutput => 'on_failure',
  }

  exec { 'nagios_disable_policy_rc_d':
    command   => template('nagios/disable_policy_rc_d.sh.erb'),
    provider  => 'shell',
    path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    onlyif    => "/usr/bin/test -f '${pid_file}' || ( ! /usr/bin/test -L '${policy_file}' && /usr/bin/test -f '${policy_file}' && /usr/bin/grep -qF '# ${marker}' '${policy_file}' )",
    logoutput => 'on_failure',
  }
}
