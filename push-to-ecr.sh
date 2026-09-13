#!/bin/bash

# ⚠️ अपनी AWS Account ID और Region यहाँ बदलें
AWS_ACCOUNT_ID="261945560801"
AWS_REGION="us-east-1"


ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# 1. Login to ECR
echo "🔐 Logging into Amazon ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URL}

# 2. Frontend: Build, Tag & Push
echo "🚀 Processing Frontend..."
docker build -t student-app/frontend ./frontend
docker tag student-app/frontend:latest ${ECR_URL}/student-app/frontend:v3
docker push ${ECR_URL}/student-app/frontend:v3

# 3. Backend: Build, Tag & Push
echo "🚀 Processing Backend..."
docker build -t student-app/backend ./backend
docker tag student-app/backend:latest ${ECR_URL}/student-app/backend:v3
docker push ${ECR_URL}/student-app/backend:v3

echo "🎉 Success! All images successfully pushed to ECR."