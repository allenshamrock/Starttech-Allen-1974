#!/bin/bash

# Frontend Deployment Script for Vite
set -e  

echo " Starting frontend deployment..."

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Required environment variables
S3_BUCKET=${S3_BUCKET:-"starttech-frontend"}
CLOUDFRONT_DISTRIBUTION_ID=${CLOUDFRONT_DISTRIBUTION_ID}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo " Environment:"
echo "   S3 Bucket: $S3_BUCKET"
echo "   Region: $AWS_REGION"
echo "   CloudFront ID: $CLOUDFRONT_DISTRIBUTION_ID"

# Validate required variables
if [[ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]]; then
    echo " ERROR: CLOUDFRONT_DISTRIBUTION_ID is not set"
    exit 1
fi

# Verify build exists (already built by workflow)
echo "🔍 Verifying build..."
if [ ! -d "dist" ]; then
    echo " ERROR: dist/ directory not found"
    echo "   Vite outputs to dist/, not build/"
    exit 1
fi

echo " Build size:"
du -sh dist/
echo " Files in dist/:"
ls -la dist/

# Sync to S3 with proper caching headers
echo " Uploading to S3 bucket: $S3_BUCKET..."
aws s3 sync dist/ s3://$S3_BUCKET/ \
    --delete \
    --cache-control "public, max-age=31536000, immutable" \
    --exclude "*.html" \
    --region $AWS_REGION

# Upload HTML files with shorter cache
echo " Uploading HTML files..."
aws s3 sync dist/ s3://$S3_BUCKET/ \
    --exclude "*" \
    --include "*.html" \
    --cache-control "public, max-age=0, must-revalidate" \
    --content-type "text/html; charset=utf-8" \
    --region $AWS_REGION

# Upload service worker and manifest if they exist
if [ -f "dist/service-worker.js" ]; then  
    echo "⚙️ Uploading service worker..."
    aws s3 cp dist/service-worker.js s3://$S3_BUCKET/service-worker.js \
        --cache-control "public, max-age=0, must-revalidate" \
        --region $AWS_REGION
fi

if [ -f "dist/manifest.json" ]; then  
    echo " Uploading manifest..."
    aws s3 cp dist/manifest.json s3://$S3_BUCKET/manifest.json \
        --cache-control "public, max-age=3600" \
        --content-type "application/json" \
        --region $AWS_REGION
fi

# Invalidate CloudFront cache
echo " Invalidating CloudFront cache..."
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
    "environment": "production",
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
        --data "{\"text\":\" Frontend deployed\n• Commit: $GIT_COMMIT\n• S3: $S3_BUCKET\n• Time: $DEPLOYMENT_TIME\"}" \
        "$SLACK_WEBHOOK_URL"
fi

echo " Frontend deployment completed successfully!"

# Get CloudFront domain
CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CLOUDFRONT_DISTRIBUTION_ID" \
    --query 'Distribution.DomainName' \
    --output text)

echo "Your site is available at:"
echo "   https://$CLOUDFRONT_DOMAIN"