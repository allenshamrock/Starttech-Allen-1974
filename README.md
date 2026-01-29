# StartTech-Allen-1974
# StartTech - Full Stack Task Management Application

A modern, scalable task management application built with React frontend and Golang backend, deployed on AWS infrastructure.

## Architecture

- **Frontend**: React (deployed to S3 + CloudFront)
- **Backend**: Golang with Gin framework (deployed to EC2 with Auto Scaling)
- **Database**: MongoDB Atlas
- **Cache**: Redis (ElastiCache)
- **Infrastructure**: AWS (VPC, ALB, ASG, S3, CloudFront)

## Prerequisites

- Node.js 18+
- Go 1.21+
- Docker
- AWS Account
- MongoDB Atlas account
- GitHub account

## Local Development

### Frontend
```bash
cd frontend
npm install
REACT_APP_API_URL=http://localhost:8080 npm start
```

Frontend runs on: http://localhost:3000

### Backend
```bash
cd backend
go mod download
export MONGODB_URL="your-mongodb-url"
export REDIS_URL="localhost:6379"
go run main.go
```

Backend runs on: http://localhost:8080

## Environment Variables

See `.env.example` for required environment variables.

## Deployment

### Frontend (to S3)
```bash
./scripts/deploy-frontend.sh
```

### Backend (to Docker Hub)
```bash
./scripts/deploy-backend.sh
```

## CI/CD Pipelines

- **Frontend**: Automated tests, build, and deploy to S3 on push to main
- **Backend**: Automated tests, Docker build, and push to Docker Hub on push to main

## API Endpoints

- `GET /health` - Health check
- `GET /tasks` - Get all tasks
- `POST /tasks` - Create new task
- `DELETE /tasks/:id` - Delete task

## Monitoring

CloudWatch logs are available at:
- Frontend: `/aws/starttech/frontend`
- Backend: `/aws/starttech/backend`

## Troubleshooting

See the main `StartTech-infra` repository for infrastructure troubleshooting.