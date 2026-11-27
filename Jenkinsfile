pipeline {
    agent any

    options {
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    parameters {
        string(
            name: 'REPO_URL',
            defaultValue: 'https://github.com/octocat/Hello-World.git',
            description: 'GitHub Repository URL'
        )
    }

    stages {
        stage('Validate Parameters & Storage') {
            steps {
                script {
                    def repoUrl = params.REPO_URL?.trim() ?: ''
                    // Strict full-string regex anchored to allow only valid HTTPS github.com repository URLs
                    def githubPattern = ~/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\.git)?$/
                    if (!(repoUrl ==~ githubPattern)) {
                        error("Security Validation Failed: REPO_URL must match GitHub HTTPS format (https://github.com/owner/repo[.git]). Received: '${repoUrl}'")
                    }
                }
                sh '''
                    set -eu
                    # Check available storage on workspace partition before cloning (availability gate; not a hard filesystem quota)
                    FREE_KB=$(df -Pk "${WORKSPACE:-.}" | awk 'NR==2 {print $4}')
                    echo "Available host workspace storage: ${FREE_KB} KB"
                    if [ "$FREE_KB" -lt 5242880 ]; then
                        echo "ERROR: Insufficient host workspace storage (${FREE_KB} KB available; minimum 5 GB required)." >&2
                        exit 1
                    fi
                '''
            }
        }

        stage('Pull Latest Analyzer Image') {
            steps {
                sh 'docker pull adityaashok2274/git-repo-analyzer:latest'
            }
        }

        stage('Clone Target Repository') {
            options {
                timeout(time: 5, unit: 'MINUTES')
            }
            steps {
                sh '''
                    set -eu
                    rm -rf target-repo || true
                    # Clone repository with disabled hooks, disabled submodules, and shallow depth 500
                    git -c core.hooksPath=/dev/null clone --no-recurse-submodules --depth 500 "$REPO_URL" target-repo

                    REPO_SIZE_KB=$(du -sk target-repo | awk '{print $1}')
                    echo "Cloned repository size: ${REPO_SIZE_KB} KB"
                    if [ "$REPO_SIZE_KB" -gt 2097152 ]; then
                        echo "ERROR: Cloned repository size (${REPO_SIZE_KB} KB) exceeds 2 GB ceiling (2,097,152 KB). Aborting." >&2
                        rm -rf target-repo
                        exit 1
                    fi
                '''
            }
        }

        stage('Run Git Repository Analyzer') {
            options {
                timeout(time: 10, unit: 'MINUTES')
            }
            steps {
                sh '''
                    set -eu
                    # Deterministic container name tied to build tag for targeted cleanup on abort/interrupt
                    CONTAINER_NAME="analyzer-${BUILD_TAG:-${BUILD_NUMBER:-run}}"

                    # Execute ephemeral analyzer container under non-root user with memory, CPU, and process sandboxing
                    # Host Docker daemon UNIX socket is NEVER mounted
                    # No Jenkins credentials or host secrets are injected; deterministic static report fallback is used
                    docker run --rm \
                      --name "$CONTAINER_NAME" \
                      --user "$(id -u):$(id -g)" \
                      --memory=768m \
                      --cpus=1.5 \
                      --pids-limit=100 \
                      -v "$WORKSPACE/target-repo:/repo" \
                      adityaashok2274/git-repo-analyzer:latest
                '''
            }
        }

        stage('Archive Reports') {
            steps {
                archiveArtifacts artifacts: 'target-repo/reports/**/*', fingerprint: true, allowEmptyArchive: false
            }
        }
    }

    post {
        always {
            sh '''
                set -u
                # Clean up any running analyzer container for this build tag if interrupted or timed out
                CONTAINER_NAME="analyzer-${BUILD_TAG:-${BUILD_NUMBER:-run}}"
                docker stop "$CONTAINER_NAME" 2>/dev/null || true
                docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
                rm -rf target-repo || true
            '''
        }
        cleanup {
            cleanWs deleteDirs: true, notFailBuild: true
        }
    }
}
