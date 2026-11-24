# ==============================================================================
# Master Site Manifest: site.pp
# Purpose: Authoritative node classification and catalog orchestration for the
#          three-node AWS Git Repository Analyzer infrastructure fleet.
# Fleet Targets:
#   1. puppet-server (Dedicated Puppet Server & CA)
#   2. app-server    (Application Host & NGINX Reverse Proxy)
#   3. cicd-server   (CI/CD Pipeline & Docker Analysis Host)
# ==============================================================================

# Global resource defaults
Exec {
  path => [
    '/bin',
    '/usr/bin',
    '/usr/local/bin',
    '/sbin',
    '/usr/sbin',
    '/opt/puppetlabs/bin',
  ],
}

# ------------------------------------------------------------------------------
# Node 1: puppet-server (Central Configuration Management & Monitoring)
# ------------------------------------------------------------------------------
node 'puppet-server' {
  class { 'common': }
  -> class { 'nrpe::client': }
  -> class { 'nagios': }
}

# ------------------------------------------------------------------------------
# Node 2: app-server (Application Server & NRPE Endpoint)
# ------------------------------------------------------------------------------
node 'app-server' {
  class { 'common': }
  -> class { 'nrpe::server': }
}

# ------------------------------------------------------------------------------
# Node 3: cicd-server (CI/CD Pipeline & Docker Analysis Host)
# ------------------------------------------------------------------------------
node 'cicd-server' {
  class { 'common': }
  -> class { 'nrpe::server': }
}

# ------------------------------------------------------------------------------
# Default Node Definition (Safety Baseline)
# ------------------------------------------------------------------------------
node default {
  class { 'common': }
}
