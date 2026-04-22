const http = require("http");
const https = require("https");
const net = require("net");
const fs = require("fs");
const path = require("path");

const PORT = 8081;
const HANDSHAKE_TIMEOUT = 3000;
const SPLIT_DELAY = 10;
const CACHE_DIR = path.join(__dirname, ".proxy-cache");
const FILTER_UPDATE_INTERVAL = 24 * 60 * 60 * 1000;

const FILTER_LISTS = [
  // uBlock Origin defaults (uAssets)
  { name: "uBlock Filters", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt" },
  { name: "uBlock Badware", url: "https://ublockorigin.github.io/uAssets/filters/badware.txt" },
  { name: "uBlock Privacy", url: "https://ublockorigin.github.io/uAssets/filters/privacy.txt" },
  { name: "uBlock Quick Fixes", url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt" },
  { name: "uBlock Unbreak", url: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt" },

  // EasyList / EasyPrivacy
  { name: "EasyList", url: "https://easylist.to/easylist/easylist.txt" },
  { name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt" },

  // Other defaults
  { name: "Peter Lowe", url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0" },
  { name: "AdGuard DNS", url: "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt" },
  { name: "URLhaus Malware", url: "https://urlhaus.abuse.ch/downloads/hostfile/" },

  // Korean
  { name: "KOR List-KR", url: "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/1st_domains.txt" },

  // Japanese
  { name: "JPN AdGuard DNS", url: "https://adguardteam.github.io/AdguardFilters/JapaneseFilter/sections/adservers.txt" }
];

const CUSTOM_BLOCKED = [
  "deledao.com",
  "*.deledao.com",
  "deledao.net",
  "*.deledao.net",
  "iprofiles.apple.com",
  "mdmenrollment.apple.com",
  "deviceenrollment.apple.com",
  "gdmf.apple.com",
  "acmdm.apple.com",
  "albert.apple.com"
];
// const CUSTOM_BLOCKED = [];

const CUSTOM_ALLOWED = [];

const passCache = new Set();
const blockedDomains = new Set();
const blockedWildcards = [];
let filtersReady = false;
let blockedCount = 0;

function fetch(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith("https") ? https : http;
    client
      .get(url, { headers: { "User-Agent": "Mozilla/5.0" } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return fetch(res.headers.location).then(resolve, reject);
        }
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}`));
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks).toString()));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

function parseFilterList(text) {
  const domains = new Set();

  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("!") || line.startsWith("[")) continue;

    const abpMatch = line.match(/^\|\|([a-z0-9._-]+)\^(\$.*)?$/i);
    if (abpMatch) {
      const opts = abpMatch[2] || "";

      // FIX: Only accept pure, unconditional domain blocks.
      // Browser filters use modifiers for conditional blocking.
      // Applying these globally in a proxy causes massive false positives.
      if (opts) continue;

      domains.add(abpMatch[1].toLowerCase());
      continue;
    }

    const hostsMatch = line.match(/^(?:0\.0\.0\.0|127\.0\.0\.1)\s+([a-z0-9._-]+)/i);
    if (hostsMatch && hostsMatch[1] !== "localhost") {
      domains.add(hostsMatch[1].toLowerCase());
      continue;
    }
  }

  return domains;
}

async function loadFilterLists() {
  if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });

  for (const list of FILTER_LISTS) {
    const cacheFile = path.join(CACHE_DIR, encodeURIComponent(list.name) + ".txt");
    let text = null;

    if (fs.existsSync(cacheFile)) {
      const age = Date.now() - fs.statSync(cacheFile).mtimeMs;
      if (age < FILTER_UPDATE_INTERVAL) {
        text = fs.readFileSync(cacheFile, "utf8");
        console.log(`  ↻ ${list.name} (cached)`);
      }
    }

    if (!text) {
      try {
        console.log(`  ↓ ${list.name}...`);
        text = await fetch(list.url);
        fs.writeFileSync(cacheFile, text);
      } catch (err) {
        console.log(`  ✗ ${list.name}: ${err.message}`);
        if (fs.existsSync(cacheFile)) {
          text = fs.readFileSync(cacheFile, "utf8");
          console.log(`    using stale cache`);
        } else {
          continue;
        }
      }
    }

    const domains = parseFilterList(text);
    for (const d of domains) blockedDomains.add(d);
    console.log(`    ${domains.size.toLocaleString()} domains`);
  }

  for (const pattern of CUSTOM_BLOCKED) {
    if (pattern.startsWith("*.")) {
      blockedWildcards.push({ suffix: pattern.slice(1) });
      blockedDomains.add(pattern.slice(2));
    } else {
      blockedDomains.add(pattern);
    }
  }

  console.log(`  ✓ ${blockedDomains.size.toLocaleString()} unique domains blocked`);
}

function isAllowed(host) {
  return CUSTOM_ALLOWED.some((pattern) => {
    if (pattern.startsWith("*.")) {
      const suffix = pattern.slice(1);
      return host === pattern.slice(2) || host.endsWith(suffix);
    }
    return host === pattern;
  });
}

function isBlocked(host) {
  if (!filtersReady) return false;
  if (isAllowed(host)) return false;

  // Exact match only
  if (blockedDomains.has(host)) return true;

  // Custom wildcards only (not filter list domains)
  for (const { suffix } of blockedWildcards) {
    if (host.endsWith(suffix)) return true;
  }

  return false;
}

function isTLSClientHello(buf) {
  return buf.length > 5 && buf[0] === 0x16 && buf[5] === 0x01;
}

function findSNIOffset(buf) {
  try {
    let offset = 43;
    if (offset >= buf.length) return -1;
    offset += 1 + buf[offset];
    if (offset + 2 > buf.length) return -1;
    offset += 2 + buf.readUInt16BE(offset);
    if (offset >= buf.length) return -1;
    offset += 1 + buf[offset];
    if (offset + 2 > buf.length) return -1;
    offset += 2;

    while (offset + 4 < buf.length) {
      const extType = buf.readUInt16BE(offset);
      const extLen = buf.readUInt16BE(offset + 2);
      if (extType === 0x0000) {
        if (offset + 9 > buf.length) return -1;
        const nameLen = buf.readUInt16BE(offset + 7);
        const nameStart = offset + 9;
        if (nameStart + nameLen > buf.length) return -1;
        return nameStart + Math.floor(nameLen / 2);
      }
      offset += 4 + extLen;
    }
  } catch (e) {}
  return -1;
}

function splitClientHello(buf) {
  const type = buf[0];
  const version = buf.readUInt16BE(1);
  const payloadLen = buf.readUInt16BE(3);
  const payload = buf.slice(5, 5 + payloadLen);

  const sniOffset = findSNIOffset(buf);
  const splitAt = sniOffset > 5 && sniOffset < 5 + payloadLen ? sniOffset - 5 : Math.min(1, payloadLen);

  const makeRecord = (data) => {
    const rec = Buffer.alloc(5 + data.length);
    rec[0] = type;
    rec.writeUInt16BE(version, 1);
    rec.writeUInt16BE(data.length, 3);
    data.copy(rec, 5);
    return rec;
  };

  return {
    record1: makeRecord(payload.slice(0, splitAt)),
    record2: makeRecord(payload.slice(splitAt)),
    trailing: buf.length > 5 + payloadLen ? buf.slice(5 + payloadLen) : null
  };
}

function addPass(host, reason) {
  passCache.add(host);
  console.log(`  ✗ ${host} → pass (${reason})`);
}

const server = http.createServer((req, res) => {
  try {
    const url = new URL(req.url);

    if (isBlocked(url.hostname)) {
      blockedCount++;
      console.log(`✕ ${url.hostname} (blocked HTTP) [${blockedCount} total]`);
      res.writeHead(403, { "Content-Type": "text/plain" });
      res.end("Forbidden by proxy");
      return;
    }

    console.log(`→ ${url.hostname}:${url.port || 80} (HTTP)`);

    const options = {
      hostname: url.hostname,
      port: url.port || 80,
      path: url.pathname + url.search,
      method: req.method,
      headers: req.headers
    };

    const proxyReq = http.request(options, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res, { end: true });
    });

    proxyReq.on("error", (err) => {
      console.log(`  ✗ HTTP proxy error (${url.hostname}): ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { "Content-Type": "text/plain" });
        res.end("Bad Gateway");
      }
    });

    req.pipe(proxyReq, { end: true });
  } catch (err) {
    res.writeHead(400, { "Content-Type": "text/plain" });
    res.end("Bad Request");
  }
});

