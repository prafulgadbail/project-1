pipeline {
    agent any

    environment {
        AWS_REGION     = 'us-east-1'
        AWS_ACCOUNT_ID = '261945560801'
        ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

        BACKEND_REPO = 'student-app/backend'
        IMAGE_TAG    = "${BUILD_NUMBER}"

        FRONTEND_BUCKET          = 'student-registration-frontend-prod'
        CLOUDFRONT_DISTRIBUTION_ID = 'E2OVGFOC8RZSOZ'

        CLUSTER_NAME = 'prod-cluster'
        NAMESPACE    = 'student-app'
    }

    stages {

        stage('Backend Build') {
            steps {
                dir('backend') {
                    sh 'mvn clean package -DskipTests'
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                echo 'SonarQube integration will be enabled after server configuration.'
            }
        }

        stage('ECR Login') {
            steps {
                sh '''
                    aws ecr get-login-password --region "$AWS_REGION" |
                    docker login --username AWS --password-stdin "$ECR_REGISTRY"
                '''
            }
        }

        stage('Backend Build & Push') {
            steps {
                dir('backend') {
                    sh '''
                        docker build \
                            -t "$ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG" \
                            .

                        docker push \
                            "$ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('Frontend Build') {
            steps {
                dir('frontend') {
                    sh '''
                        npm ci
                        VITE_API_URL=/api npm run build
                    '''
                }
            }
        }

        stage('Frontend Upload to S3') {
            steps {
                dir('frontend') {
                    sh '''
                        aws s3 sync dist/ \
                            "s3://$FRONTEND_BUCKET" \
                            --delete
                    '''
                }
            }
        }

        stage('CloudFront Invalidation') {
            steps {
                sh '''
                    aws cloudfront create-invalidation \
                        --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
                        --paths "/*"
                '''
            }
        }

        stage('Deploy Backend to Kubernetes') {
            steps {
                sh '''
                    aws eks update-kubeconfig \
                        --region "$AWS_REGION" \
                        --name "$CLUSTER_NAME"

                    kubectl apply -f k8s/namespace.yaml
                    kubectl apply -f k8s/external-secret.yaml
                    kubectl apply -f k8s/backend.yaml
                    kubectl apply -f k8s/ingress.yaml

                    kubectl set image deployment/backend \
                        backend="$ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG" \
                        -n "$NAMESPACE"
                '''
            }
        }

        stage('Verify Deployment') {
            steps {
                sh '''
                    kubectl rollout status deployment/backend \
                        -n "$NAMESPACE" \
                        --timeout=5m
                '''
            }
        }
    }
}