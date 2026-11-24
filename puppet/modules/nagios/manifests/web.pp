# ==============================================================================
# Class: nagios::web
# Purpose: Configures Apache loopback virtual host (127.0.0.1:8080) and HTTP
#          Basic Authentication with fail-closed production secret enforcement
#          and package-installation startup suppression.
# Target: app-server (EC2 2) exclusively.
# ==============================================================================
class nagios::web (
  String[1]        $apache_package            = 'apache2',
  String[1]        $apache_service            = 'apache2',
  Array[String[1]] $utils_packages            = ['apache2-utils'],
  Integer[1,65535] $listen_port               = 8080,
  String[1]        $bind_address              = '127.0.0.1',
  String[1]        $admin_user                = 'nagiosadmin',
  Optional[String] $admin_password_hash       = undef,
  String[1]        $htpasswd_file             = '/etc/nagios4/htpasswd.users',
  Boolean          $manage_service            = true,
  Boolean          $enforce_production_secret = true,
) {
  $operator_guidance = "A real operator-generated password hash is required in nagios::web::admin_password_hash. Generate one interactively using 'htpasswd -B -C 12 -n ${admin_user}' (never pass plaintext via -b) and configure ONLY the resulting hash via protected node Hiera (e.g., puppet/hieradata/nodes/app-server.yaml)."

  if $admin_password_hash == undef or $admin_password_hash =~ /^\s*$/ {
    fail("Nagios web credential error: nagios::web::admin_password_hash is absent or empty. ${operator_guidance}")
  }

  if $admin_password_hash =~ /[\s:]/ {
    fail("Nagios web credential error: nagios::web::admin_password_hash is malformed (must not contain colons, spaces, or newlines; supply only the hash portion, not 'username:hash'). ${operator_guidance}")
  }

  $is_known_placeholder = (
    $admin_password_hash == '$apr1$demo$hashedpassword' or
    $admin_password_hash =~ /^\$apr1\$demo\$/ or
    $admin_password_hash =~ /(?i)(placeholder|hashedpassword|changeme|replace[_-]?me)/
  )

  $is_valid_bcrypt = ($admin_password_hash =~ /^\$2[aby]\$(?:0[4-9]|[12][0-9]|3[01])\$[.\/A-Za-z0-9]{53}$/)
  $is_valid_apr1   = ($admin_password_hash =~ /^\$apr1\$[.\/A-Za-z0-9]{1,8}\$[.\/A-Za-z0-9]{22}$/)
  $is_valid_sha2   = ($admin_password_hash =~ /^\$[56]\$(?:rounds=[0-9]+\$)?[.\/A-Za-z0-9]{1,16}\$[.\/A-Za-z0-9]{43,86}$/)
  $is_valid_hash_format = $is_valid_bcrypt or $is_valid_apr1 or $is_valid_sha2

  if $enforce_production_secret {
    if $is_known_placeholder {
      fail("Production deployment rejected: nagios::web::admin_password_hash contains a known placeholder or demo credential. ${operator_guidance}")
    }
    if !$is_valid_hash_format {
      fail("Production deployment rejected: nagios::web::admin_password_hash is malformed or uses an unsupported password hash format (expected bcrypt \$2y\$/\$2b\$, APR1 \$apr1\$, or SHA-2 \$5\$/\$6\$). ${operator_guidance}")
    }
  } else {
    notify { 'nagios_placeholder_credential_warning':
      message  => "SECURITY WARNING: Production credential enforcement is explicitly disabled for nagios::web (admin_user=${admin_user}). Replace nagios::web::admin_password_hash and set enforce_production_secret => true before live deployment.",
      loglevel => 'warning',
    }
  }

  if ! defined(Class['nagios::install_guard']) {
    class { 'nagios::install_guard':
      target_packages => [$apache_package] + $utils_packages,
    }
  }

  package { $apache_package:
    ensure  => present,
    require => Exec['nagios_enable_policy_rc_d'],
  }

  package { $utils_packages:
    ensure  => present,
    require => Exec['nagios_enable_policy_rc_d'],
  }

  Exec['nagios_enable_policy_rc_d']
  -> Package[$apache_package]
  -> Exec['nagios_disable_policy_rc_d']

  Exec['nagios_enable_policy_rc_d']
  -> Package[$utils_packages]
  -> Exec['nagios_disable_policy_rc_d']

  if ! defined(File['/etc/nagios4']) {
    file { '/etc/nagios4':
      ensure  => directory,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      require => Exec['nagios_disable_policy_rc_d'],
    }
  }

  # Ensure Apache listens strictly on loopback port
  file { '/etc/apache2/ports.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('nagios/ports.conf.erb'),
    require => [
      Package[$apache_package],
      Exec['nagios_disable_policy_rc_d'],
    ],
    notify  => Exec['apache2_configtest'],
  }

  # Deploy Nagios loopback virtual host
  file { '/etc/apache2/sites-available/nagios.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('nagios/apache_nagios.conf.erb'),
    require => [
      Package[$apache_package],
      Exec['nagios_disable_policy_rc_d'],
    ],
    notify  => Exec['apache2_configtest'],
  }

  # Enable Nagios site
  file { '/etc/apache2/sites-enabled/nagios.conf':
    ensure  => link,
    target  => '/etc/apache2/sites-available/nagios.conf',
    require => File['/etc/apache2/sites-available/nagios.conf'],
    notify  => Exec['apache2_configtest'],
  }

  # Disable default Apache site to prevent port or document root conflicts
  file { '/etc/apache2/sites-enabled/000-default.conf':
    ensure  => absent,
    require => [
      Package[$apache_package],
      Exec['nagios_disable_policy_rc_d'],
    ],
    notify  => Exec['apache2_configtest'],
  }

  # Deploy htpasswd file with strict permissions (0640, root:www-data)
  file { $htpasswd_file:
    ensure  => file,
    owner   => 'root',
    group   => 'www-data',
    mode    => '0640',
    content => "${admin_user}:${admin_password_hash}\n",
    require => [
      Package[$apache_package],
      Exec['nagios_disable_policy_rc_d'],
      File['/etc/nagios4'],
    ],
    notify  => Exec['apache2_configtest'],
  }

  $apache_deployed_files = [
    File['/etc/apache2/ports.conf'],
    File['/etc/apache2/sites-available/nagios.conf'],
    File['/etc/apache2/sites-enabled/nagios.conf'],
    File['/etc/apache2/sites-enabled/000-default.conf'],
    File[$htpasswd_file],
  ]

  # When orchestrated inside full Nagios class, ensure Apache config & auth deploy
  # after Nagios objects and before Nagios/Apache validations and services.
  if defined(Class['nagios::objects']) {
    Class['nagios::objects'] -> File['/etc/apache2/ports.conf']
    Class['nagios::objects'] -> File['/etc/apache2/sites-available/nagios.conf']
    Class['nagios::objects'] -> File['/etc/apache2/sites-enabled/000-default.conf']
    Class['nagios::objects'] -> File[$htpasswd_file]
  }

  if defined(Exec['nagios4_configtest']) {
    $apache_deployed_files -> Exec['nagios4_configtest']
  }

  if defined(Exec['nagios4_configtest_before_start']) {
    $apache_deployed_files -> Exec['nagios4_configtest_before_start']
  }

  # Pre-reload Apache configuration validation
  exec { 'apache2_configtest':
    command     => '/usr/sbin/apache2ctl configtest',
    path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    refreshonly => true,
    onlyif      => '/usr/bin/test -x /usr/sbin/apache2ctl',
    require     => $apache_deployed_files,
    notify      => Service[$apache_service],
    before      => Service[$apache_service],
  }

  # Pre-start safety gate: ensures validation ALWAYS runs whenever apache2
  # is currently inactive (e.g., first install or retry after failed configtest).
  if $manage_service {
    exec { 'apache2_configtest_before_start':
      command => '/usr/sbin/apache2ctl configtest',
      path    => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
      onlyif  => '/usr/bin/test -x /usr/sbin/apache2ctl',
      unless  => "/usr/bin/systemctl is-active --quiet ${apache_service}",
      require => $apache_deployed_files,
      before  => Service[$apache_service],
    }
  }

  $service_ensure = $manage_service ? {
    true    => 'running',
    default => undef,
  }

  $base_apache_require = [
    Package[$apache_package],
    Exec['nagios_disable_policy_rc_d'],
    File['/etc/apache2/ports.conf'],
    File['/etc/apache2/sites-available/nagios.conf'],
    File['/etc/apache2/sites-enabled/nagios.conf'],
    File['/etc/apache2/sites-enabled/000-default.conf'],
    File[$htpasswd_file],
    Exec['apache2_configtest'],
  ]

  $apache_service_require = $manage_service ? {
    true    => $base_apache_require + [Exec['apache2_configtest_before_start']],
    default => $base_apache_require,
  }

  service { $apache_service:
    ensure     => $service_ensure,
    enable     => $manage_service,
    hasstatus  => true,
    hasrestart => true,
    require    => $apache_service_require,
  }
}
