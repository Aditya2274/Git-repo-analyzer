# ==============================================================================
# Class: jenkins::install
# Purpose: Installs Java 21 runtime dependency, fontconfig, and Jenkins LTS
#          (2.580.3 planning baseline) on Ubuntu 24.04 LTS.
# Target: cicd-server (EC2 3) exclusively.
# Note: Exact package availability in pkg.jenkins.io/debian-stable and Java 21
#       compatibility must be revalidated prior to Boundary B deployment.
# ==============================================================================
class jenkins::install (
  Boolean                                           $manage_repo         = true,
  Boolean                                           $manage_packages     = true,
  Enum['openjdk-21-jre-headless', 'openjdk-21-jre'] $java_package        = 'openjdk-21-jre-headless',
  Pattern[/^[0-9]+\.[0-9]+(?:\.[0-9]+)?$/]          $jenkins_version     = '2.580.3',
  Boolean                                           $pin_package_version = true,
  String[1]                                         $package_name        = 'jenkins',
  String[1]                                         $apt_source_file     = '/etc/apt/sources.list.d/jenkins.list',
  String[1]                                         $apt_pref_file       = '/etc/apt/preferences.d/jenkins',
) {
  if $manage_packages {
    if ! defined(Package['fontconfig']) {
      package { 'fontconfig':
        ensure => present,
      }
    }

    if ! defined(Package[$java_package]) {
      package { $java_package:
        ensure => present,
      }
    }

    $effective_package_ensure = $pin_package_version ? {
      true    => $jenkins_version,
      default => 'present',
    }

    $base_requires = [
      Package['fontconfig'],
      Package[$java_package],
    ]

    $package_requires = $manage_repo ? {
      true    => $base_requires + [
        File[$apt_source_file],
        File[$apt_pref_file],
        Exec['jenkins_apt_update'],
      ],
      default => $base_requires,
    }

    package { $package_name:
      ensure  => $effective_package_ensure,
      require => $package_requires,
    }
  }
}
