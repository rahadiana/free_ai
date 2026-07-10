# Free AI Router — Docker Container

OpenAI-compatible proxy untuk model AI dari OpenCode Zen. **Zero Node.js** — pure Go static binary (~5 MB) dalam container Alpine Linux. Dilengkapi **Cloudflare WARP VPN** untuk proteksi IP + auto-reconnect saat kena rate limit.

## Features

- **All models** — 50+ model, gratis & paid (butuh API key untuk paid)
- **Go static binary** — event-driven concurrency, ribuan request parallel
- **Cloudflare WARP VPN** — ganti IP otomatis via WireGuard
- **Auto WARP Reconnect** — saat upstream return non-200/non-401, WARP disconnect + reconnect (ganti IP)
- **Streaming support** — SSE (Server-Sent Events)
- **OpenAI-compatible** — works with Cline, Claude Code, Cursor, any OpenAI client
- **No Node.js** — pure Go + shell, image cuma 31 MB
- **Alpine Linux** — lightweight, secure

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/engine/install/)
- Untuk WARP VPN: `--privileged` atau `--cap-add=NET_ADMIN --device /dev/net/tun`

### 1. Build Image

```bash
git clone https://github.com/rahadiana/free_ai.git
cd free_ai
docker build -t free-ai-router .
```

### 2. Run Container

**Mode tanpa WARP** (hanya proxy — ringan):

```bash
docker run -d \
  --name free-ai \
  -p 20128:20128 \
  -e WARP_ENABLED=false \
  free-ai-router
```

**Mode dengan WARP VPN** (proteksi IP):

```bash
docker run -d \
  --name free-ai \
  --privileged \
  -p 20128:20128 \
  free-ai-router
```

**Dengan volume persistensi + port kustom:**

```bash
docker run -d \
  --name free-ai \
  --privileged \
  -p 8080:8080 \
  -e PORT=8080 \
  -v ./free-ai-data:/data \
  free-ai-router
```

## Usage

Point AI tool lo ke:

```
Base URL: http://localhost:20128/v1
API Key:  (kosong untuk free model, isi untuk paid model)
Model:    deepseek  (atau full ID model)
```

### Test with curl

```bash
# Models list
curl http://localhost:20128/v1/models

# Chat (free model — pake alias)
curl http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mimo","messages":[{"role":"user","content":"halo"}],"max_tokens":100}'

# Chat (streaming)
curl -N http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek","messages":[{"role":"user","content":"ceritakan dongeng"}],"stream":true}'

# Health check
curl http://localhost:20128/health
```

### Model Aliases

| Short Alias | Full Model ID |
|-------------|---------------|
| `deepseek` | `deepseek-v4-flash-free` |
| `mimo` | `mimo-v2.5-free` |
| `hy3` | `hy3-free` |
| `nemotron` | `nemotron-3-ultra-free` |
| `north` | `north-mini-code-free` |

Semua model lain bisa dipake langsung dengan full ID-nya (lihat `/v1/models`).

## Architecture

```
Your AI Tool (Cline/Cursor/etc)
       ↓ OpenAI-compatible API
Free Router (Go binary — event-driven)
       ↓ proxy via http.Client
OpenCode Zen API (opencode.ai/zen/v1)
       ↓
50+ AI Models (DeepSeek, Claude, GPT, Gemini, MiMo, dll)
       ↓
[Opsional] Cloudflare WARP VPN
       ↓ WireGuard tunnel
WARP disconnect/reconnect otomatis saat error non-200/non-401
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `20128` | Port proxy |
| `HOST` | `0.0.0.0` | Listen address |
| `WARP_ENABLED` | `true` | Aktifkan Cloudflare WARP VPN |
| `WARP_RECONNECT_ON_ERROR` | `true` | Auto reconnect WARP saat upstream error |
| `WARP_ERROR_THRESHOLD` | `2` | Jumlah error berturut-turut sebelum reconnect |
| `WARP_LICENSE` | `(empty)` | License key WARP+ |
| `DATA_DIR` | `/data` | Direktori persistensi WARP config |

## WARP Reconnect Logic

```
Upstream response:
  ├── 200 → success, reset error counter
  ├── 401 → AuthError (missing API key), skip
  └── lainnya (403, 429, 502, dll) → trigger WARP reconnect
```

Setelah N kali error (default 2), proxy nulis trigger file → entrypoint detek → disconnect WARP → reconnect → **IP baru**.

## Container Details

| Metric | Value |
|--------|-------|
| **Base image** | Alpine Linux 3.20 |
| **Runtime** | Go static binary (5.6 MB) |
| **Image size** | 31 MB |
| **Proxy** | Go `net/http` (event-driven) |
| **WARP** | wireguard-tools + wireguard-go (fallback) |
| **Concurrency** | Ribuan goroutines parallel |

## Files

| File | Description |
|------|-------------|
| `Dockerfile` | Multi-stage build (Go builder + Alpine runtime) |
| `free-router.go` | Go HTTP proxy server (stdlib-only) |
| `entrypoint.sh` | Container startup script (WARP + proxy) |

## Notes

- **Free models** bisa langsung dipake tanpa API key
- **Paid models** (Claude, GPT, Gemini, dll) butuh API key dari OpenCode Zen
- Cloudflare WARP membutuhkan `--privileged` untuk akses TUN device
- WARP config tersimpan di `/data` — survive container restart
- Proxy ini cuma nerusin request — data lo ga disimpan
