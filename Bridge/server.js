/**
 * FieldReport DJI Telemetry Bridge  v2.0  —  Session-Code Router
 * ================================================================
 *
 * Architecture
 * ────────────
 *  ┌─────────────────┐   MQTT TCP :1883   ┌──────────────────────┐
 *  │  DJI Pilot 2    │──────────────────▶│                       │
 *  │  (RC Pro Ent.)  │  clientId:         │   FieldReport Bridge  │
 *  │                 │  fr_HAWK5_17480…  │                       │──▶ ws://host:8080/join/HAWK5
 *  └─────────────────┘                   │  sessions Map         │
 *          ▲                             │  HAWK5 → { iosSocket, │   ┌──────────────────────┐
 *          │  GET /h5/HAWK5              │           mqttClientId}│   │  iPhone (FieldReport) │
 *  ┌───────┴─────────┐                  └──────────────────────┘   └──────────────────────┘
 *  │  DJI Pilot 2    │
 *  │  WebView (H5)   │
 *  └─────────────────┘
 *
 * Session lifecycle
 * ─────────────────
 *  1. iPhone connects WS → GET ws://host:8080/join/HAWK5
 *     Server creates session { iosSocket, mqttClientId: null }
 *     Server → iPhone: { type: 'hello', code: 'HAWK5', h5Url: '...' }
 *
 *  2. Pilot enters URL in DJI Pilot 2 Cloud Services: http://host:8080/h5/HAWK5
 *     H5 page loads, calls djiBridge.setMqttConfig({ clientId: 'fr_HAWK5_1748…' })
 *
 *  3. MQTT client fr_HAWK5_* connects
 *     Server parses code 'HAWK5', links to session
 *     Server → iPhone: { type: 'drone_connected' }
 *
 *  4. DJI pushes OSD on: thing/product/{device_sn}/osd
 *     Server routes frame to HAWK5's iosSocket
 *
 *  5. iPhone disconnects → session deleted (ephemeral data gone)
 *     MQTT client disconnects → mqttClientId cleared, iPhone notified
 *
 * Setup
 * ─────
 *   npm install
 *   node server.js
 *
 *   iPhone WS:    ws://<IP>:8080/join/<CODE>
 *   DJI H5 URL:   http://<IP>:8080/h5/<CODE>
 *   Status:       http://<IP>:8080/status
 */

'use strict';

const aedes = require('aedes');
const net   = require('net');
const http  = require('http');
const ws    = require('ws');
const fs    = require('fs');
const path  = require('path');

// ── Config ────────────────────────────────────────────────────────────────────
const MQTT_PORT = parseInt(process.env.MQTT_PORT || '1883', 10);
const HTTP_PORT = parseInt(process.env.HTTP_PORT || '8080', 10);  // HTTP + WS on same port

// ── Session Registry ──────────────────────────────────────────────────────────
//  code (uppercase) → { iosSocket: ws.WebSocket|null, mqttClientId: string|null }
const sessions = new Map();

function getOrNull(code) { return sessions.get(code.toUpperCase()) ?? null; }

