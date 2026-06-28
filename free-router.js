const http = require('http');
const https = require('https');

const PORT = 20128;
const HOST = '0.0.0.0';

const ZEN_URL = 'https://opencode.ai/zen/v1';
const MODELS_URL = 'https://opencode.ai/zen/v1/models';

const FREE_MODELS = [
  'deepseek-v4-flash-free',
  'mimo-v2.5-free',
  'nemotron-3-ultra-free',
  'north-mini-code-free',
];

function fetchJson(url, options = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const opts = {
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      method: options.method || 'GET',
      headers: { 'User-Agent': 'free-router/1.0', ...options.headers },
      timeout: 30000,
    };
    const req = mod.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    if (options.body) req.write(options.body);
    req.end();
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Models list
  if (path === '/v1/models' && req.method === 'GET') {
    fetchJson(MODELS_URL).then((data) => {
      data.data = data.data.filter(m => FREE_MODELS.includes(m.id));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    }).catch((err) => {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    });
    return;
  }

  // Chat completions
  if (path === '/v1/chat/completions' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => body += chunk);
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body);

        const ROUTE = {
          'deepseek': 'deepseek-v4-flash-free',
          'mimo': 'mimo-v2.5-free',
          'nemotron': 'nemotron-3-ultra-free',
          'north': 'north-mini-code-free',
        };

        let model = parsed.model || '';
        if (ROUTE[model]) {
          model = ROUTE[model];
          parsed.model = model;
        }

        if (!FREE_MODELS.includes(model)) {
          res.writeHead(403, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            error: `Model '${model}' not in free list. Use one of: ${FREE_MODELS.join(', ')}`
          }));
          return;
        }

        // Proxy to OpenCode Zen
        const fullUrl = `${ZEN_URL}/chat/completions`;
        const u = new URL(fullUrl);
        const mod = u.protocol === 'https:' ? https : http;
        const bodyStr = JSON.stringify(parsed);

        const opts = {
          hostname: u.hostname,
          port: u.port || (u.protocol === 'https:' ? 443 : 80),
          path: u.pathname + u.search,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(bodyStr),
            'User-Agent': 'free-router/1.0',
          },
          timeout: 120000,
        };

        const proxyReq = mod.request(opts, (proxyRes) => {
          if (parsed.stream) {
            res.writeHead(proxyRes.statusCode, {
              'Content-Type': 'text/event-stream',
              'Cache-Control': 'no-cache',
              'Connection': 'keep-alive',
            });
            proxyRes.pipe(res);
          } else {
            let data = '';
            proxyRes.on('data', chunk => data += chunk);
            proxyRes.on('end', () => {
              res.writeHead(proxyRes.statusCode, { 'Content-Type': 'application/json' });
              res.end(data);
            });
          }
        });

        proxyReq.on('error', (err) => {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: err.message }));
        });

        proxyReq.write(bodyStr);
        proxyReq.end();
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'invalid json' }));
      }
    });
    return;
  }

  if (path === '/health' || path === '/') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      free_models: FREE_MODELS,
      zen_endpoint: ZEN_URL,
    }));
    return;
  }

  res.writeHead(404);
  res.end();
});

server.listen(PORT, HOST, () => {
  console.log(`Free Router running on http://${HOST}:${PORT}`);
  console.log(`Zen API: ${ZEN_URL}`);
  console.log(`Free models (${FREE_MODELS.length}):`);
  FREE_MODELS.forEach(m => console.log(`  - ${m}`));
});
