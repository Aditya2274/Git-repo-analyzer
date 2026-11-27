# ==============================================================================
# Class: jenkins::service
# Purpose: Manages the Jenkins Controller systemd service enablement, running
#          state, and configuration-change restarts on cicd-server.
# Target: cicd-server (EC2 3) exclusively.
# ==============================================================================
class jenkins::service (
  Boolean                 $manage_service      = true,
  Boolean                 $manage_packages     = true,
  String[1]               $package_name        = 'jenkins',
  String[1]               $service_name        = 'jenkins',
  Enum['systemd', 'base'] $service_provider    = 'systemd',
  String[1]               $systemctl_bin       = '/bin/systemctl',
  String[1]               $jenkins_home        = '/var/lib/jenkins',
  String[1]               $systemd_dropin_file = '/etc/systemd/system/jenkins.service.d/override.conf',
) {
  if $manage_service {
    $base_requires = [
      File[$jenkins_home],
      File["${jenkins_home}/init.groovy.d/01-controller-hardening.groovy"],
      File[$systemd_dropin_file],
      Exec['jenkins_systemd_daemon_reload'],
    ]

    $service_requires = $manage_packages ? {
      true    => $base_requires + [Package[$package_name]],
      default => $base_requires,
    }

    $service_subscribes = [
      File[$systemd_dropin_file],
      File["${jenkins_home}/init.groovy.d/01-controller-hardening.groovy"],
    ]

    if $service_provider == 'systemd' {
      service { $service_name:
        ensure     => running,
        enable     => true,
        provider   => 'systemd',
        hasstatus  => true,
        hasrestart => true,
        require    => $service_requires,
        subscribe  => $service_subscribes,
      }
    } else {
      service { $service_name:
        ensure    => running,
        provider  => 'base',
        status    => "${systemctl_bin} is-active '${service_name}'",
        start     => "${systemctl_bin} start '${service_name}'",
        stop      => "${systemctl_bin} stop '${service_name}'",
        restart   => "${systemctl_bin} restart '${service_name}'",
        require   => $service_requires,
        subscribe => $service_subscribes,
      }
    }

    Exec['jenkins_systemd_daemon_reload'] ~> Service[$service_name]
  }
}
