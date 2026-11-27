#!/usr/bin/env bash
# ==============================================================================
# Nagios / NRPE Plugin: check_docker.sh
# Purpose: Read-only monitoring check for Docker daemon and UNIX socket status.
# Target: CI/CD & Analysis Server (EC2 3 / cicd-server).
# Standards: Nagios Plugin API return codes:
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN
# Security: Strictly read-only. Never executes containers or user repository code.
# ==============================================================================
set -euo pipefail

export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin"

SERVICE_NAME="docker"
DOCKER_SOCKET="/var/run/docker.sock"

# 1. Verify systemd service status
if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    SERVICE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")
    echo "CRITICAL - Docker daemon service (${SERVICE_NAME}) is ${SERVICE_STATE}"
    exit 2
fi

# 2. Verify Docker UNIX socket existence
if [[ ! -S "${DOCKER_SOCKET}" ]]; then
    echo "CRITICAL - Docker service is active but socket (${DOCKER_SOCKET}) is missing"
    exit 2
fi

# 3. Check Docker daemon responsiveness via CLI if available and accessible
if command -v docker >/dev/null 2>&1; then
    if DOCKER_OUTPUT=$(timeout 5 docker info --format '{{.ServerVersion}} (containers: {{.ContainersRunning}} running, {{.Containers}} total)' 2>/dev/null); then
        echo "OK - Docker daemon is responsive - v${DOCKER_OUTPUT}"
        exit 0
    fi
fi

# Fallback: Service is active and UNIX socket is confirmed present
echo "OK - Docker daemon service is active and socket ${DOCKER_SOCKET} is present"
exit 0