server.on("connect", (req, clientSocket, head) => {
  const [host, port] = req.url.split(":");
  const targetPort = port || 443;

  if (isBlocked(host)) {
    blockedCount++;
    console.log(`✕ ${host} (blocked) [${blockedCount} total]`);
    clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
    clientSocket.destroy();
    return;
  }

  // PATCHED: Assume it might be TLS unless it's explicitly cached as a pass.
  // We will verify the actual data inside the clientSocket.on("data") event.
  const mightBeTLS = !passCache.has(host);
  let actuallySplit = false;

  console.log(`→ ${host}:${targetPort}${mightBeTLS ? "" : " (cache pass)"}`);

  const serverSocket = net.connect(targetPort, host, () => {
    serverSocket.setNoDelay(true);
    clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head.length > 0) serverSocket.write(head);
  });

  let isFirstPacket = true;
  let serverSentData = false;
  let handshakeTimer = null;

  if (mightBeTLS) {
    handshakeTimer = setTimeout(() => {
      if (!serverSentData && !serverSocket.destroyed) {
        addPass(host, "handshake timeout");
        serverSocket.destroy();
        clientSocket.destroy();
      }
    }, HANDSHAKE_TIMEOUT);
  }

  clientSocket.on("data", (chunk) => {
    if (isFirstPacket) {
      isFirstPacket = false;

      // Dynamically inspect the payload to see if it's actually a TLS handshake
      if (mightBeTLS && isTLSClientHello(chunk)) {
        actuallySplit = true; // Confirmed TLS
        const { record1, record2, trailing } = splitClientHello(chunk);

        serverSocket.write(record1);
        setTimeout(() => {
          if (!serverSocket.destroyed) {
            serverSocket.write(record2);
            if (trailing) serverSocket.write(trailing);
          }
        }, SPLIT_DELAY);
        return;
      } else {
        // Not TLS or it's in the cache. Cancel the timeout.
        if (handshakeTimer) clearTimeout(handshakeTimer);
      }

      serverSocket.write(chunk);
    } else {
      serverSocket.write(chunk);
    }
  });

  serverSocket.on("data", (chunk) => {
    if (!serverSentData) {
      serverSentData = true;
      if (handshakeTimer) clearTimeout(handshakeTimer);

      if (actuallySplit) {
        if (chunk[0] === 0x15) {
          addPass(host, "TLS alert");
          serverSocket.destroy();
          clientSocket.destroy();
          return;
        }
        if (chunk[0] === 0x16 && chunk.length < 50) {
          addPass(host, "short ServerHello");
          serverSocket.destroy();
          clientSocket.destroy();
          return;
        }
      }
    }
    clientSocket.write(chunk);
  });

  serverSocket.on("error", (err) => {
    if (handshakeTimer) clearTimeout(handshakeTimer);
    if (actuallySplit && !serverSentData) addPass(host, `error: ${err.code}`);
    clientSocket.destroy();
  });

  serverSocket.on("close", () => {
    if (handshakeTimer) clearTimeout(handshakeTimer);
    if (actuallySplit && !serverSentData) addPass(host, "closed without response");
    clientSocket.destroy();
  });

  clientSocket.on("error", () => {
    if (handshakeTimer) clearTimeout(handshakeTimer);
    serverSocket.destroy();
  });

  clientSocket.on("close", () => {
    if (handshakeTimer) clearTimeout(handshakeTimer);
    serverSocket.destroy();
  });
});

async function start() {
  server.listen(PORT, "127.0.0.1", () => {
    console.log(`🟢 Server on 127.0.0.1:${PORT}\n`);
  });

  console.log("📋 Loading filter lists...");
  await loadFilterLists();
  filtersReady = true;
  console.log("🛡  Ad blocking active\n");

  setInterval(async () => {
    console.log("\n📋 Refreshing filter lists...");
    blockedDomains.clear();
    blockedWildcards.length = 0;
    await loadFilterLists();
  }, FILTER_UPDATE_INTERVAL);
}

start();
