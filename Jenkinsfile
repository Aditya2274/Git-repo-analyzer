pipeline {
    agent any
    parameters {
        string(
            name: 'REPO_URL',
            defaultValue: 'https://github.com/octocat/Hello-World.git',
            description: 'GitHub Repository URL'
        )
    }
    stages {
        stage('Pull Latest Analyzer Image') {
            steps {
                sh 'docker pull adityaashok2274/git-repo-analyzer:latest'
            }
        }
        stage('Clone Target Repository') {
            steps {
                sh '''
                rm -rf target-repo || true
                git clone ${REPO_URL} target-repo
                '''
            }
        }
        stage('Run Git Repository Analyzer') {
            steps {
                // This block securely fetches the key and maps it to the GROQ_API_KEY variable
                withCredentials([string(credentialsId: 'groq-api-key', variable: 'GROQ_API_KEY')]) {
                    sh '''
                    docker run --rm \
                      --user $(id -u):$(id -g) \
                      -e GROQ_API_KEY="$GROQ_API_KEY" \
                      -v $WORKSPACE/target-repo:/repo \
                      adityaashok2274/git-repo-analyzer:latest
                    '''
                }
            }
        }
        stage('Archive Reports') {
            steps {
                archiveArtifacts artifacts: 'target-repo/reports/**/*', fingerprint: true
            }
        }
    }
}