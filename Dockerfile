FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /app/KamadevaPriveBackend ./cmd/api

FROM alpine:3.19

WORKDIR /app

RUN apk add --no-cache ca-certificates tzdata wget \
  && addgroup -S kamadevaprive \
  && adduser -S kamadevaprive -G kamadevaprive \
  && mkdir -p /app/var/cache/samba \
  && chown -R kamadevaprive:kamadevaprive /app/var

COPY --from=builder /app/KamadevaPriveBackend /app/KamadevaPriveBackend

ENV API_PORT=8787
ENV SAMBA_CACHE_DIR=/app/var/cache/samba

USER kamadevaprive

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD wget -qO- "http://127.0.0.1:${API_PORT}/health" || exit 1

CMD ["/app/KamadevaPriveBackend"]
