# ==============================================================================
# Class: application::nodejs
# Purpose: Configures official NodeSource Node.js 24 LTS repository, GPG keyring,
#          APT pinning preference, installs nodejs package, and verifies major
#          version 24 on app-server. Node 20 EOL is explicitly forbidden.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class application::nodejs (
  Integer[24, 24] $node_major      = 24,
  Boolean         $manage_packages = true,
  Boolean         $verify_runtime  = true,
  String[1]       $node_bin        = '/usr/bin/node',
  String[1]       $keyring_dir     = '/etc/apt/keyrings',
  String[1]       $keyring_file    = '/etc/apt/keyrings/nodesource.gpg',
  String[1]       $apt_source_file = '/etc/apt/sources.list.d/nodesource.list',
  String[1]       $apt_pref_file   = '/etc/apt/preferences.d/nodesource-nodejs',
  String[1]       $gpg_key_url     = 'https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key',
  String[1]       $repo_base_url   = 'https://deb.nodesource.com/node_24.x',
) {
  if $repo_base_url !~ /^https:\/\/deb\.nodesource\.com\/node_24\.x\/?$/ {
    fail("Invalid application::nodejs repo_base_url '${repo_base_url}': must target NodeSource Node.js 24 LTS (node_24.x)")
  }

  if $gpg_key_url !~ /^https:\/\/deb\.nodesource\.com\/.+$/ {
    fail("Invalid application::nodejs gpg_key_url '${gpg_key_url}': must use official HTTPS deb.nodesource.com GPG key URL")
  }

  if $manage_packages {
    ['ca-certificates', 'curl', 'gnupg'].each |$pkg| {
      if ! defined(Package[$pkg]) {
        package { $pkg:
          ensure => present,
        }
      }
    }

    file { $keyring_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    exec { 'app_nodesource_gpg_key':
      command => "/bin/sh -c 'set -eu; tmp=\$(mktemp); trap \"rm -f \\\"\\\$tmp\\\"\" EXIT; /usr/bin/curl -fsSL \"${gpg_key_url}\" | /usr/bin/gpg --dearmor -o \"\$tmp\" && /usr/bin/install -m 0644 \"\$tmp\" \"${keyring_file}\"'",
      creates => $keyring_file,
      path    => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require => [
        File[$keyring_dir],
        Package['ca-certificates'],
        Package['curl'],
        Package['gnupg'],
      ],
      notify  => Exec['app_nodesource_apt_update'],
    }

    file { $keyring_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      require => Exec['app_nodesource_gpg_key'],
    }

    file { $apt_source_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "deb [signed-by=${keyring_file}] ${repo_base_url} nodistro main\n",
      require => File[$keyring_file],
      notify  => Exec['app_nodesource_apt_update'],
    }

    file { $apt_pref_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 900\n",
      notify  => Exec['app_nodesource_apt_update'],
    }

    exec { 'app_nodesource_apt_update':
      command     => '/usr/bin/apt-get update',
      refreshonly => true,
      path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require     => [
        File[$keyring_file],
        File[$apt_source_file],
        File[$apt_pref_file],
      ],
    }

    package { 'nodejs':
      ensure  => present,
      require => [
        File[$apt_source_file],
        File[$apt_pref_file],
        Exec['app_nodesource_apt_update'],
      ],
    }
  }

  if $verify_runtime {
    $runtime_require = $manage_packages ? {
      true    => Package['nodejs'],
      default => undef,
    }

    exec { 'app_verify_node_major_24':
      command => "/bin/sh -c 'echo \"Expected Node.js ${node_major} LTS at ${node_bin}, found: \$(${node_bin} -v 2>&1 || echo missing)\" >&2; exit 1'",
      unless  => "${node_bin} -e \"process.exit(Number(process.versions.node.split('.')[0])===${node_major}?0:1)\"",
      path    => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require => $runtime_require,
    }
  }
}
