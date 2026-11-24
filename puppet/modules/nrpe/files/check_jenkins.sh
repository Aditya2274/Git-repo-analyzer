#!/usr/bin/env bash
# ==============================================================================
# Nagios / NRPE Plugin: check_jenkins.sh
# Purpose: Read-only monitoring check for Jenkins service and HTTP API status.
# Target: CI/CD & Analysis Server (EC2 3 / cicd-server).
# Standards: Nagios Plugin API return codes:
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN
# Security: Strictly read-only. Never executes user code or repository files.
# ==============================================================================
set -euo pipefail

export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin"

SERVICE_NAME="jenkins"
JENKINS_HOST="127.0.0.1"
JENKINS_PORT=8080
TIMEOUT=5

# 1. Verify systemd service status
if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    SERVICE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")
    echo "CRITICAL - Jenkins service (${SERVICE_NAME}) is ${SERVICE_STATE}"
    exit 2
fi

# 2. Check local HTTP endpoint responsiveness
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -m "${TIMEOUT}" -o /dev/null -w "%{http_code}" "http://${JENKINS_HOST}:${JENKINS_PORT}/login" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^(200|403)$ ]]; then
        echo "OK - Jenkins service is running and HTTP endpoint responding on port ${JENKINS_PORT} (HTTP ${HTTP_CODE})"
        exit 0
    elif [[ "${HTTP_CODE}" == "000" ]]; then
        if nc -z -w "${TIMEOUT}" "${JENKINS_HOST}" "${JENKINS_PORT}" 2>/dev/null || (exec 3<>/dev/tcp/${JENKINS_HOST}/${JENKINS_PORT}) 2>/dev/null; then
            echo "WARNING - Jenkins service is active; port ${JENKINS_PORT} open but HTTP endpoint timed out"
            exit 1
        else
            echo "CRITICAL - Jenkins service is active but port ${JENKINS_PORT} refused connection"
            exit 2
        fi
    else
        echo "WARNING - Jenkins HTTP check returned unexpected status code: ${HTTP_CODE}"
        exit 1
    fi
fi

# 3. Direct TCP port check fallback
if nc -z -w "${TIMEOUT}" "${JENKINS_HOST}" "${JENKINS_PORT}" 2>/dev/null || (exec 3<>/dev/tcp/${JENKINS_HOST}/${JENKINS_PORT}) 2>/dev/null; then
    echo "OK - Jenkins service is running and listening on port ${JENKINS_PORT}"
    exit 0
else
    echo "CRITICAL - Jenkins service is active but port ${JENKINS_PORT} is not listening"
    exit 2
fi
