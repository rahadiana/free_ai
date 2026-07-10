#!/bin/sh
# =============================================================================
# Entrypoint: Free AI Router + Cloudflare WARP
# =============================================================================
# Urutan startup:
#   1. Setup WARP via WireGuard (koneksi VPN)
#   2. Jalankan free-router (Go LLM proxy OpenAI-compatible)
#   3. Monitor keduanya dengan auto-heal
# =============================================================================
set -euo pipefail

# ── Konfigurasi ──────────────────────────────────────────────────────────────
PORT="${PORT:-20128}"
HOST="${HOST:-0.0.0.0}"
WARP_ENABLED="${WARP_ENABLED:-true}"
DATA_DIR="${DATA_DIR:-/data}"
WARP_CONFIG="${DATA_DIR}/warp.conf"
WARP_ACCOUNT="${DATA_DIR}/warp-account.json"
WARP_LICENSE="${WARP_LICENSE:-}"
WARP_RECONNECT_ON_ERROR="${WARP_RECONNECT_ON_ERROR:-true}"
WARP_TRIGGER_FILE="/tmp/warp-reconnect"

# Cloudflare WARP API & endpoint
WARP_API="https://api.cloudflareclient.com/v0a884"
WARP_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_INTERFACE="warp"

# ── Multi-endpoint & fallback ──────────────────────────────────────────────────
# Multiple WARP IP endpoints + fallback UDP ports (official Cloudflare docs)
# https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/deployment/firewall/
WARP_ENDPOINTS="${WARP_ENDPOINTS:-162.159.192.1 162.159.193.6 162.159.193.5}"
WARP_PORTS="${WARP_PORTS:-2408 500 1701 4500}"
WARP_MAX_RETRIES="${WARP_MAX_RETRIES:-15}"
WARP_RETRY_COUNT=0  # global counter: reset after successful connect, disable after max
WARP_EP_IDX=0       # linear index endpoint:port (0 = first IP + first port)

