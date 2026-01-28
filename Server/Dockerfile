FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o backend .

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/backend .
EXPOSE 8080
CMD ["./Server"]