# Free AI Router (OpenCode Zen)

OpenAI-compatible proxy untuk model AI gratis dari OpenCode Zen. No API key, no Docker, no server required.

## Features

- **Free models**: DeepSeek, MiMo, Nemotron, North Mini Code
- **OpenAI-compatible** — works with Cline, Claude Code, Cursor, any OpenAI client
- **Streaming support**
- **Cloudflare Tunnel** — akses dari mana saja via URL publik
- **No registration, no API key, no billing**

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/rahadiana/free_ai/main/install-free.sh | bash
```

Atau jalanin manual:

```bash
# Download script
wget https://raw.githubusercontent.com/rahadiana/free_ai/main/install-free.sh
chmod +x install-free.sh

# Install (Node.js + cloudflared auto-installed)
./install-free.sh
```

## Manual Setup (tanpa script)

```bash
# Install dependencies
npm install -g node  # atau pake package manager lo
```

Buat file `free-router.js`, copy dari repo ini, lalu:

```bash
node free-router.js &
```

Cloudflare tunnel (opsional):

```bash
cloudflared tunnel --url http://localhost:20128
```

## Usage

Point AI tool lo ke:

```
Base URL: http://localhost:20128/v1
          atau https://[tunnel-url].trycloudflare.com/v1
API Key:  (kosong / anything)
Model:    mimo
```

### Available Models

| Short Alias | Full Model ID |
|---|---|
| `mimo` | `mimo-v2.5-free` |
| `deepseek` | `deepseek-v4-flash-free` |
| `nemotron` | `nemotron-3-ultra-free` |
| `north` | `north-mini-code-free` |

### Test with curl

```bash
curl http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mimo","messages":[{"role":"user","content":"halo"}],"max_tokens":100}'
```

### Models list

```bash
curl http://localhost:20128/v1/models
```

## Architecture

```
Your AI Tool (Cline/Cursor/etc)
       ↓ OpenAI-compatible API
Free Router (Node.js proxy)
       ↓
OpenCode Zen API (opencode.ai/zen/v1)
       ↓
Free AI Models (DeepSeek, MiMo, etc)
```

## Files

| File | Description |
|---|---|
| `install-free.sh` | One-click installer (Node.js + cloudflared + proxy) |
| `free-router.js` | Standalone Node.js proxy server |

## Notes

- Qwen3.6 Plus Free dan MiniMax M3 Free sudah expired
- Cloudflare quick tunnel URL berubah setiap restart (kecuali pake named tunnel berbayar)
- Proxy ini cuma nerusin request ke OpenCode Zen — data lo ga disimpan