# Colors
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()  { printf "${GREEN}[$(date '+%H:%M:%S')]${NC} %s\n" "$1"; }
info() { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
err()  { printf "${RED}[ERR]${NC} %s\n" "$1"; }

# ── Trap cleanup ──────────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down..."
    if [ -n "${PROXY_PID:-}" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    if [ "$WARP_ENABLED" = "true" ] && [ -f "/etc/wireguard/${WARP_INTERFACE}.conf" ]; then
        info "Disconnecting WARP..."
        wg-quick down "$WARP_INTERFACE" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ── Utility ───────────────────────────────────────────────────────────────────
rand_str() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$1"; }

# ── Check if running with enough privileges for WARP ────────────────────────
check_warp_capabilities() {
    # Cek TUN device
    if [ ! -c /dev/net/tun ]; then
        warn "TUN device (/dev/net/tun) tidak ditemukan."
        warn "Jalankan container dengan: --device /dev/net/tun:/dev/net/tun --cap-add=NET_ADMIN"
        return 1
    fi

    # Cek NET_ADMIN capability
    if ! ip link show lo >/dev/null 2>&1; then
        warn "Tidak punya NET_ADMIN capability."
        warn "Jalankan container dengan: --cap-add=NET_ADMIN"
        return 1
    fi

    # Cek apakah wireguard-go atau kernel module tersedia
    if lsmod 2>/dev/null | grep -q wireguard; then
        export WG_QUICK_USERSPACE_IMPLEMENTATION=""
        info "WireGuard: kernel module tersedia"
    elif command -v wireguard-go &>/dev/null; then
        export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
        info "WireGuard: menggunakan wireguard-go (userspace)"
    else
        err "Tidak ada WireGuard kernel module maupun wireguard-go!"
        return 1
    fi
    return 0
}

# ── Setup resolvconf untuk wg-quick ──────────────────────────────────────────
setup_resolvconf() {
    mkdir -p /etc/resolvconf.conf.d /etc/resolvconf/resolv.conf.d
    echo "resolv_conf=/etc/resolv.conf" > /etc/resolvconf.conf
    echo "nameserver 1.1.1.1" > /etc/resolvconf/resolv.conf.d/head
    echo "nameserver 1.0.0.1" >> /etc/resolvconf/resolv.conf.d/head
}

# ── Helper: hitung total kombinasi endpoint:port ──────────────────────────────
_total_combos() {
    local eps=0 ports=0
    for _ in $WARP_ENDPOINTS; do eps=$((eps + 1)); done
    for _ in $WARP_PORTS; do ports=$((ports + 1)); done
    echo $((eps * ports))
}

# ── Helper: pilih endpoint & port berikutnya ──────────────────────────────────
# Cycling: ganti port dulu (2408→500→1701→4500), baru ganti IP
# Kalo semua kombinasi habis → return 1 (exhausted / wrap around)
next_endpoint() {
    local total
    total=$(_total_combos)
    WARP_EP_IDX=$((WARP_EP_IDX + 1))
    [ "$WARP_EP_IDX" -ge "$total" ] && { WARP_EP_IDX=0; return 1; }
    return 0
}

# ── Helper: set WARP_EP dan WARP_PORT dari linear index ──────────────────────
resolve_endpoint() {
    local ports=0 ep_idx=0 port_idx=0 current=0
    for _ in $WARP_PORTS; do ports=$((ports + 1)); done

    ep_idx=$((WARP_EP_IDX / ports))
    port_idx=$((WARP_EP_IDX % ports))

    # Ambil IP ke-ep_idx
    current=0; WARP_EP=""
    for ip in $WARP_ENDPOINTS; do
        [ "$current" -eq "$ep_idx" ] && { WARP_EP="$ip"; break; }
        current=$((current + 1))
    done

    # Ambil port ke-port_idx
    current=0; WARP_PORT=""
    for p in $WARP_PORTS; do
        [ "$current" -eq "$port_idx" ] && { WARP_PORT="$p"; break; }
        current=$((current + 1))
    done

    [ -n "$WARP_EP" ] && [ -n "$WARP_PORT" ]
}

# ── Helper: cek apakah semua endpoint sudah exhausted ─────────────────────────
is_exhausted() {
    local total
    total=$(_total_combos)
    [ "$WARP_RETRY_COUNT" -ge "$WARP_MAX_RETRIES" ] || [ "$WARP_EP_IDX" -eq 0 -a "$WARP_RETRY_COUNT" -gt 0 ] && {
        [ "$WARP_RETRY_COUNT" -ge "$total" ]
        return $?
    }
    return 1
}

# ── Connect WARP (dengan retry + multi-endpoint) ──────────────────────────────
warp_connect() {
    local attempt=1

    while [ "$attempt" -le 3 ]; do
        # Resolve current endpoint dari index
        resolve_endpoint || {
            err "Endpoint index ${WARP_EP_IDX} out of range"
            return 1
        }

        info "WARP connect attempt ${attempt}/3 — ${WARP_EP}:${WARP_PORT}"

        # Update config dengan endpoint terbaru
        sed -i "s/^Endpoint = .*/Endpoint = ${WARP_EP}:${WARP_PORT}/" "$WARP_CONFIG"

        # Cleanup existing
        wg-quick down "$WARP_INTERFACE" 2>/dev/null || true

        # Copy config
        cp "$WARP_CONFIG" "/etc/wireguard/${WARP_INTERFACE}.conf"
        chmod 600 "/etc/wireguard/${WARP_INTERFACE}.conf"

        # Jalankan wg-quick
        WG_OUTPUT=$(wg-quick up "$WARP_INTERFACE" 2>&1) || true
        echo "$WG_OUTPUT" | while IFS= read -r line; do echo "  $line"; done

        # Cek apakah interface berhasil dibuat
        if ip link show "$WARP_INTERFACE" >/dev/null 2>&1; then
            # Cek handshake dalam 3 detik
            sleep 2
            if wg show "$WARP_INTERFACE" 2>/dev/null | grep -q 'latest handshake'; then
                info "Interface ${WARP_INTERFACE} berhasil — handshake OK"
                WARP_RETRY_COUNT=0
                return 0
            fi
            # Handshake belum — tunggu sebentar
            sleep 3
            if wg show "$WARP_INTERFACE" 2>/dev/null | grep -q 'latest handshake'; then
                info "Interface ${WARP_INTERFACE} berhasil — handshake OK (delayed)"
                WARP_RETRY_COUNT=0
                return 0
            fi
            info "Interface up tapi handshake belum — coba endpoint lain"
        fi

        # Gagal — cleanup dan coba endpoint/port berikutnya
        wg-quick down "$WARP_INTERFACE" 2>/dev/null || true
        WARP_RETRY_COUNT=$((WARP_RETRY_COUNT + 1))

        # Next endpoint (cycle port/IP)
        next_endpoint || WARP_RETRY_COUNT=$((WARP_RETRY_COUNT + 999))  # force exhaust

        # Cek exhaustion
        if [ "$WARP_RETRY_COUNT" -ge "$WARP_MAX_RETRIES" ]; then
            err "WARP: semua endpoint & port habis (${WARP_RETRY_COUNT} percobaan)"
            return 2  # exhausted — auto-disable
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    err "Gagal menghubungkan WARP setelah 3 percobaan"
    return 1
}

# ── Setup WARP ────────────────────────────────────────────────────────────────
setup_warp() {
    log "========================================"
    log "  Cloudflare WARP Setup"
    log "========================================"

    # Cek prasyarat
    check_warp_capabilities || return 1

    mkdir -p "$DATA_DIR"
    setup_resolvconf

    # Inisialisasi endpoint pertama
    WARP_EP_IDX=0
    resolve_endpoint || {
        err "Gagal resolve endpoint default"
        return 1
    }

    # Register atau pakai config lama
    if [ -f "$WARP_CONFIG" ] && [ -s "$WARP_CONFIG" ]; then
        info "Menggunakan konfigurasi WARP yang tersimpan"
        # Update endpoint di config lama
        sed -i "s/^Endpoint = .*/Endpoint = ${WARP_EP}:${WARP_PORT}/" "$WARP_CONFIG" 2>/dev/null || true
    else
        info "Registrasi WARP baru..."
        register_warp || return 1
    fi

    # Konek ke WARP (dengan multi-endpoint fallback)
    log "Menghubungkan ke Cloudflare WARP..."
    log "Endpoint: ${WARP_ENDPOINTS}"
    log "Ports:    ${WARP_PORTS}"

    warp_connect
    local WC_RESULT=$?
    if [ "$WC_RESULT" -eq 2 ]; then
        warn "Semua endpoint & port WARP gagal — auto-disable WARP"
        WARP_ENABLED="false"
        return 1
    elif [ "$WC_RESULT" -ne 0 ]; then
        return 1
    fi

    # Verifikasi
    sleep 3
    log "Memverifikasi koneksi WARP..."
    WARP_CHECK=$(curl -sf --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null || echo "")

    if echo "$WARP_CHECK" | grep -q 'warp=on'; then
        log "✓ Cloudflare WARP: ${GREEN}TERHUBUNG${NC}"
        echo "$WARP_CHECK" | grep -E '^(warp|ip|colo|region)' | while IFS= read -r line; do
            info "  $line"
        done
    else
        warn "WARP terkoneksi tapi warp=on belum terdeteksi."
        warn "Beberapa detik lagi biasanya aktif."
        # Coba sekali lagi setelah 5 detik
        sleep 5
        WARP_CHECK2=$(curl -sf --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null || echo "")
        if echo "$WARP_CHECK2" | grep -q 'warp=on'; then
            log "✓ Cloudflare WARP: ${GREEN}TERHUBUNG${NC} (delayed)"
            echo "$WARP_CHECK2" | grep -E '^(warp|ip|colo|region)' | while IFS= read -r line; do
                info "  $line"
            done
        else
            warn "WARP belum aktif — proxy tetap jalan."
        fi
    fi
}

# ── Register WARP ─────────────────────────────────────────────────────────────
register_warp() {
    info "Membuat key pair WireGuard..."
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    info "Public key: ${PUBLIC_KEY}"

    INSTALL_ID=$(rand_str 22)
    FCM_TOKEN="${INSTALL_ID}:APA91b$(rand_str 134)"
    TOS_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    info "Mendaftarkan device ke Cloudflare WARP..."

    RESPONSE=$(curl -sf --connect-timeout 10 -X POST "${WARP_API}/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "CF-Client-Version: a-6.10-2158" \
        -H "Content-Type: application/json" \
        -d "$(cat <<EOF
{
    "key": "${PUBLIC_KEY}",
    "install_id": "${INSTALL_ID}",
    "fcm_token": "${FCM_TOKEN}",
    "tos": "${TOS_DATE}",
    "model": "Linux",
    "serial_number": "${INSTALL_ID}",
    "locale": "en_US"
}
EOF
    )" 2>/dev/null || true)

    echo "$RESPONSE" > "$WARP_ACCOUNT"
    chmod 600 "$WARP_ACCOUNT"

    if [ -z "$RESPONSE" ]; then
        err "Gagal mendaftarkan WARP! Response kosong."
        return 1
    fi

    V4_ADDR=$(echo "$RESPONSE" | jq -r '.config.interface.addresses.v4 // "172.16.0.2/32"')
    V6_ADDR=$(echo "$RESPONSE" | jq -r '.config.interface.addresses.v6 // empty')

    info "Assigned IPv4: ${V4_ADDR}"
    [ -n "$V6_ADDR" ] && info "Assigned IPv6: ${V6_ADDR}"

    # Generate WireGuard config — routing full traffic via WARP
    cat > "$WARP_CONFIG" << WARPEOF
# Cloudflare WARP — Generated $(date -u -Iseconds)
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${V4_ADDR}
WARPEOF

    if [ -n "$V6_ADDR" ]; then
        echo "Address = ${V6_ADDR}" >> "$WARP_CONFIG"
    fi

    cat >> "$WARP_CONFIG" << WARPEOF
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = ${WARP_PUBLIC_KEY}
Endpoint = ${WARP_EP}:${WARP_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WARPEOF

    chmod 600 "$WARP_CONFIG"
    log "✓ WARP config saved"

    # License key opsional
    if [ -n "$WARP_LICENSE" ]; then
        DEVICE_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
        if [ -n "$DEVICE_ID" ]; then
            info "Mengaktifkan WARP+ license..."
            curl -sf -X PUT "${WARP_API}/reg/${DEVICE_ID}/account" \
                -H "User-Agent: okhttp/3.12.1" \
                -H "CF-Client-Version: a-6.10-2158" \
                -H "Content-Type: application/json" \
                -d "{\"license\": \"${WARP_LICENSE}\"}" >/dev/null 2>&1 && \
            log "✓ WARP+ activated!" || \
            warn "Gagal mengaktifkan WARP+ license"
        fi
    fi
}

# ── Start Proxy ───────────────────────────────────────────────────────────────
start_proxy() {
    log "========================================"
    log "  Starting Free AI Router (Go binary)"
    log "========================================"
    info "Port: ${HOST}:${PORT}"
    info "WARP: ${WARP_ENABLED}"

    # Jalankan Go binary
    PORT="${PORT}" HOST="${HOST}" free-router &
    PROXY_PID=$!
    info "Proxy PID: ${PROXY_PID}"

    sleep 1
    if kill -0 "$PROXY_PID" 2>/dev/null; then
        log "✓ Free AI Router (Go) berjalan di http://${HOST}:${PORT}"
    else
        err "Gagal menjalankan proxy!"
        return 1
    fi
}

# ── WARP Renewal Check (background) ──────────────────────────────────────────
check_warp_renewal() {
    while true; do
        sleep 21600  # setiap 6 jam
        if [ -f "$WARP_ACCOUNT" ] && [ -f "$WARP_CONFIG" ]; then
            local AGE
            AGE=$(($(date +%s) - $(stat -c %Y "$WARP_ACCOUNT")))
            if [ "$AGE" -gt "$((25 * 24 * 60 * 60))" ]; then
                warn "WARP account expired! Re-register..."
                rm -f "$WARP_ACCOUNT" "$WARP_CONFIG"
                setup_warp
            fi
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

log "╔══════════════════════════════════════════════════════════╗"
log "║     Free AI Router + Cloudflare WARP Container         ║"
log "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: WARP ──────────────────────────────────────────────────────────────
if [ "$WARP_ENABLED" = "true" ]; then
    setup_warp || warn "WARP setup gagal — proxy tetap jalan tanpa WARP"
    check_warp_renewal &
fi

# ── Step 2: Proxy ─────────────────────────────────────────────────────────────
start_proxy || exit 1

# Tampilkan info
echo ""
info "Endpoint:  http://localhost:${PORT}/v1/chat/completions"
info "Models:    ALL models from OpenCode Zen (no filter)"
info "Health:    http://localhost:${PORT}/health"
info "WARP:      $(curl -sf --connect-timeout 3 https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null | grep warp || echo 'check logs')"
echo ""

# ── Step 3: Monitor Loop ──────────────────────────────────────────────────────
# Variabel state untuk tracking koneksi WARP
WARP_WAS_ACTIVE=false

while true; do
    # Cek proxy
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        warn "Proxy mati! Restart..."
        start_proxy || { err "Proxy crash loop — exit"; exit 1; }
    fi

    # Cek WARP trigger file (dari free-router Go binary — upstream non-2xx/non-401)
    if [ "$WARP_RECONNECT_ON_ERROR" = "true" ] && [ -f "$WARP_TRIGGER_FILE" ]; then
        local REASON
        REASON=$(cat "$WARP_TRIGGER_FILE" 2>/dev/null || echo "unknown")
        rm -f "$WARP_TRIGGER_FILE"
        warn "╔══════════════════════════════════════════════════════════╗"
        warn "║  WARP RECONNECT TRIGGERED by upstream error ${REASON} ║"
        warn "╚══════════════════════════════════════════════════════════╝"
        log "Memutus WARP dan reconnect untuk ganti IP..."

        # Disconnect
        if ip link show "$WARP_INTERFACE" >/dev/null 2>&1; then
            wg-quick down "$WARP_INTERFACE" 2>/dev/null || true
            sleep 2
        fi
        WARP_WAS_ACTIVE=false

        # Coba endpoint/port berikutnya (cycle untuk dapet IP baru)
        next_endpoint
        resolve_endpoint
        log "Mencoba endpoint: ${WARP_EP}:${WARP_PORT}"

        # Update config
        sed -i "s/^Endpoint = .*/Endpoint = ${WARP_EP}:${WARP_PORT}/" "$WARP_CONFIG" 2>/dev/null || true
        cp "$WARP_CONFIG" "/etc/wireguard/${WARP_INTERFACE}.conf" 2>/dev/null || true

        # Reconnect
        wg-quick up "$WARP_INTERFACE" 2>/dev/null || true
        sleep 5
        log "WARP reconnect selesai — endpoint ${WARP_EP}:${WARP_PORT}"
    fi

    # Cek WARP (setiap 30 detik)
    if [ "$WARP_ENABLED" = "true" ] && [ -f "/etc/wireguard/${WARP_INTERFACE}.conf" ]; then
        if ip link show "$WARP_INTERFACE" >/dev/null 2>&1; then
            # Cek handshake — kalau sudah pernah connected, reconnect kalau lost
            if wg show "$WARP_INTERFACE" 2>/dev/null | grep -q 'latest handshake'; then
                WARP_WAS_ACTIVE=true
            else
                if [ "$WARP_WAS_ACTIVE" = true ]; then
                    warn "WARP handshake lost! Coba endpoint lain..."
                    wg-quick down "$WARP_INTERFACE" 2>/dev/null || true
                    sleep 2
                    next_endpoint || true
                    resolve_endpoint
                    sed -i "s/^Endpoint = .*/Endpoint = ${WARP_EP}:${WARP_PORT}/" "$WARP_CONFIG" 2>/dev/null || true
                    cp "$WARP_CONFIG" "/etc/wireguard/${WARP_INTERFACE}.conf" 2>/dev/null || true
                    info "Mencoba ${WARP_EP}:${WARP_PORT}"
                    wg-quick up "$WARP_INTERFACE" 2>/dev/null || true
                fi
            fi
        else
            # Interface tidak ada — coba buat ulang (tapi tidak spam)
            if [ "$WARP_WAS_ACTIVE" = true ]; then
                warn "WARP interface hilang! Coba endpoint lain..."
                sleep 5
                next_endpoint || true
                resolve_endpoint
                sed -i "s/^Endpoint = .*/Endpoint = ${WARP_EP}:${WARP_PORT}/" "$WARP_CONFIG" 2>/dev/null || true
                cp "$WARP_CONFIG" "/etc/wireguard/${WARP_INTERFACE}.conf" 2>/dev/null || true
                info "Mencoba ${WARP_EP}:${WARP_PORT}"
                wg-quick up "$WARP_INTERFACE" 2>/dev/null || true
            fi
        fi
    fi

    sleep 30
done
