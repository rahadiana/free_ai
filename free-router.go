// =============================================================================
// Free AI Router — Go static binary
// =============================================================================
// OpenAI-compatible proxy untuk free LLM models dari OpenCode Zen.
// Zero dependencies (stdlib only), ~5 MB binary, event-driven concurrency.
// =============================================================================
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ── Konfigurasi ───────────────────────────────────────────────────────────────

var (
	port   = env("PORT", "20128")
	host   = env("HOST", "0.0.0.0")
	zenURL = env("ZEN_URL", "https://opencode.ai/zen/v1")

	// Model alias → full ID (biar bisa pake nama pendek)
	modelAliases = map[string]string{
		"deepseek": "deepseek-v4-flash-free",
		"mimo":     "mimo-v2.5-free",
		"hy3":      "hy3-free",
		"nemotron": "nemotron-3-ultra-free",
		"north":    "north-mini-code-free",
	}

	// WARP Reconnect on Error
	warpReconnectOnError = os.Getenv("WARP_RECONNECT_ON_ERROR") != "false"
	warpErrorThreshold   = intEnv("WARP_ERROR_THRESHOLD", 2)
	warpTriggerFile      = "/tmp/warp-reconnect"

	// Error counter (thread-safe)
	errMu       sync.Mutex
	errCount    int
	triggeredAt time.Time
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func intEnv(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return fallback
}

// ── WARP Trigger ──────────────────────────────────────────────────────────────

func triggerWarpReconnect(statusCode int) {
	if !warpReconnectOnError {
		return
	}
	errMu.Lock()
	defer errMu.Unlock()

	// Cooldown 30 detik setelah trigger terakhir
	if !triggeredAt.IsZero() && time.Since(triggeredAt) < 30*time.Second {
		return
	}

	errCount++
	log.Printf("[WARP] Upstream %d (error %d/%d)", statusCode, errCount, warpErrorThreshold)

	if errCount >= warpErrorThreshold {
		if err := os.WriteFile(warpTriggerFile, []byte(fmt.Sprintf("%d\n", statusCode)), 0644); err != nil {
			log.Printf("[WARP] Gagal write trigger: %v", err)
			return
		}
		triggeredAt = time.Now()
		errCount = 0
		log.Printf("[WARP] Trigger file written: %s — reconnect in progress", warpTriggerFile)
	}
}

func resetWarpError() {
	errMu.Lock()
	defer errMu.Unlock()
	if errCount > 0 {
		errCount--
	}
}

// ── HTTP Client (reusable, connection pooling) ────────────────────────────────

var httpClient = &http.Client{
	Timeout: 120 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:        100,
		IdleConnTimeout:     90 * time.Second,
		DisableCompression:  false,
	},
}

// ── CORS Middleware ───────────────────────────────────────────────────────────

func cors(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next(w, r)
	}
}

// ── Helper: JSON response ─────────────────────────────────────────────────────

func jsonResp(w http.ResponseWriter, code int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(data)
}

// ── Handler: GET /v1/models ───────────────────────────────────────────────────

func modelsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonResp(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	// Proxy langsung dari upstream — semua model, tanpa filter
	modelsURL := zenURL + "/models"
	resp, err := httpClient.Get(modelsURL)
	if err != nil {
		triggerWarpReconnect(0)
		jsonResp(w, http.StatusBadGateway, map[string]string{"error": "upstream unreachable"})
		return
	}
	defer resp.Body.Close()

	// Forward response headers
	for k, v := range resp.Header {
		for _, hv := range v {
			w.Header().Add(k, hv)
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// ── Handler: POST /v1/chat/completions ────────────────────────────────────────

func chatHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonResp(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	// Baca body
	body, err := io.ReadAll(r.Body)
	if err != nil || len(body) == 0 {
		jsonResp(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	// Parse minimal utk ambil model + stream flag
	var req struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		jsonResp(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	// Resolve model alias
	if full, ok := modelAliases[req.Model]; ok {
		body = []byte(strings.Replace(string(body), `"model":"`+req.Model+`"`, `"model":"`+full+`"`, 1))
		req.Model = full
	}

	// Proxy ke upstream
	chatURL := zenURL + "/chat/completions"
	upstreamResp, err := httpClient.Post(chatURL, "application/json", strings.NewReader(string(body)))
	if err != nil {
		triggerWarpReconnect(0)
		jsonResp(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	defer upstreamResp.Body.Close()

	// ── WARP Reconnect Logic ─────────────────────────────────────────
	// 200 = sukses → reset error counter
	// 401 = AuthError (Missing API Key) → skip, bukan masalah IP
	// Selain 200 & 401 → trigger WARP disconnect + reconnect (ganti IP)
	sc := upstreamResp.StatusCode
	if sc == 200 || sc == 401 {
		resetWarpError()
	} else {
		triggerWarpReconnect(sc)
	}

	// Forward response headers
	for k, v := range upstreamResp.Header {
		for _, hv := range v {
			w.Header().Add(k, hv)
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(sc)

	if req.Stream {
		// Streaming: pipe langsung dari upstream ke client
		io.Copy(w, upstreamResp.Body)
	} else {
		// Non-streaming: baca dulu, lalu tulis
		respBody, _ := io.ReadAll(upstreamResp.Body)
		w.Write(respBody)
	}
}

// ── Handler: GET /health ──────────────────────────────────────────────────────

func healthHandler(w http.ResponseWriter, r *http.Request) {
	jsonResp(w, http.StatusOK, map[string]interface{}{
		"status":  "ok",
		"version": "2.0.0",
	})
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", cors(modelsHandler))
	mux.HandleFunc("/v1/chat/completions", cors(chatHandler))
	mux.HandleFunc("/health", cors(healthHandler))
	mux.HandleFunc("/", cors(healthHandler))

	addr := host + ":" + port
	log.Printf("Free AI Router v2.0.0 — Go runtime")
	log.Printf("Listening on http://%s", addr)
	log.Printf("Zen API: %s", zenURL)
	log.Printf("All models from upstream (no filtering)")

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
