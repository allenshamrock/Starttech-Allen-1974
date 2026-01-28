#!/bin/bash

# Frontend Deployment Script
set -e  

echo " Starting frontend deployment..."

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Required environment variables
S3_BUCKET=${S3_BUCKET:-"starttech-frontend"}
CLOUDFRONT_DISTRIBUTION_ID=${CLOUDFRONT_DISTRIBUTION_ID}
AWS_REGION=${AWS_REGION:-"us-east-1"}
NODE_ENV=${NODE_ENV:-"production"}
REACT_APP_API_URL=${REACT_APP_API_URL:-"http://localhost:8080/api"}

echo " Environment:"
echo "   S3 Bucket: $S3_BUCKET"
echo "   Region: $AWS_REGION"
echo "   Node Env: $NODE_ENV"
echo "   API URL: $REACT_APP_API_URL"

# Validate required variables
if [[ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]]; then
    echo " ERROR: CLOUDFRONT_DISTRIBUTION_ID is not set"
    exit 1
fi

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo " Installing dependencies..."
    npm ci --silent
else
    echo " Dependencies already installed"
fi

# Run security audit
echo " Running security audit..."
npm audit --audit-level=high || true

# Run tests
echo " Running tests..."
npm test -- --watchAll=false --passWithNoTests

# Build the application
echo   Building React application..."
REACT_APP_API_URL=$REACT_APP_API_URL \
REACT_APP_VERSION=$(git rev-parse --short HEAD) \
REACT_APP_BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
npm run build

# Verify build output
if [ ! -d "build" ]; then
    echo " ERROR: Build directory not found"
    exit 1
fi

echo "Build size:"
du -sh build/

# Sync to S3 with proper caching headers
echo " Uploading to S3 bucket: $S3_BUCKET..."
aws s3 sync build/ s3://$S3_BUCKET/ \
    --delete \
    --cache-control "public, max-age=31536000, immutable" \
    --exclude "index.html" \
    --exclude "service-worker.js" \
    --exclude "manifest.json" \
    --region $AWS_REGION

# Upload HTML files with shorter cache
echo " Uploading HTML files..."
aws s3 sync build/ s3://$S3_BUCKET/ \
    --exclude "*" \
    --include "*.html" \
    --cache-control "public, max-age=0, must-revalidate" \
    --content-type "text/html; charset=utf-8" \
    --region $AWS_REGION

# Upload service worker and manifest
if [ -f "build/service-worker.js" ]; then
    echo "  Uploading service worker..."
    aws s3 cp build/service-worker.js s3://$S3_BUCKET/service-worker.js \
        --cache-control "public, max-age=0, must-revalidate" \
        --region $AWS_REGION
fi

if [ -f "build/manifest.json" ]; then
    echo " Uploading manifest..."
    aws s3 cp build/manifest.json s3://$S3_BUCKET/manifest.json \
        --cache-control "public, max-age=3600" \
        --content-type "application/json" \
        --region $AWS_REGION
fi

# Invalidate CloudFront cache
echo "Invalidating CloudFront cache..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id $CLOUDFRONT_DISTRIBUTION_ID \
    --paths "/*" \
    --query 'Invalidation.Id' \
    --output text \
    --region $AWS_REGION)

echo " CloudFront invalidation created: $INVALIDATION_ID"

# Wait for invalidation to complete
echo " Waiting for invalidation to complete..."
aws cloudfront wait invalidation-completed \
    --distribution-id $CLOUDFRONT_DISTRIBUTION_ID \
    --id $INVALIDATION_ID \
    --region $AWS_REGION

# Update deployment tracking
DEPLOYMENT_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
GIT_COMMIT=$(git rev-parse --short HEAD)
GIT_BRANCH=$(git branch --show-current)

echo " Creating deployment record..."
cat > deployment-info.json << EOF
{
    "deployment_time": "$DEPLOYMENT_TIME",
    "git_commit": "$GIT_COMMIT",
    "git_branch": "$GIT_BRANCH",
    "build_version": "$(node -p "require('./package.json').version")",
    "environment": "$NODE_ENV",
    "s3_bucket": "$S3_BUCKET",
    "cloudfront_distribution": "$CLOUDFRONT_DISTRIBUTION_ID"
}
EOF

aws s3 cp deployment-info.json s3://$S3_BUCKET/deployment-info.json \
    --cache-control "public, max-age=300" \
    --content-type "application/json" \
    --region $AWS_REGION

# Send deployment notification (optional)
if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
    echo " Sending deployment notification..."
    curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"✅ Frontend deployed to $NODE_ENV\n• Commit: $GIT_COMMIT\n• Branch: $GIT_BRANCH\n• S3: $S3_BUCKET\n• Time: $DEPLOYMENT_TIME\"}" \
        $SLACK_WEBHOOK_URL
fi

echo " Frontend deployment completed successfully!"
echo " Your site will be available shortly at:"
echo "   https://$(aws cloudfront get-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --query 'Distribution.DomainName' --output text)"