function notify(socket, payload) {
  if (socket && socket.readyState === ws.WebSocket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

// ── MQTT Broker ───────────────────────────────────────────────────────────────
const broker = aedes();
const mqttServer = net.createServer(broker.handle);

mqttServer.listen(MQTT_PORT, () => {
  log('MQTT', `Broker listening on TCP :${MQTT_PORT}`);
});

// clientId pattern:  fr_<CODE>_<timestamp>
const CLIENT_RE = /^fr_([A-Z0-9]+)_\d+$/i;

broker.on('client', (client) => {
  const m = client.id.match(CLIENT_RE);
  if (!m) return;
  const code    = m[1].toUpperCase();
  const session = getOrNull(code);
  if (!session) {
    log('MQTT', `Client ${client.id} connected but no session for code ${code}`);
    return;
  }
  session.mqttClientId = client.id;
  log('SESSION', `Drone linked → session ${code}  (client: ${client.id})`);
  notify(session.iosSocket, { type: 'drone_connected', code });
});

broker.on('clientDisconnect', (client) => {
  const m = client.id.match(CLIENT_RE);
  if (!m) return;
  const code    = m[1].toUpperCase();
  const session = getOrNull(code);
  if (!session) return;
  session.mqttClientId = null;
  log('SESSION', `Drone unlinked from session ${code}`);
  notify(session.iosSocket, { type: 'drone_disconnected', code });
});

// ── OSD + State Relay ─────────────────────────────────────────────────────────
broker.on('publish', (packet, client) => {
  if (!client) return;  // broker-initiated, skip

  const m = client.id.match(CLIENT_RE);
  if (!m) return;
  const code    = m[1].toUpperCase();
  const session = getOrNull(code);
  if (!session?.iosSocket) return;

  const topic = packet.topic;

  // OSD telemetry  ── thing/product/{sn}/osd
  if (topic.match(/^thing\/product\/[^/]+\/osd$/)) {
    try {
      const raw      = JSON.parse(packet.payload.toString('utf8'));
      const tsMs     = typeof raw.timestamp === 'number' ? raw.timestamp : Date.now();
      const deviceSn = topic.split('/')[2];
      const frame    = {
        deviceSn,
        timestamp: tsMs / 1000,
        data:      raw.data || {}
      };
      notify(session.iosSocket, frame);
    } catch (e) {
      log('RELAY', `OSD parse error (${code}): ${e.message}`);
    }
    return;
  }

  // State topic  ── thing/product/{sn}/state  (battery alerts etc.)
  if (topic.match(/^thing\/product\/[^/]+\/state$/)) {
    try {
      const raw = JSON.parse(packet.payload.toString('utf8'));
      notify(session.iosSocket, { type: 'drone_state', data: raw.data || {} });
    } catch (_) {}
  }
});

// ── HTTP + WebSocket Server ───────────────────────────────────────────────────
const httpServer = http.createServer((req, res) => {
  // ── Status endpoint
  if (req.url === '/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    const sessionInfo = {};
    for (const [code, sess] of sessions) {
      sessionInfo[code] = {
        iosConnected:   !!sess.iosSocket,
        droneConnected: !!sess.mqttClientId
      };
    }
    res.end(JSON.stringify({ sessions: sessionInfo, uptime: process.uptime() }));
    return;
  }

  // ── H5 handshake page for DJI Pilot 2
  //    URL pattern: GET /h5/<CODE>  or  /h5/<CODE>/
  const h5Match = req.url?.match(/^\/h5\/([A-Za-z0-9]+)\/?$/);
  if (h5Match) {
    const code    = h5Match[1].toUpperCase();
    const htmlPath = path.join(__dirname, 'h5', 'index.html');
    fs.readFile(htmlPath, 'utf8', (err, html) => {
      if (err) {
        res.writeHead(500);
        res.end('H5 page not found. Ensure Bridge/h5/index.html exists.');
        return;
      }
      // Inject the session code and server origin into the HTML
      const served = html
        .replace('__SESSION_CODE__', code)
        .replace('__MQTT_HOST__', req.headers.host?.split(':')[0] || 'localhost')
        .replace('__MQTT_PORT__', String(MQTT_PORT));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(served);
      log('H5', `Served handshake page for code ${code}`);
    });
    return;
  }

  // ── Root redirect
  res.writeHead(302, { Location: '/status' });
  res.end();
});

// ── WebSocket upgrade router  ─  ws://host:8080/join/<CODE>
const wss = new ws.WebSocketServer({ noServer: true });

httpServer.on('upgrade', (req, socket, head) => {
  const match = req.url?.match(/^\/join\/([A-Za-z0-9]+)$/);
  if (!match) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (client) => {
    const code = match[1].toUpperCase();
    wss.emit('connection', client, code);
  });
});

wss.on('connection', (socket, code) => {
  const existing = sessions.get(code);

  // Close any stale iOS connection for this code (e.g. app restarted)
  if (existing?.iosSocket) {
    try { existing.iosSocket.close(1000, 'Replaced'); } catch (_) {}
  }

  sessions.set(code, {
    iosSocket:    socket,
    mqttClientId: existing?.mqttClientId ?? null  // preserve if drone already connected
  });

  log('SESSION', `iPhone joined session ${code}  (active sessions: ${sessions.size})`);

  // Send hello — includes the H5 URL the pilot must enter on the RC
  const serverHost = socket._socket?.localAddress?.replace('::ffff:', '') || '<SERVER_IP>';
  notify(socket, {
    type:   'hello',
    code,
    h5Url:  `http://${serverHost}:${HTTP_PORT}/h5/${code}`,
    server: 'FieldReport/2.0'
  });

  // If the drone was already connected before this iPhone rejoined, notify immediately
  if (sessions.get(code)?.mqttClientId) {
    notify(socket, { type: 'drone_connected', code });
  }

  socket.on('close', () => {
    const sess = sessions.get(code);
    if (sess?.iosSocket === socket) {
      sessions.delete(code);
      log('SESSION', `Session ${code} ended (iPhone disconnected, data purged)`);
    }
  });

  socket.on('error', (err) => {
    log('WS', `Session ${code} socket error: ${err.message}`);
  });
});

httpServer.listen(HTTP_PORT, () => {
  log('HTTP', `Server listening on :${HTTP_PORT}`);
  log('INFO', `iPhone WS URL:  ws://<IP>:${HTTP_PORT}/join/<CODE>`);
  log('INFO', `DJI H5 URL:     http://<IP>:${HTTP_PORT}/h5/<CODE>`);
  log('INFO', `Status:         http://<IP>:${HTTP_PORT}/status`);
});

// ── Utilities ─────────────────────────────────────────────────────────────────
function log(tag, msg) {
  const ts = new Date().toISOString().slice(11, 23);
  console.log(`[${ts}] [${tag.padEnd(7)}] ${msg}`);
}

// ── Graceful Shutdown ─────────────────────────────────────────────────────────
function shutdown(signal) {
  log('SYS', `${signal} received — shutting down`);
  broker.close(() => {
    mqttServer.close();
    httpServer.close();
    process.exit(0);
  });
}
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
