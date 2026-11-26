# ==============================================================================
# Class: jenkins
# Purpose: Top-level orchestrator for the Puppet-managed Jenkins Controller on
#          cicd-server (EC2 3):
#            - Official Jenkins LTS APT repository & GPG keyring (jenkins::repo)
#            - Java 21 runtime & Jenkins LTS 2.580.3 baseline (jenkins::install)
#            - Systemd drop-in JVM heap (-Xms384m -Xmx512m), port 8080, single
#              controller executor, no anonymous access, and Docker group
#              membership (jenkins::config)
#            - Systemd daemon reload & service lifecycle (jenkins::service)
# Target: cicd-server (EC2 3) exclusively.
# Security & Boundary Notes:
#   - Jenkins must NEVER be placed on puppet-server or app-server.
#   - Zero credentials, passwords, or API tokens are embedded in manifests,
#     templates, or Hiera plaintext.
#   - Listener architecture: $listen_address defaults to '0.0.0.0' (a wildcard
#     IPv4 socket bind, NOT a private-only bind). Winstone/Jetty supports only
#     a single --httpListenAddress; '0.0.0.0' is required so both local NRPE
#     (127.0.0.1:8080) and remote app-server VPC calls work without adding an
#     extra reverse proxy on EC2 3. Binding to the VPC private IP alone would
#     break 127.0.0.1 NRPE checks and still receives AWS IGW 1:1 NAT traffic
#     for public IPv4 instances.
#   - Network security boundary: AWS Security Group cicd_analysis_sg restricts
#     TCP 8080 ingress strictly to app_monitoring_sg and is the primary
#     network-level control preventing unauthorized external access.
#   - Application-layer security: setAllowAnonymousRead(false) and
#     DefaultCrumbIssuer(true) are additional application-layer controls
#     (authentication and CSRF protection); they do NOT prevent TCP network
#     connections, provide network isolation, or rely on omitting container
#     credentials to restrict access to the Jenkins listener.
#   - External LLM API keys are never configured here; pipeline runs retain static fallback.
#   - Exact Jenkins LTS 2.580.3 availability and Java 21 compatibility must be
#     revalidated against pkg.jenkins.io/debian-stable prior to Boundary B.
#   - Actual 300 MB minimum host MemAvailable acceptance on the 2 GB EC2 3 node
#     remains a pending Boundary B empirical validation item.
# ==============================================================================
class jenkins (
  Boolean                                           $enforce_node         = true,
  Boolean                                           $manage_repo          = true,
  Boolean                                           $manage_packages      = true,
  Boolean                                           $manage_users         = true,
  Boolean                                           $manage_ownership     = true,
  Boolean                                           $manage_service       = true,
  Boolean                                           $manage_docker_group  = true,
  Enum['openjdk-21-jre-headless', 'openjdk-21-jre'] $java_package         = 'openjdk-21-jre-headless',
  Pattern[/^[0-9]+\.[0-9]+(?:\.[0-9]+)?$/]          $jenkins_version      = '2.580.3',
  Boolean                                           $pin_package_version  = true,
  String[1]                                         $package_name         = 'jenkins',
  String[1]                                         $service_name         = 'jenkins',
  Enum['systemd', 'base']                           $service_provider     = 'systemd',
  String[1]                                         $systemctl_bin        = '/bin/systemctl',
  String[1]                                         $jenkins_user         = 'jenkins',
  String[1]                                         $jenkins_group        = 'jenkins',
  String[1]                                         $docker_group         = 'docker',
  String[1]                                         $jenkins_home         = '/var/lib/jenkins',
  Integer[1024, 65535]                              $http_port            = 8080,
  Enum['0.0.0.0', '127.0.0.1']                      $listen_address       = '0.0.0.0',
  Pattern[/^[0-9]+[mMgG]$/]                         $jvm_xms              = '384m',
  Pattern[/^[0-9]+[mMgG]$/]                         $jvm_xmx              = '512m',
  Integer[1, 1]                                     $num_executors        = 1,
  String[1]                                         $keyring_dir          = '/etc/apt/keyrings',
  String[1]                                         $keyring_file         = '/etc/apt/keyrings/jenkins-keyring.asc',
  String[1]                                         $apt_source_file      = '/etc/apt/sources.list.d/jenkins.list',
  String[1]                                         $apt_pref_file        = '/etc/apt/preferences.d/jenkins',
  String[1]                                         $gpg_key_url          = 'https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key',
  String[1]                                         $repo_base_url        = 'https://pkg.jenkins.io/debian-stable',
  String[1]                                         $systemd_dropin_dir   = '/etc/systemd/system/jenkins.service.d',
  String[1]                                         $systemd_dropin_file  = '/etc/systemd/system/jenkins.service.d/override.conf',
) {
  # Node targeting guard: Jenkins must run exclusively on cicd-server
  if $enforce_node and $trusted['certname'] != '' and $trusted['certname'] != 'cicd-server' {
    fail("Class jenkins is strictly restricted to cicd-server; attempted inclusion on '${trusted['certname']}'")
  }

  # Validate absolute filesystem paths and reject control characters
  [
    $systemctl_bin,
    $jenkins_home,
    $keyring_dir,
    $keyring_file,
    $apt_source_file,
    $apt_pref_file,
    $systemd_dropin_dir,
    $systemd_dropin_file,
  ].each |$abs_path| {
    if $abs_path =~ /[\r\n\0]/ {
      fail('Class jenkins paths must not contain CR/LF or NUL characters')
    }
    if $abs_path !~ /^\// {
      fail("Class jenkins path '${abs_path}' must be an absolute path")
    }
  }

  # Validate JVM heap bounds so Xms <= Xmx and Xmx fits within 2 GB t3.small budget
  $xms_val = Integer(regsubst($jvm_xms, /^([0-9]+)[mMgG]$/, '\1'))
  $xms_unit = downcase(regsubst($jvm_xms, /^[0-9]+([mMgG])$/, '\1'))
  $xms_mb = $xms_unit ? {
    'g'     => $xms_val * 1024,
    default => $xms_val,
  }

  $xmx_val = Integer(regsubst($jvm_xmx, /^([0-9]+)[mMgG]$/, '\1'))
  $xmx_unit = downcase(regsubst($jvm_xmx, /^[0-9]+([mMgG])$/, '\1'))
  $xmx_mb = $xmx_unit ? {
    'g'     => $xmx_val * 1024,
    default => $xmx_val,
  }

  if $xms_mb <= 0 or $xmx_mb <= 0 or $xms_mb > $xmx_mb {
    fail("Invalid Jenkins JVM heap configuration: jvm_xms (${jvm_xms}) must be > 0 and <= jvm_xmx (${jvm_xmx})")
  }

  if $xmx_mb > 1024 {
    fail("Invalid Jenkins JVM heap configuration: jvm_xmx (${jvm_xmx}) exceeds safe 1024m ceiling for 2 GB t3.small cicd-server")
  }

  class { 'jenkins::repo':
    manage_repo     => $manage_repo,
    package_name    => $package_name,
    keyring_dir     => $keyring_dir,
    keyring_file    => $keyring_file,
    apt_source_file => $apt_source_file,
    apt_pref_file   => $apt_pref_file,
    gpg_key_url     => $gpg_key_url,
    repo_base_url   => $repo_base_url,
  }

  class { 'jenkins::install':
    manage_repo         => $manage_repo,
    manage_packages     => $manage_packages,
    java_package        => $java_package,
    jenkins_version     => $jenkins_version,
    pin_package_version => $pin_package_version,
    package_name        => $package_name,
    apt_source_file     => $apt_source_file,
    apt_pref_file       => $apt_pref_file,
  }

  class { 'jenkins::config':
    manage_users        => $manage_users,
    manage_ownership    => $manage_ownership,
    manage_service      => $manage_service,
    manage_docker_group => $manage_docker_group,
    jenkins_user        => $jenkins_user,
    jenkins_group       => $jenkins_group,
    docker_group        => $docker_group,
    jenkins_home        => $jenkins_home,
    http_port           => $http_port,
    listen_address      => $listen_address,
    jvm_xms             => $jvm_xms,
    jvm_xmx             => $jvm_xmx,
    num_executors       => $num_executors,
    service_name        => $service_name,
    systemctl_bin       => $systemctl_bin,
    systemd_dropin_dir  => $systemd_dropin_dir,
    systemd_dropin_file => $systemd_dropin_file,
  }

  class { 'jenkins::service':
    manage_service      => $manage_service,
    manage_packages     => $manage_packages,
    package_name        => $package_name,
    service_name        => $service_name,
    service_provider    => $service_provider,
    systemctl_bin       => $systemctl_bin,
    jenkins_home        => $jenkins_home,
    systemd_dropin_file => $systemd_dropin_file,
  }

  contain jenkins::repo
  contain jenkins::install
  contain jenkins::config
  contain jenkins::service

  Class['jenkins::repo']
  -> Class['jenkins::install']
  -> Class['jenkins::config']
  -> Class['jenkins::service']
}
