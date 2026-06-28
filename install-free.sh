#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/free-router"
PORT="${PORT:-20128}"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Free Router Installer (no Docker)    ${NC}"
echo -e "${CYAN}========================================${NC}"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null; then SUDO="sudo"; fi

# Node.js
if ! command -v node &>/dev/null; then
  echo -e "${YELLOW}[..]${NC} Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash -
  $SUDO apt-get install -y nodejs
fi
echo -e "${GREEN}[OK]${NC} Node.js $(node -v)"

# cloudflared
CF="${CLOUDFLARED:-$HOME/.local/bin/cloudflared}"
mkdir -p "$HOME/.local/bin"
if ! command -v "$CF" &>/dev/null; then
  echo -e "${YELLOW}[..]${NC} Installing cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf && mv /tmp/cf "$CF"
fi
echo -e "${GREEN}[OK]${NC} cloudflared $("$CF" version | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+')"

# free-router
mkdir -p "$APP_DIR"
cat > "$APP_DIR/free-router.js" << 'SCRIPT'
const http = require('http');
const https = require('https');
const PORT = parseInt(process.env.PORT || '20128');
const HOST = process.env.HOST || '0.0.0.0';
const ZEN_URL = 'https://opencode.ai/zen/v1';
const MODELS_URL = 'https://opencode.ai/zen/v1/models';
const FREE_MODELS = ['deepseek-v4-flash-free','mimo-v2.5-free','nemotron-3-ultra-free','north-mini-code-free'];
const ROUTE = {deepseek:'deepseek-v4-flash-free',mimo:'mimo-v2.5-free',nemotron:'nemotron-3-ultra-free',north:'north-mini-code-free'};

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const opts = {hostname:u.hostname,port:u.port||443,path:u.pathname+u.search,method:'GET',headers:{'User-Agent':'free-router/1.0'},timeout:15000};
    const r = mod.request(opts,(res)=>{let d='';res.on('data',c=>d+=c);res.on('end',()=>{try{resolve(JSON.parse(d))}catch{resolve(d)}});});
    r.on('error',reject);r.on('timeout',()=>{r.destroy();reject(new Error('timeout'));});r.end();
  });
}

http.createServer((req,res)=>{
  const url = new URL(req.url,`http://${req.headers.host}`);
  const p = url.pathname;
  res.setHeader('Access-Control-Allow-Origin','*');
  res.setHeader('Access-Control-Allow-Methods','GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers','*');
  if(req.method==='OPTIONS'){res.writeHead(204);res.end();return;}
  if(p==='/v1/models'&&req.method==='GET'){
    return fetchJson(MODELS_URL).then(d=>{d.data=d.data.filter(m=>FREE_MODELS.includes(m.id));res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(d));}).catch(e=>{res.writeHead(500);res.end(JSON.stringify({error:e.message}));});
  }
  if(p==='/v1/chat/completions'&&req.method==='POST'){
    let body='';req.on('data',c=>body+=c);req.on('end',()=>{
      try{
        const parsed=JSON.parse(body);let model=parsed.model||'';
        if(ROUTE[model]){model=ROUTE[model];parsed.model=model;}
        if(!FREE_MODELS.includes(model)){res.writeHead(403);res.end(JSON.stringify({error:`Use: ${FREE_MODELS.join(', ')}`}));return;}
        const u=new URL(ZEN_URL+'/chat/completions');const mod=u.protocol==='https:'?https:http;const bodyStr=JSON.stringify(parsed);
        const opts={hostname:u.hostname,port:u.port||443,path:u.pathname+u.search,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(bodyStr),'User-Agent':'free-router/1.0'},timeout:120000};
        const pr=mod.request(opts,pr=>{if(parsed.stream){res.writeHead(pr.statusCode,{'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive'});pr.pipe(res);}else{let d='';pr.on('data',c=>d+=c);pr.on('end',()=>{res.writeHead(pr.statusCode,{'Content-Type':'application/json'});res.end(d);});}});
        pr.on('error',e=>{res.writeHead(502);res.end(JSON.stringify({error:e.message}));});pr.write(bodyStr);pr.end();
      }catch(e){res.writeHead(400);res.end(JSON.stringify({error:'invalid json'}));}
    });return;
  }
  if(p==='/'||p==='/health'){res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({status:'ok',free_models:FREE_MODELS,port:PORT}));return;}
  res.writeHead(404);res.end();
}).listen(PORT,HOST,()=>console.log(`Free Router on http://${HOST}:${PORT} | models: ${FREE_MODELS.join(', ')}`));
SCRIPT

# Stop old
lsof -ti :"$PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true
node "$APP_DIR/free-router.js" &
echo $! > "$APP_DIR/pid"
disown
sleep 2

# Tunnel
nohup "$CF" tunnel --url "http://localhost:$PORT" > "$APP_DIR/tunnel.log" 2>&1 &
echo $! > "$APP_DIR/tunnel.pid"
disown
sleep 5
TUNNEL_URL=$(grep -oP 'https://[a-z-]+\.trycloudflare\.com' "$APP_DIR/tunnel.log" | head -1)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}        READY!                          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Local:   ${CYAN}http://localhost:$PORT/v1${NC}"
echo -e "  Global:  ${CYAN}$TUNNEL_URL/v1${NC}"
echo ""
echo -e "  Models:  mimo / deepseek / nemotron / north"
echo ""
echo -e "  ${YELLOW}Cline / Claude Code / Cursor:${NC}"
echo -e "  Endpoint: $TUNNEL_URL/v1"
echo -e "  Model:    mimo"
echo ""
echo -e "  Stop:    kill \$(cat $APP_DIR/pid) \$(cat $APP_DIR/tunnel.pid)"
echo -e "  Start:   node $APP_DIR/free-router.js &"
echo ""
