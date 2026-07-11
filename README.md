# Free AI Router — Docker Container

OpenAI-compatible proxy untuk model AI dari OpenCode Zen. **Zero Node.js** — pure Go static binary (~5 MB) dalam container Alpine Linux. Dilengkapi **Cloudflare WARP VPN** untuk proteksi IP + auto-reconnect saat kena rate limit.

## Features

- **All models** — 50+ model, gratis & paid (butuh API key untuk paid)
- **Go static binary** — event-driven concurrency, ribuan request parallel
- **Cloudflare WARP VPN** — ganti IP otomatis via WireGuard
- **Multi-endpoint + Fallback Port** — 3 IP WARP × 4 UDP port (2408, 500, 1701, 4500)
- **Auto WARP Reconnect** — saat upstream return non-200/non-401, WARP disconnect + reconnect (ganti IP & port)
- **Auto-disable WARP** — kalo semua endpoint gagal, WARP dimatiin, proxy tetap jalan
- **Streaming support** — SSE (Server-Sent Events)
- **OpenAI-compatible** — works with Cline, Claude Code, Cursor, any OpenAI client
- **No Node.js** — pure Go + shell, image cuma 31 MB
- **Alpine Linux** — lightweight, secure

## Prerequisites

### 1. Docker

- [Docker Engine](https://docs.docker.com/engine/install/) (26.x+) + Docker Compose v2

### 2. Linux Kernel Modules (untuk WARP VPN)

WARP VPN butuh WireGuard di host. Jalankan **sekali** sebelum start container:

```bash
sudo modprobe wireguard
sudo modprobe ip_tables
sudo modprobe ip6_tables
```

> Atau biar permanent, tambah ke `/etc/modules-load.d/warp.conf`:
> ```
> wireguard
> ip_tables
> ip6_tables
> ```

### 3. TUN Device

Pastikan `/dev/net/tun` ada di host:
```bash
ls -la /dev/net/tun
# → crw-rw-rw- 1 root root 10, 200 ...
```

## Quick Start

### Opsi A — Docker Compose (Recommended)

```bash
git clone https://github.com/rahadiana/free_ai.git
cd free_ai
docker compose up -d --build
```

Container langsung jalan dengan WARP + proxy di port `20128`.

> **Tanpa WARP** (lingkungan tanpa TUN device / tidak butuh VPN):
> ```bash
> WARP_ENABLED=false docker compose up -d --build
> ```
>
> Atau simpan di file `.env` biar permanent:
> ```bash
> echo "WARP_ENABLED=false" >> .env
> docker compose up -d --build
> ```

### Opsi B — Docker Run

**Build image dulu:**
```bash
docker build -t free-ai-router .
```

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
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -p 20128:20128 \
  free-ai-router
```

**Dengan volume persistensi + port kustom:**
```bash
docker run -d \
  --name free-ai \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -p 8080:8080 \
  -e PORT=8080 \
  -v ./free-ai-data:/data \
  free-ai-router
```

## Usage with OpenCode

Cara configure Free AI Router sebagai provider di OpenCode:

### 1. Add credential

Di TUI OpenCode, jalankan:

```
/connect
```

Pilih **Other** → enter provider ID `freeai` → enter API key kosong (enter aja).

### 2. Config file

Buat `opencode.json` di root project:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "freeai": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Free AI Router",
      "options": {
        "baseURL": "http://localhost:20128/v1"
      },
      "models": {
        "deepseek-v4-flash-free": {
          "id": "deepseek-v4-flash-free",
          "name": "DeepSeek V4 Flash Free",
          "reasoning": true,
          "tool_call": true,
          "limit": {
            "context": 1000000,
            "output": 384000
          },
          "modalities": {
            "input": ["text"],
            "output": ["text"]
          }
        },
        "mimo-v2.5-free": {
          "id": "mimo-v2.5-free",
          "name": "MiMo V2.5 Free",
          "reasoning": true,
          "tool_call": true,
          "limit": {
            "context": 1000000,
            "output": 131072
          },
          "modalities": {
            "input": ["text", "image", "video", "audio"],
            "output": ["text"]
          }
        },
        "nemotron-3-ultra-free": {
          "id": "nemotron-3-ultra-free",
          "name": "Nemotron 3 Ultra Free",
          "reasoning": true,
          "tool_call": true,
          "limit": {
            "context": 1000000,
            "output": 131072
          },
          "modalities": {
            "input": ["text"],
            "output": ["text"]
          }
        },
        "north-mini-code-free": {
          "id": "north-mini-code-free",
          "name": "North Mini Code Free",
          "reasoning": false,
          "tool_call": true,
          "limit": {
            "context": 1000000,
            "output": 131072
          },
          "modalities": {
            "input": ["text"],
            "output": ["text"]
          }
        },
        "hy3-free": {
          "id": "hy3-free",
          "name": "HY3 Free",
          "reasoning": true,
          "tool_call": true,
          "limit": {
            "context": 1000000,
            "output": 131072
          },
          "modalities": {
            "input": ["text"],
            "output": ["text"]
          }
        }
      }
    }
  }
}
```

### 3. Pilih model

Jalankan `/models` di OpenCode → pilih model Free AI Router.

> Semua 50+ model dari Zen API juga available — tinggal tambahin ke `models` di config.

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

Semua variable bisa di-set langsung (`-e` flag) atau via file `.env` untuk docker-compose.

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `20128` | Port proxy |
| `HOST` | `0.0.0.0` | Listen address |
| `WARP_ENABLED` | `true` | Aktifkan Cloudflare WARP VPN. Set `false` untuk mode tanpa WARP |
| `WARP_RECONNECT_ON_ERROR` | `true` | Auto reconnect WARP saat upstream error |
| `WARP_ERROR_THRESHOLD` | `2` | Jumlah error berturut-turut sebelum reconnect |
| `WARP_LICENSE` | `(empty)` | License key WARP+ |
| `WARP_ENDPOINTS` | `162.159.192.1 162.159.193.6 162.159.193.5` | Daftar IP WARP endpoint |
| `WARP_PORTS` | `2408 500 1701 4500` | Daftar UDP port WARP (fallback sequence) |
| `WARP_MAX_RETRIES` | `15` | Maks percobaan sebelum auto-disable WARP |
| `DATA_DIR` | `/data` | Direktori persistensi WARP config |

## WARP Reconnect Logic

```
Upstream response:
  ├── 200 → success, reset error counter
  ├── 401 → AuthError (missing API key), skip
  └── lainnya (3xx, 403, 429, 502, dll) → trigger WARP reconnect
```

Setelah N kali error (default 2), proxy nulis trigger file → entrypoint detek → disconnect → **cycle ke endpoint:port berikutnya** → reconnect → **IP baru**.

### Multi-endpoint & Fallback Port Cycle

WARP otomatis cycle melalui kombinasi IP endpoint + port setiap kali reconnect:

| # | Endpoint:Port | Keterangan |
|---|--------------|------------|
| 0 | `162.159.192.1:2408` | IP utama, port default |
| 1 | `162.159.192.1:500` | IP utama, fallback port |
| 2 | `162.159.192.1:1701` | IP utama, fallback port |
| 3 | `162.159.192.1:4500` | IP utama, fallback port |
| 4 | `162.159.193.6:2408` | IP alternatif, port default |
| ... | ... | ... |
| 11 | `162.159.193.5:4500` | IP terakhir, port terakhir |

Kalo semua 12 kombinasi gagal setelah `WARP_MAX_RETRIES` percobaan (default 15), WARP **auto-disable** — proxy tetap jalan tanpa VPN.

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

## Troubleshooting

### Container jalan tapi endpoint "Connection reset by peer"

Penyebab: WARP routing (`AllowedIPs = 0.0.0.0/0`) mengganggu koneksi lokal ke proxy.

**Solusi:** Set `WARP_ENABLED=false` atau pastikan container punya akses TUN device yang benar.

### Error `/app/entrypoint.sh: local: line 457: not in a function`

Penyebab: Keyword `local` dipakai di luar fungsi di shell Alpine (busybox ash).

**Solusi:** Update entrypoint.sh — hapus keyword `local` di global scope. (Sudah di-fix di versi terbaru.)

### WARP connect gagal — "TUN device not found"

```bash
# Pastikan TUN device ada di host
ls -la /dev/net/tun

# Load kernel modules
sudo modprobe wireguard
sudo modprobe ip_tables
sudo modprobe ip6_tables
```

### Port 20128 sudah dipakai

```bash
# Cek pemakai port
ss -tlnp | grep 20128

# Ganti port
HOST_PORT=20130 docker compose up -d
```

## Notes

- **Free models** bisa langsung dipake tanpa API key
- **Paid models** (Claude, GPT, Gemini, dll) butuh API key dari OpenCode Zen
- Cloudflare WARP membutuhkan `--cap-add=NET_ADMIN` dan akses `/dev/net/tun` (sudah di `docker-compose.yml`)
- WARP config tersimpan di `/data` — survive container restart
- WARP otomatis fallback ke UDP port 500/1701/4500 kalo port 2408 diblokir
- Kalo semua endpoint WARP gagal, WARP auto-disable — proxy tetap jalan normal
- Proxy ini cuma nerusin request — data lo ga disimpan
