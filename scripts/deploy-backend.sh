#!/bin/bash

# Backend Deployment Script for Docker Hub & EC2
set -e  

echo " Starting backend deployment..."

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Required variables
DOCKER_USERNAME=${DOCKER_USERNAME}
IMAGE_NAME=${IMAGE_NAME:-"starttech-backend"}
TAG=${TAG:-"latest"}
ENVIRONMENT=${ENVIRONMENT:-"production"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

# Git information for tagging
GIT_COMMIT=$(git rev-parse --short HEAD)
GIT_BRANCH=$(git branch --show-current)
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo " Deployment Configuration:"
echo "   Docker Hub: $DOCKER_USERNAME/$IMAGE_NAME"
echo "   Git Commit: $GIT_COMMIT"
echo "   Branch: $GIT_BRANCH"
echo "   Environment: $ENVIRONMENT"
echo "   AWS Region: $AWS_REGION"

# Validate required variables
if [[ -z "$DOCKER_USERNAME" ]]; then
    echo " ERROR: DOCKER_USERNAME not set"
    exit 1
fi

# Login to Docker Hub
echo " Logging into Docker Hub..."
echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

# Build Docker image with security scanning
echo "  Building Docker image..."
docker build \
    --tag $DOCKER_USERNAME/$IMAGE_NAME:$TAG \
    --tag $DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT \
    --build-arg GIT_COMMIT=$GIT_COMMIT \
    --build-arg BUILD_DATE=$BUILD_DATE \
    --build-arg ENVIRONMENT=$ENVIRONMENT \
    -f ./Server/Dockerfile \
    ./Server

echo " Image built successfully"

# Run security scan on Docker image
echo " Scanning Docker image for vulnerabilities..."
if command -v trivy &> /dev/null; then
    trivy image --exit-code 1 --severity CRITICAL,HIGH $DOCKER_USERNAME/$IMAGE_NAME:$TAG
    echo " Security scan passed"
else
    echo "  Trivy not installed, skipping security scan"
    echo "   Install with: brew install trivy OR curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
fi

# Push to Docker Hub
echo " Pushing to Docker Hub..."
docker push $DOCKER_USERNAME/$IMAGE_NAME:$TAG
docker push $DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT

echo " Image pushed to Docker Hub:"
echo "   - $DOCKER_USERNAME/$IMAGE_NAME:$TAG"
echo "   - $DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT"

# Deploy to EC2 Auto Scaling Group
if [[ "$ENVIRONMENT" == "production" ]] || [[ "$ENVIRONMENT" == "staging" ]]; then
    echo " Deploying to EC2 Auto Scaling Group..."
    
    # Configure AWS credentials
    export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    export AWS_DEFAULT_REGION=${AWS_REGION}
    
    # Get current Auto Scaling Group name
    ASG_NAME=${ASG_NAME:-"starttech-backend-asg"}
    
    echo "🔍 Checking Auto Scaling Group: $ASG_NAME"
    
    # Create new launch template version with updated Docker image
    echo " Creating new launch template version..."
    
    # Base64 encode user data with new Docker image
    USER_DATA=$(cat <<EOF | base64 -w 0
#!/bin/bash
# Update and install Docker if not present
yum update -y
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user

# Login to Docker Hub (using instance profile/SSM for credentials)
aws ssm get-parameter --name /starttech/docker-hub-password --with-decryption --query Parameter.Value --output text | \
docker login -u $DOCKER_USERNAME --password-stdin

# Pull the new image
docker pull $DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT

# Stop and remove old container
docker stop starttech-backend || true
docker rm starttech-backend || true

# Run new container with environment variables
docker run -d \\
  --name starttech-backend \\
  --restart unless-stopped \\
  -p 8080:8080 \\
  -e MONGODB_URL="\$MONGODB_URL" \\
  -e REDIS_URL="\$REDIS_URL" \\
  -e ENVIRONMENT="$ENVIRONMENT" \\
  -e GIT_COMMIT="$GIT_COMMIT" \\
  --log-driver=awslogs \\
  --log-opt awslogs-region=$AWS_REGION \\
  --log-opt awslogs-group=/starttech/backend \\
  --log-opt awslogs-stream=instance-\$(curl -s http://169.254.169.254/latest/meta-data/instance-id) \\
  $DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT

# Install and configure CloudWatch agent for system metrics
yum install -y amazon-cloudwatch-agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c ssm:AmazonCloudWatch-linux
EOF
)

    # Create new launch template version
    LAUNCH_TEMPLATE_ID=$(aws ec2 describe-launch-templates \
        --query "LaunchTemplates[?contains(LaunchTemplateName, 'starttech-backend')].LaunchTemplateId" \
        --output text)
    
    if [[ -n "$LAUNCH_TEMPLATE_ID" ]]; then
        echo " Updating launch template: $LAUNCH_TEMPLATE_ID"
        
        aws ec2 create-launch-template-version \
            --launch-template-id $LAUNCH_TEMPLATE_ID \
            --source-version '$Latest' \
            --launch-template-data "UserData=$USER_DATA" \
            --query 'LaunchTemplateVersion.LatestVersion' \
            --output text
        
        # Start instance refresh for rolling deployment
        echo " Starting rolling deployment..."
        aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --strategy "Rolling" \
            --preferences '{
                "MinHealthyPercentage": 90,
                "InstanceWarmup": 300,
                "SkipMatching": false,
                "ScaleInProtectedInstancesFromLoadBalancers": false,
                "StandbyInstances": "Ignore"
            }' \
            --query 'InstanceRefreshId' \
            --output text
        
        echo " Instance refresh started. Deployment in progress..."
        
        # Monitor deployment progress
        echo "⏳ Monitoring deployment (will timeout after 10 minutes)..."
        TIMEOUT=600  # 10 minutes
        INTERVAL=30
        ELAPSED=0
        
        while [[ $ELAPSED -lt $TIMEOUT ]]; do
            STATUS=$(aws autoscaling describe-instance-refreshes \
                --auto-scaling-group-name $ASG_NAME \
                --query 'InstanceRefreshes[0].Status' \
                --output text)
            
            echo "   Status: $STATUS"
            
            if [[ "$STATUS" == "Successful" ]]; then
                echo " Deployment completed successfully!"
                break
            elif [[ "$STATUS" == "Failed" ]] || [[ "$STATUS" == "Cancelled" ]]; then
                echo " Deployment failed with status: $STATUS"
                exit 1
            fi
            
            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
        done
        
        if [[ $ELAPSED -ge $TIMEOUT ]]; then
            echo "  Deployment monitoring timed out. Check AWS Console for status."
        fi
        
    else
        echo "  No launch template found. Creating one..."
        
        # Create new launch template
        aws ec2 create-launch-template \
            --launch-template-name starttech-backend-lt \
            --launch-template-data "{\"ImageId\":\"ami-0c55b159cbfafe1f0\",\"InstanceType\":\"t3.micro\",\"KeyName\":\"starttech-key\",\"UserData\":\"$USER_DATA\"}" \
            --tag-specifications 'ResourceType=launch-template,Tags=[{Key=Name,Value=starttech-backend}]'
        
        echo " Created new launch template"
    fi
    
    # Run smoke tests after deployment
    echo " Running smoke tests..."
    
    # Get ALB DNS name from SSM Parameter Store
    ALB_DNS=$(aws ssm get-parameter \
        --name "/starttech/alb-dns-name" \
        --query "Parameter.Value" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$ALB_DNS" ]]; then
        echo " Testing load balancer endpoint: $ALB_DNS"
        
        # Retry logic for smoke tests
        for i in {1..10}; do
            echo "   Attempt $i/10..."
            if curl -f -s -o /dev/null --max-time 10 "http://$ALB_DNS/health"; then
                echo " Smoke test passed!"
                break
            fi
            sleep 30
        done
    else
        echo "  ALB DNS not found in SSM. Skipping smoke test."
    fi
fi

# Create deployment record
echo " Creating deployment record..."
DEPLOYMENT_INFO=$(cat <<EOF
{
    "deployment_time": "$(date -u +"%Y-%m-%d %H:%M:%S UTC")",
    "git_commit": "$GIT_COMMIT",
    "git_branch": "$GIT_BRANCH",
    "docker_image": "$DOCKER_USERNAME/$IMAGE_NAME:$GIT_COMMIT",
    "environment": "$ENVIRONMENT",
    "deployed_by": "$(whoami)@$(hostname)"
}
EOF
)
