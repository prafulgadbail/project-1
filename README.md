# 3-Tier Student Registration Application (AWS ECS Fargate)

![AWS](https://img.shields.io/badge/AWS-232F3E?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Jenkins](https://img.shields.io/badge/Jenkins-D24939?style=for-the-badge&logo=jenkins&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-003545?style=for-the-badge&logo=mariadb&logoColor=white)

A production-grade, highly available 3-Tier Web Application deployed on **AWS ECS Fargate** using an automated **Jenkins CI/CD Pipeline**. Built following enterprise security standards with zero hardcoded credentials and serverless compute.

---

## 🏗 Architecture & Design Flow

![System Architecture](./assets/architecture-diagram.svg)

### Key Infrastructure Highlights
* **Serverless Compute:** Deployed on AWS ECS Fargate, eliminating manual EC2 / Auto Scaling Group overhead.
* **Secrets Management:** DB credentials injected at runtime via **AWS Secrets Manager** using Task Execution IAM Roles.
* **SSL & Traffic Routing:** **AWS Route 53** routes custom domain traffic to an **Application Load Balancer (ALB)** secured with **AWS Certificate Manager (ACM)** HTTPS.
* **Network Isolation:** Application tasks run in Private Subnets with restricted Security Groups.

---

## 🔄 Automated CI/CD Pipeline

![CI/CD Pipeline Flow](./assets/cicd-pipeline.svg)

1. **Developer Push:** Code commit triggers Jenkins pipeline.
2. **Build Agent Execution:** Jenkins Controller delegates job to a dedicated Docker build agent.
3. **Image Packaging:** Container image built and tagged automatically with commit hash.
4. **Amazon ECR Storage:** Docker image pushed securely to private Amazon ECR repository.
5. **Zero-Downtime Deployment:** Jenkins updates AWS ECS Service to trigger a rolling deployment.

---

## 🛠 Tech Stack

* **Frontend / Backend:** Student Registration Stack
* **Database:** MariaDB
* **CI/CD:** Jenkins (Controller-Agent Architecture)
* **Containerization:** Docker, Amazon ECR
* **Cloud Infrastructure:** AWS ECS (Fargate), AWS ALB, Route 53, ACM, AWS Secrets Manager, CloudWatch

---

## 📸 Deployment Proofs & Evidence

<details>
<summary><b>👉 Click here to expand & view all AWS & Jenkins Live Deployment Proofs</b></summary>

<br>

### 1. Application UI & SSL Domain Verification
![Application UI](./assets/01-app-ui.png)

### 2. AWS Route 53 & ACM SSL Setup
![Route 53 and ACM](./assets/02-route53-acm.png)

### 3. Application Load Balancer & Target Group
![ALB Target Groups](./assets/03-alb-target-group.png)

### 4. AWS ECS Cluster & Fargate Tasks
![ECS Fargate Tasks](./assets/04-ecs-cluster-tasks.png)

### 5. AWS Secrets Manager Integration
![AWS Secrets Manager](./assets/05-secrets-manager.png)

### 6. MariaDB Database Terminal Verification
![MariaDB Verification](./assets/06-mariadb-terminal.png)

### 7. Jenkins CI/CD Pipeline Execution
![Jenkins Pipeline](./assets/07-jenkins-pipeline.png)

### 8. Amazon ECR Container Repositories
![Amazon ECR](./assets/08-amazon-ecr.png)

</details>