# ==============================================================================
# Class: jenkins::repo
# Purpose: Configures the official Jenkins Debian/Ubuntu LTS APT repository,
#          modern signed-by keyring (/etc/apt/keyrings/jenkins-keyring.asc),
#          and APT pin priority (900) without deprecated apt-key usage.
# Target: cicd-server (EC2 3) exclusively.
# ==============================================================================
class jenkins::repo (
  Boolean   $manage_repo     = true,
  String[1] $package_name    = 'jenkins',
  String[1] $keyring_dir     = '/etc/apt/keyrings',
  String[1] $keyring_file    = '/etc/apt/keyrings/jenkins-keyring.asc',
  String[1] $apt_source_file = '/etc/apt/sources.list.d/jenkins.list',
  String[1] $apt_pref_file   = '/etc/apt/preferences.d/jenkins',
  String[1] $gpg_key_url     = 'https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key',
  String[1] $repo_base_url   = 'https://pkg.jenkins.io/debian-stable',
) {
  if $repo_base_url !~ /^https:\/\/pkg\.jenkins\.io\/debian-stable\/?$/ {
    fail("Invalid jenkins::repo repo_base_url '${repo_base_url}': must use official HTTPS pkg.jenkins.io/debian-stable LTS repository")
  }

  if $gpg_key_url !~ /^https:\/\/pkg\.jenkins\.io\/.+$/ {
    fail("Invalid jenkins::repo gpg_key_url '${gpg_key_url}': must use official HTTPS pkg.jenkins.io signing key URL")
  }

  $normalized_repo_url = regsubst($repo_base_url, /\/$/, '')

  if $manage_repo {
    ['ca-certificates', 'curl', 'gnupg'].each |$pkg| {
      if ! defined(Package[$pkg]) {
        package { $pkg:
          ensure => present,
        }
      }
    }

    if ! defined(File[$keyring_dir]) {
      file { $keyring_dir:
        ensure => directory,
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
      }
    }

    exec { 'jenkins_apt_gpg_key':
      command => "/bin/sh -c 'set -eu; tmp=\$(mktemp); trap \"rm -f \\\"\\\$tmp\\\"\" EXIT; /usr/bin/curl -fsSL \"${gpg_key_url}\" -o \"\$tmp\" && /usr/bin/install -m 0644 \"\$tmp\" \"${keyring_file}\"'",
      creates => $keyring_file,
      path    => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require => [
        File[$keyring_dir],
        Package['ca-certificates'],
        Package['curl'],
        Package['gnupg'],
      ],
      notify  => Exec['jenkins_apt_update'],
    }

    file { $keyring_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      require => Exec['jenkins_apt_gpg_key'],
    }

    file { $apt_source_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "deb [signed-by=${keyring_file}] ${normalized_repo_url} binary/\n",
      require => File[$keyring_file],
      notify  => Exec['jenkins_apt_update'],
    }

    file { $apt_pref_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "Package: ${package_name}\nPin: origin pkg.jenkins.io\nPin-Priority: 900\n",
      notify  => Exec['jenkins_apt_update'],
    }

    exec { 'jenkins_apt_update':
      command     => '/usr/bin/apt-get update',
      refreshonly => true,
      path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require     => [
        File[$keyring_file],
        File[$apt_source_file],
        File[$apt_pref_file],
      ],
    }
  }
}
