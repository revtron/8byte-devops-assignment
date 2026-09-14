// 8byte todo — CI/CD pipeline (assignment Part 2).
//
// Runs on the management host's Jenkins controller. `agent any` is used on
// purpose: this is a single-node demo, the controller is the only node and
// has Docker, Node 20, Trivy and the AWS CLI installed by
// scripts/bootstrap/management.sh. A real installation would pin builds to a
// dedicated agent label.
//
// Global environment (DOCKERHUB_REPO, BACKEND_INSTANCE_ID, SNS_TOPIC_ARN,
// ALB_DNS, AWS_REGION) is injected by JCasC (jenkins/jenkins.yaml,
// globalNodeProperties) so nothing environment-specific lives in this file.
//
// Stage order follows the design spec, section 6.2.

// Deploy <tag> to <envName> on the backend host through SSM Run Command.
// The send/poll logic lives in scripts/ssm-deploy.sh so it can be linted with
// `bash -n` and run by hand from the management box.
def ssmDeploy(String envName, String tag) {
    withEnv(["DEPLOY_ENV=${envName}", "DEPLOY_TAG=${tag}"]) {
        sh 'bash scripts/ssm-deploy.sh "$DEPLOY_ENV" "$DEPLOY_TAG"'
    }
}

// Failed-stage tracking: every stage has `post { failure { markStageFailed() } }`.
// A stage's post block runs inside that stage's context, so env.STAGE_NAME is
// the stage that just failed. The pipeline-level post { failure } reads
// env.FAILED_STAGE for the SNS message. Simple, no plugin needed.
def markStageFailed() {
    env.FAILED_STAGE = env.STAGE_NAME
}

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        // Default: promote to production automatically once staging is
        // healthy. Untick on "Build with Parameters" to get the manual
        // "Approve production" prompt back (e.g. for a demo).
        booleanParam(name: 'AUTO_APPROVE_PROD', defaultValue: true,
                     description: 'Deploy to production without waiting for a manual approval')
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
                    echo "Building ${env.BRANCH_NAME} @ ${env.GIT_SHA}"
                }
            }
            post { failure { markStageFailed() } }
        }

        stage('Install & Lint') {
            steps {
                dir('app') {
                    sh 'npm ci'
                    sh 'npm run lint'
                }
            }
            post { failure { markStageFailed() } }
        }

        stage('Unit tests') {
            steps {
                dir('app') {
                    sh 'npm run test:unit'
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'app/reports/junit.xml'
                }
                failure { markStageFailed() }
            }
        }

        stage('Integration tests') {
            // A throw-away Postgres sidecar on the controller. disableConcurrentBuilds
            // only serialises builds of ONE branch job; two branches of the
            // multibranch project can still build side by side on the two
            // executors, so the container name and host port are derived from
            // EXECUTOR_NUMBER (unique per running build on a node).
            environment {
                IT_PG_NAME = "it-pg-${env.EXECUTOR_NUMBER}"
            }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    IT_PG_PORT=$((15430 + EXECUTOR_NUMBER))
                    docker rm -f "$IT_PG_NAME" >/dev/null 2>&1 || true
                    docker run -d --name "$IT_PG_NAME" \
                        -e POSTGRES_USER=todo -e POSTGRES_PASSWORD=todo -e POSTGRES_DB=todo_test \
                        -p "127.0.0.1:${IT_PG_PORT}:5432" postgres:16-alpine
                    for i in $(seq 1 30); do
                        if docker exec "$IT_PG_NAME" pg_isready -U todo -d todo_test >/dev/null 2>&1; then
                            echo "postgres ready after ${i}s"; break
                        fi
                        if [ "$i" -eq 30 ]; then echo "postgres did not become ready" >&2; exit 1; fi
                        sleep 1
                    done
                '''
                dir('app') {
                    sh 'DATABASE_URL="postgres://todo:todo@127.0.0.1:$((15430 + EXECUTOR_NUMBER))/todo_test" npm run test:integration'
                }
            }
            post {
                always {
                    sh 'docker rm -f "$IT_PG_NAME" >/dev/null 2>&1 || true'
                    junit allowEmptyResults: true, testResults: 'app/reports/junit.xml'
                }
                failure { markStageFailed() }
            }
        }

        stage('Dependency scan') {
            steps {
                // npm audit is advisory only (documented): the npm advisory DB is
                // noisy for dev-only deps. Trivy on the lockfile is the gate;
                // node_modules (installed above, dev deps included) is skipped so
                // only the lockfile's production dependency graph is judged.
                dir('app') {
                    sh 'npm audit --audit-level=high || true'
                }
                sh '''#!/bin/bash
                    set -euo pipefail
                    trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --no-progress \
                        --skip-dirs '**/node_modules' app/ | tee trivy-fs.txt
                '''
            }
            post { failure { markStageFailed() } }
        }

        stage('Terraform check') {
            // Only when the change set touches terraform/. Note: a branch's first
            // build has an empty change set, so this is skipped there.
            when { changeset "terraform/**" }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    # Run as the jenkins uid so .terraform/ is not left root-owned in the workspace.
                    TF="docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v $WORKSPACE/terraform:/tf -w /tf hashicorp/terraform:1.9"
                    $TF fmt -check -recursive
                    $TF init -backend=false -input=false
                    $TF validate
                '''
            }
            post { failure { markStageFailed() } }
        }

        stage('Build image') {
            when { branch 'main' }
            steps {
                sh 'docker build -t "$DOCKERHUB_REPO:$GIT_SHA" -t "$DOCKERHUB_REPO:latest" app/'
            }
            post { failure { markStageFailed() } }
        }

        stage('Image scan') {
            when { branch 'main' }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    trivy image --severity CRITICAL --exit-code 1 --no-progress "$DOCKERHUB_REPO:$GIT_SHA" | tee trivy-image.txt
                '''
            }
            post { failure { markStageFailed() } }
        }

        stage('Push image') {
            when { branch 'main' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
                    sh '''#!/bin/bash
                        set -euo pipefail
                        echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
                        trap 'docker logout' EXIT
                        docker push "$DOCKERHUB_REPO:$GIT_SHA"
                        docker push "$DOCKERHUB_REPO:latest"
                    '''
                }
            }
            post { failure { markStageFailed() } }
        }

        stage('Deploy staging') {
            when { branch 'main' }
            steps {
                ssmDeploy('staging', env.GIT_SHA)
            }
            post { failure { markStageFailed() } }
        }

        stage('Smoke test staging') {
            when { branch 'main' }
            steps {
                sh 'bash scripts/smoke-test.sh "http://$ALB_DNS:8080"'
            }
            post { failure { markStageFailed() } }
        }

        stage('Approve production') {
            // `input` inside a stage holds the executor while waiting. Fine for
            // this demo (2 executors, one job); on a busy controller you would
            // move the input to a no-agent stage or use `agent none` + `agent`
            // per stage. The `input` *step* (not the directive) is used so the
            // message sees env.GIT_SHA, which is set at runtime in Checkout —
            // the directive form is evaluated before any stage runs and showed
            // "Promote null to production?" on the first real run.
            when { branch 'main' }
            options {
                timeout(time: 30, unit: 'MINUTES')
            }
            steps {
                script {
                    // params is empty on the very first build after a
                    // parameters block is added; treat "unknown" as auto.
                    def auto = (params.AUTO_APPROVE_PROD == null) ? true : params.AUTO_APPROVE_PROD
                    if (auto) {
                        echo "AUTO_APPROVE_PROD=true — promoting ${env.GIT_SHA} without a manual gate"
                    } else {
                        input message: "Promote ${env.GIT_SHA} to production?", ok: 'Deploy'
                        echo "approved ${env.GIT_SHA}"
                    }
                }
            }
            post { failure { markStageFailed() } }
        }

        stage('Deploy production') {
            when { branch 'main' }
            steps {
                // Same tag as staging: the image is promoted, never rebuilt.
                ssmDeploy('prod', env.GIT_SHA)
            }
            post { failure { markStageFailed() } }
        }

        stage('Smoke test production') {
            when { branch 'main' }
            steps {
                sh 'bash scripts/smoke-test.sh "http://$ALB_DNS"'
            }
            post { failure { markStageFailed() } }
        }
    }

    post {
        failure {
            // Email via SNS (topic + subscription are created by Terraform).
            // Never fail the post block itself if SNS is unreachable.
            sh '''#!/bin/bash
                # No set -u: a missing variable must fall through to the || warning,
                # never abort the notifier itself.
                aws sns publish --region "${AWS_REGION:-}" --topic-arn "${SNS_TOPIC_ARN:-}" \
                    --subject "Jenkins FAILED: ${JOB_NAME:-?} #${BUILD_NUMBER:-?}" \
                    --message "Build ${BUILD_URL:-?} (branch ${BRANCH_NAME:-?}, commit ${GIT_SHA:-?}) failed at stage: ${FAILED_STAGE:-unknown}" \
                    || echo "WARNING: SNS publish failed" >&2
            '''
        }
        always {
            archiveArtifacts allowEmptyArchive: true, artifacts: 'trivy-*.txt'
        }
    }
}
