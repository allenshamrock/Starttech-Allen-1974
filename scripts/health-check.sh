#!/bin/bash
# Health check script for the backend service
curl -f http://localhost:8080/health || exit 1
echo "Backend service is healthy."
exit 0
