#!/usr/bin/env bash
# ==============================================================================
# Nagios / NRPE Plugin: check_puppetserver.sh
# Purpose: Read-only monitoring check for Puppet Server service & port 8140.
# Target: Dedicated Puppet Server (EC2 1 / puppet-server).
# Standards: Nagios Plugin API return codes:
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN
# Security: Strictly read-only. Never executes user code or repository files.
# ==============================================================================
set -euo pipefail

export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/opt/puppetlabs/bin"

SERVICE_NAME="puppetserver"
PUPPET_HOST="127.0.0.1"
PUPPET_PORT=8140
TIMEOUT=5

# 1. Verify systemd service status
if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    SERVICE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")
    echo "CRITICAL - Puppet Server service (${SERVICE_NAME}) is ${SERVICE_STATE}"
    exit 2
fi

# 2. Check port 8140 responsiveness via Puppet status API (/status/v1/simple)
if command -v curl >/dev/null 2>&1; then
    # -k accepts internal CA self-signed cert; timeout bounded
    STATUS_RESP=$(curl -k -s -m "${TIMEOUT}" "https://${PUPPET_HOST}:${PUPPET_PORT}/status/v1/simple" 2>/dev/null || echo "")
    if [[ "${STATUS_RESP}" =~ "running" ]]; then
        echo "OK - Puppet Server is active and healthy on port ${PUPPET_PORT} (${STATUS_RESP})"
        exit 0
    fi
fi

# 3. Fallback: check TCP socket listener on port 8140
if nc -z -w "${TIMEOUT}" "${PUPPET_HOST}" "${PUPPET_PORT}" 2>/dev/null || (exec 3<>/dev/tcp/${PUPPET_HOST}/${PUPPET_PORT}) 2>/dev/null; then
    echo "OK - Puppet Server service is active and listening on port ${PUPPET_PORT}"
    exit 0
else
    echo "WARNING - Puppet Server service is active but port ${PUPPET_PORT} is unresponsive"
    exit 1
fi
