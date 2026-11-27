# ==============================================================================
# Class: application::release
# Purpose: Verifies staged application release tarballs via external .sha256
#          sidecar + Hiera expected digest, safely extracts immutable releases,
#          and activates backend/frontend symlinks.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class application::release (
  Optional[String[1]] $version                = undef,
  Optional[String[1]] $expected_sha256        = undef,
  Boolean             $require_release        = false,
  String[1]           $base_dir               = '/opt/git-repo-analyzer',
  String[1]           $cache_dir              = '/var/cache/git-repo-analyzer',
  String[1]           $staging_dir            = '/var/cache/git-repo-analyzer/staging',
  String[1]           $www_dir                = '/var/www/git-repo-analyzer',
  String[1]           $state_file             = '/var/lib/git-repo-analyzer/release-state.json',
  Integer[2, 20]      $retain_releases        = 3,
  String[1]           $staging_owner          = 'ubuntu',
  String[1]           $staging_group          = 'ubuntu',
  String[1]           $backend_owner          = 'root',
  String[1]           $backend_group          = 'gitrepo',
  String[1]           $frontend_owner         = 'root',
  String[1]           $frontend_group         = 'www-data',
  Boolean             $manage_ownership       = true,
  Boolean             $manage_maintenance     = false,
  Optional[String[1]] $maintenance_flag_file  = undef,
  String[1]           $python_bin             = '/usr/bin/python3',
) {
  $effective_maintenance_flag = $maintenance_flag_file ? {
    undef   => "${base_dir}/maintenance.flag",
    default => $maintenance_flag_file,
  }
  if ($version != undef and $expected_sha256 == undef) or ($version == undef and $expected_sha256 != undef) {
    fail('application::release requires BOTH version and expected_sha256 when deploying a release')
  }

  if $require_release and ($version == undef or $expected_sha256 == undef) {
    fail('application::release requires version and expected_sha256 when require_release is true')
  }

  if $version != undef {
    if $version !~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ or $version =~ /\.\./ {
      fail("Invalid application::release version '${version}': unsafe characters or path traversal rejected")
    }
  }

  if $expected_sha256 != undef {
    if $expected_sha256 !~ /^[0-9a-f]{64}$/ {
      fail("Invalid application::release expected_sha256 '${expected_sha256}': expected 64 lowercase hex characters")
    }
  }

  $releases_dir = "${base_dir}/releases"
  $bin_dir = "${base_dir}/bin"
  $release_manager_path = "${bin_dir}/release_manager.py"
  $health_check_path = "${bin_dir}/health_check.py"
  $current_active_link = "${base_dir}/current"
  $backend_active_link = "${base_dir}/backend"
  $frontend_active_link = "${www_dir}/dist"

  $dir_root_owner = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $dir_root_group = $manage_ownership ? {
    true    => 'root',
    default => undef,
  }
  $dir_staging_owner = $manage_ownership ? {
    true    => $staging_owner,
    default => undef,
  }
  $dir_staging_group = $manage_ownership ? {
    true    => $staging_group,
    default => undef,
  }
  $dir_www_owner = $manage_ownership ? {
    true    => $frontend_owner,
    default => undef,
  }
  $dir_www_group = $manage_ownership ? {
    true    => $frontend_group,
    default => undef,
  }

  file { $cache_dir:
    ensure => directory,
    owner  => $dir_root_owner,
    group  => $dir_root_group,
    mode   => '0755',
  }

  file { $staging_dir:
    ensure  => directory,
    owner   => $dir_staging_owner,
    group   => $dir_staging_group,
    mode    => '0750',
    require => File[$cache_dir],
  }

  file { $base_dir:
    ensure => directory,
    owner  => $dir_root_owner,
    group  => $dir_root_group,
    mode   => '0755',
  }

  file { $releases_dir:
    ensure  => directory,
    owner   => $dir_root_owner,
    group   => $dir_root_group,
    mode    => '0755',
    require => File[$base_dir],
  }

  file { $bin_dir:
    ensure  => directory,
    owner   => $dir_root_owner,
    group   => $dir_root_group,
    mode    => '0755',
    require => File[$base_dir],
  }

  file { $www_dir:
    ensure => directory,
    owner  => $dir_www_owner,
    group  => $dir_www_group,
    mode   => '0750',
  }

  file { $release_manager_path:
    ensure  => file,
    owner   => $dir_root_owner,
    group   => $dir_root_group,
    mode    => '0755',
    source  => 'puppet:///modules/application/release_manager.py',
    require => File[$bin_dir],
  }

  file { $health_check_path:
    ensure  => file,
    owner   => $dir_root_owner,
    group   => $dir_root_group,
    mode    => '0755',
    source  => 'puppet:///modules/application/health_check.py',
    require => File[$bin_dir],
  }

  if $version != undef and $expected_sha256 != undef {
    $chown_flag = $manage_ownership ? {
      true    => ' --chown',
      default => '',
    }
    $frontend_chown_flags = $manage_ownership ? {
      true    => " --chown --frontend-owner '${frontend_owner}' --frontend-group '${frontend_group}'",
      default => '',
    }
    $target_release_dir = "${releases_dir}/${version}"

    exec { 'app_prepare_release':
      command   => "${python_bin} ${release_manager_path} prepare --version '${version}' --expected-sha256 '${expected_sha256}' --staging-dir '${staging_dir}' --releases-dir '${releases_dir}' --backend-owner '${backend_owner}' --backend-group '${backend_group}' --frontend-owner '${frontend_owner}' --frontend-group '${frontend_group}'${chown_flag}",
      unless    => "${python_bin} ${release_manager_path} is-extracted --version '${version}' --expected-sha256 '${expected_sha256}' --releases-dir '${releases_dir}'",
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => [
        File[$staging_dir],
        File[$releases_dir],
        File[$release_manager_path],
      ],
    }

    if $manage_maintenance {
      exec { 'app_enter_maintenance':
        command   => "${python_bin} ${release_manager_path} enter-maintenance --version '${version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --backend-link '${backend_active_link}' --maintenance-flag '${effective_maintenance_flag}'",
        unless    => "${python_bin} ${release_manager_path} is-maintenance-ready --version '${version}' --expected-sha256 '${expected_sha256}' --state-file '${state_file}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}' --maintenance-flag '${effective_maintenance_flag}'",
        path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
        logoutput => on_failure,
        require   => [
          File[$base_dir],
          File[$release_manager_path],
          Exec['app_prepare_release'],
        ],
      }

      $activate_requires = [
        File[$www_dir],
        File[$release_manager_path],
        Exec['app_prepare_release'],
        Exec['app_enter_maintenance'],
      ]
    } else {
      $activate_requires = [
        File[$www_dir],
        File[$release_manager_path],
        Exec['app_prepare_release'],
      ]
    }

    exec { 'app_activate_release':
      command   => "${python_bin} ${release_manager_path} activate --version '${version}' --expected-sha256 '${expected_sha256}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}' --state-file '${state_file}'${frontend_chown_flags}",
      unless    => "${python_bin} ${release_manager_path} is-active --version '${version}' --expected-sha256 '${expected_sha256}' --releases-dir '${releases_dir}' --current-link '${current_active_link}' --backend-link '${backend_active_link}' --frontend-link '${frontend_active_link}'",
      path      => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      logoutput => on_failure,
      require   => $activate_requires,
    }
  }
}
