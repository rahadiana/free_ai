# =============================================================================
# Free AI Router + Cloudflare WARP Container
# =============================================================================
# Runtime: Go static binary (~5 MB) — zero dependencies
# Fitur:
#   - Cloudflare WARP VPN (via WireGuard)
#   - OpenAI-compatible LLM proxy
#   - Auto-register & connect WARP saat startup
#   - Support streaming & non-streaming
#   - Auto WARP reconnect on upstream error
# =============================================================================

# =============================================================================
# Stage 1: Builder — compile Go binary + wireguard-go
# =============================================================================
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git make

# Build free-router (Go static binary)
WORKDIR /build
COPY free-router.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o free-router free-router.go

# Build wireguard-go (userspace WireGuard fallback)
RUN git clone https://git.zx2c4.com/wireguard-go /tmp/wireguard-go && \
    cd /tmp/wireguard-go && \
    make && \
    cp wireguard-go /usr/local/bin/

# =============================================================================
# Stage 2: Runtime — Alpine minimal
# =============================================================================
FROM alpine:3.20

LABEL maintainer="rahadiana"
LABEL description="Free AI Router with Cloudflare WARP — Go static binary"
LABEL version="2.0.0"

# ---------------------------------------------------------------------------
# Install runtime dependencies
# ---------------------------------------------------------------------------
# wireguard-tools  → wg, wg-quick
# iptables         → wg-quick routing
# ip6tables        → wg-quick IPv6 routing
# curl             → register WARP + health check
# jq               → WARP registration parsing
# openresolv       → resolvconf untuk wg-quick
# tini             → init system
# ---------------------------------------------------------------------------
RUN apk add --no-cache \
      wireguard-tools \
      iptables \
      ip6tables \
      curl \
      jq \
      openresolv \
      tini \
    && rm -rf /var/cache/apk/*

# Copy binary dari builder
COPY --from=builder /build/free-router /usr/local/bin/free-router
COPY --from=builder /usr/local/bin/wireguard-go /usr/local/bin/wireguard-go

# ---------------------------------------------------------------------------
# Copy entrypoint
# ---------------------------------------------------------------------------
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# ---------------------------------------------------------------------------
# Volume untuk persistensi WARP config
# ---------------------------------------------------------------------------
VOLUME [ "/data" ]

# ---------------------------------------------------------------------------
# Port proxy
# ---------------------------------------------------------------------------
EXPOSE 20128

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
ENV PORT=20128
ENV HOST=0.0.0.0
ENV WARP_ENABLED=true
ENV WARP_RECONNECT_ON_ERROR=true
ENV WARP_ERROR_THRESHOLD=2
ENV WARP_REGION=
ENV DATA_DIR=/data

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:${PORT}/health || exit 1

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
ENTRYPOINT [ "/sbin/tini", "--", "/app/entrypoint.sh" ]
