# ==============================================================================
# Class: jenkins::config
# Purpose: Configures Jenkins home permissions, systemd drop-in overrides
#          (JVM heap -Xms384m -Xmx512m, HTTP port 8080, multicast suppression),
#          single-executor & security initialization script (zero embedded
#          credentials), and Docker group membership for the jenkins account.
# Target: cicd-server (EC2 3) exclusively.
# Security Note:
#   - Adding the jenkins user to the docker group grants root-equivalent access
#     on cicd-server (ADR 007); no unrelated service accounts are added.
#   - Docker remains on its local UNIX socket (never TCP).
#   - No credentials, API tokens, or LLM API keys are configured or injected.
#   - $listen_address ('0.0.0.0' default) creates a wildcard IPv4 listener on
#     all host interfaces (not a private-only socket), required because
#     Winstone/Jetty accepts one address only and must serve both 127.0.0.1 NRPE
#     probes and app-server VPC API requests.
#   - Network boundary: AWS SG cicd_analysis_sg (TCP 8080 restricted strictly
#     to app_monitoring_sg) is the primary network-level control across the EC2
#     1:1 NAT ENI. Application-layer controls (setAllowAnonymousRead(false) and
#     DefaultCrumbIssuer(true)) protect HTTP/REST requests only and do NOT block
#     TCP connections, provide network isolation, or rely on omitted container
#     credentials to restrict listener access.
# ==============================================================================
class jenkins::config (
  Boolean                      $manage_users        = true,
  Boolean                      $manage_ownership    = true,
  Boolean                      $manage_service      = true,
  Boolean                      $manage_docker_group = true,
  String[1]                    $jenkins_user        = 'jenkins',
  String[1]                    $jenkins_group       = 'jenkins',
  String[1]                    $docker_group        = 'docker',
  String[1]                    $jenkins_home        = '/var/lib/jenkins',
  Integer[1024, 65535]         $http_port           = 8080,
  Enum['0.0.0.0', '127.0.0.1'] $listen_address      = '0.0.0.0',
  Pattern[/^[0-9]+[mMgG]$/]    $jvm_xms             = '384m',
  Pattern[/^[0-9]+[mMgG]$/]    $jvm_xmx             = '512m',
  Integer[1, 1]                $num_executors       = 1,
  String[1]                    $service_name        = 'jenkins',
  String[1]                    $systemctl_bin       = '/bin/systemctl',
  String[1]                    $systemd_dropin_dir  = '/etc/systemd/system/jenkins.service.d',
  String[1]                    $systemd_dropin_file = '/etc/systemd/system/jenkins.service.d/override.conf',
) {
  $dir_root_owner = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $dir_root_group = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $dir_jenkins_owner = $manage_ownership ? {
    true    => $jenkins_user,
    default => undef,
  }
  $dir_jenkins_group = $manage_ownership ? {
    true    => $jenkins_group,
    default => undef,
  }

  $service_notify = $manage_service ? {
    true    => Service[$service_name],
    default => undef,
  }
  $daemon_reload_notify = $manage_service ? {
    true    => Exec['jenkins_systemd_daemon_reload'],
    default => undef,
  }

  if $manage_users and $manage_docker_group {
    if ! defined(Group[$docker_group]) {
      group { $docker_group:
        ensure => present,
      }
    }

    # ADR 007: Grant docker group membership strictly to the jenkins service user
    # (recognized as root-equivalent on cicd-server; unrelated accounts excluded).
    user { $jenkins_user:
      ensure     => present,
      gid        => $jenkins_group,
      groups     => [$docker_group],
      membership => 'minimum',
      managehome => false,
      require    => Group[$docker_group],
      notify     => $service_notify,
    }
  }

  file { $jenkins_home:
    ensure => directory,
    owner  => $dir_jenkins_owner,
    group  => $dir_jenkins_group,
    mode   => '0750',
  }

  file { "${jenkins_home}/init.groovy.d":
    ensure  => directory,
    owner   => $dir_jenkins_owner,
    group   => $dir_jenkins_group,
    mode    => '0750',
    require => File[$jenkins_home],
  }

  file { "${jenkins_home}/init.groovy.d/01-controller-hardening.groovy":
    ensure  => file,
    owner   => $dir_jenkins_owner,
    group   => $dir_jenkins_group,
    mode    => '0640',
    content => template('jenkins/controller-hardening.groovy.erb'),
    require => File["${jenkins_home}/init.groovy.d"],
    notify  => $service_notify,
  }

  file { $systemd_dropin_dir:
    ensure => directory,
    owner  => $dir_root_owner,
    group  => $dir_root_group,
    mode   => '0755',
  }

  file { $systemd_dropin_file:
    ensure  => file,
    owner   => $dir_root_owner,
    group   => $dir_root_group,
    mode    => '0644',
    content => template('jenkins/override.conf.erb'),
    require => File[$systemd_dropin_dir],
    notify  => $daemon_reload_notify,
  }

  if $manage_service {
    exec { 'jenkins_systemd_daemon_reload':
      command     => "${systemctl_bin} daemon-reload",
      refreshonly => true,
      path        => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }
  }
}
