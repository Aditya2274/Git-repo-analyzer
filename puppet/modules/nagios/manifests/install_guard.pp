# ==============================================================================
# Class: nagios::install_guard
# Purpose: Manages a narrowly scoped, temporary /usr/sbin/policy-rc.d lifecycle
#          around Nagios Core and Apache2 package installation on Ubuntu 24.04.
# Target: app-server (EC2 2) exclusively.
#
# Lifecycle:
#   1. Pre-install (nagios_enable_policy_rc_d): Executes ONLY when any target
#      package is missing and no unrelated admin policy-rc.d exists. Atomically
#      installs a Puppet-marked policy-rc.d (0755) + active Puppet PID file.
#   2. Package install: Blocks maintainer-script startup (exit 101) ONLY for
#      nagios4 and apache2 while the recorded Puppet process PID is running.
#      Unrelated daemons always return 0. If Puppet aborts mid-install, the
#      dead PID causes policy-rc.d to fail open (exit 0) immediately.
#   3. Post-install cleanup (nagios_disable_policy_rc_d): Explicitly removes
#      only the Puppet-marked policy-rc.d and PID file once packages finish.
#      Never overwrites or deletes an unrelated administrator-managed policy.
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
    command  => template('nagios/enable_policy_rc_d.sh.erb'),
    provider => 'shell',
    path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    onlyif   => "/usr/bin/test ! -e '${policy_file}' -a ! -L '${policy_file}' || /usr/bin/grep -qF '# ${marker}' '${policy_file}'",
    unless   => $all_installed_cmd,
  }

  exec { 'nagios_disable_policy_rc_d':
    command  => template('nagios/disable_policy_rc_d.sh.erb'),
    provider => 'shell',
    path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    onlyif   => "/usr/bin/test -f '${pid_file}' || ( /usr/bin/test -f '${policy_file}' && ! /usr/bin/test -L '${policy_file}' && /usr/bin/grep -qF '# ${marker}' '${policy_file}' )",
  }
}
