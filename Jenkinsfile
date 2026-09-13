pipeline {
    agent {
        label 'build-agent'
    }

    environment {
        AWS_REGION = 'ap-south-1'
        AWS_ACCOUNT_ID = '261945560801'
        ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        BACKEND_REPO = 'student-app/backend'
        FRONTEND_REPO = 'student-app/frontend'
        IMAGE_TAG = "${BUILD_NUMBER}"
        CLUSTER_NAME = 'student-app-cluster'
    }

    stages {
        


        stage('ECR Login') {
            steps {
                sh "aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY"
            }
        }

        stage('Backend Build & Push') {
            steps {
                dir('backend') {
                    sh "docker build -t $ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG ."
                    sh "docker push $ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG"
                }
            }
        }
        stage('Frontend Build & Push') {
            steps {
                dir('frontend') {
                    sh "docker build -t $ECR_REGISTRY/$FRONTEND_REPO:$IMAGE_TAG ."
                    sh "docker push $ECR_REGISTRY/$FRONTEND_REPO:$IMAGE_TAG"
                }
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                sh "aws eks --region $AWS_REGION update-kubeconfig --name $CLUSTER_NAME"
                sh "kubectl apply -f k8s/namespace.yaml"
                sh "kubectl apply -f k8s/"
                sh "kubectl set image deployment/backend backend=$ECR_REGISTRY/$BACKEND_REPO:$IMAGE_TAG -n student-app"
                sh "kubectl set image deployment/frontend frontend=$ECR_REGISTRY/$FRONTEND_REPO:$IMAGE_TAG -n student-app"
                sh "kubectl rollout status deployment/backend -n student-app"
                sh "kubectl rollout status deployment/frontend -n student-app"
            }
        }
    }
}