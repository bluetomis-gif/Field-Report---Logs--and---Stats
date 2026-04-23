'use strict';

const aedes  = require('aedes')();
const net    = require('net');
const http   = require('http');
const ws     = require('ws');
const crypto = require('crypto');
const { Duplex } = require('stream');

const TCP_PORT = parseInt(process.env.MQTT_TCP_PORT || '1883', 10);
const WS_PORT  = parseInt(process.env.PORT || '8080', 10);
const HOST     = process.env.MQTT_HOST || 'fieldreport-mqtt.fly.dev';

// ── MQTT over TCP (for DJI RC) ──────────────────────────────────────────────
const mqttServer = net.createServer(aedes.handle);
mqttServer.listen(TCP_PORT, () => console.log(`MQTT TCP :${TCP_PORT}`));

// ── Buffered WebSocket stream ───────────────────────────────────────────────
function createBufferedWSStream(socket) {
    let pending = Buffer.alloc(0);
    let flushScheduled = false;

    const duplex = new Duplex({
        read() {},
        write(chunk, encoding, callback) {
            pending = Buffer.concat([pending, chunk]);
            if (!flushScheduled) {
                flushScheduled = true;
                process.nextTick(() => {
                    flushScheduled = false;
                    if (pending.length > 0 && socket.readyState === ws.OPEN) {
                        socket.send(pending);
                        pending = Buffer.alloc(0);
                    }
                });
            }
            callback();
        },
        final(callback) {
            if (pending.length > 0 && socket.readyState === ws.OPEN) {
                socket.send(pending);
                pending = Buffer.alloc(0);
            }
            socket.close();
            callback();
        }
    });

    socket.on('message', (data) => {
        duplex.push(Buffer.from(data));
    });
    socket.on('close', () => {
        duplex.push(null);
        duplex.destroy();
    });
    socket.on('error', (err) => {
        duplex.destroy(err);
    });

    return duplex;
}

// ── DJI Cloud API v2 — HTTP endpoints ───────────────────────────────────────
// DJI Pilot 2 native Cloud Services mode authenticates via HTTP, then the SDK
// manages MQTT natively (persists across all screens, no WebView needed).
//
// Flow:
//   1. Pilot 2 POSTs /api/v1/pilot/login  → gets token + MQTT config
//   2. SDK connects to MQTT broker using returned credentials
//   3. Connection persists until explicit logout

function readBody(req) {
    return new Promise((resolve) => {
        const chunks = [];
        req.on('data', c => chunks.push(c));
        req.on('end', () => resolve(Buffer.concat(chunks).toString()));
    });
}

function json(res, code, data) {
    const body = JSON.stringify(data);
    res.writeHead(code, {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, x-auth-token'
    });
    res.end(body);
}

// Generate a stable token for a session
function makeToken() {
    return crypto.randomBytes(32).toString('hex');
}

// Stable IDs matching DJI Cloud API Demo format
const WORKSPACE_ID = 'e3dea0f5-37f2-4d79-ae58-490af3228069';
const USER_ID      = 'be7c6c3d-afe9-4be4-b9eb-c55066c0914e';

// Store the latest token so authenticated endpoints can return consistent data
let currentToken = makeToken();

const httpServer = http.createServer(async (req, res) => {
    const method = req.method;
    const url    = req.url.split('?')[0];   // strip query string

    const authToken = req.headers['x-auth-token'] || '';
    console.log(`[HTTP] ${method} ${url} token=${authToken.slice(0,8)||'none'} headers=${JSON.stringify(req.headers).slice(0,300)}`);

    // ── CORS preflight ───────────────────────────────────────────────────
    if (method === 'OPTIONS') {
        json(res, 200, {});
        return;
    }

    // ── Health check ─────────────────────────────────────────────────────
    if (url === '/health') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('ok');
        return;
    }

    // ── DJI Pilot 2 login ────────────────────────────────────────────────
    // On-Premises:   POST /manage/api/v1/login
    // Open Platform: POST /api/v1/pilot/login
    if (method === 'POST' && url.includes('/login')) {
        const body = await readBody(req);
        console.log(`[AUTH] Login at ${url}: ${body}`);

        currentToken = makeToken();

        // Match DJI Cloud API Demo UserDTO exactly
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                access_token: currentToken,
                user_id: USER_ID,
                username: 'pilot',
                workspace_id: WORKSPACE_ID,
                user_type: 2,
                mqtt_addr: `ssl://${HOST}:8883`,
                mqtt_username: '',
                mqtt_password: ''
            }
        });
        console.log(`[AUTH] Login OK → token=${currentToken.slice(0,8)}…`);
        return;
    }

    // ── Current user info ────────────────────────────────────────────────
    // GET /manage/api/v1/users/current — called after login
    if (method === 'GET' && url.includes('/users/current')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                user_id: USER_ID,
                username: 'pilot',
                workspace_id: WORKSPACE_ID,
                user_type: 2,
                mqtt_addr: `ssl://${HOST}:8883`,
                mqtt_username: '',
                mqtt_password: ''
            }
        });
        return;
    }

    // ── Current workspace ────────────────────────────────────────────────
    // GET /manage/api/v1/workspaces/current
    if (method === 'GET' && url.includes('/workspaces/current')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                workspace_id: WORKSPACE_ID,
                workspace_name: 'FieldReport',
                workspace_desc: 'FieldReport Telemetry',
                platform_name: 'FieldReport Cloud',
                bind_code: 'fieldreport'
            }
        });
        return;
    }

    // ── Workspace info (generic) ─────────────────────────────────────────
    if (method === 'GET' && url.includes('/workspaces')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                workspace_id: WORKSPACE_ID,
                workspace_name: 'FieldReport',
                workspace_desc: 'FieldReport Telemetry',
                platform_name: 'FieldReport Cloud',
                bind_code: 'fieldreport'
            }
        });
        return;
    }

    // ── Device topology ──────────────────────────────────────────────────
    // GET /manage/api/v1/workspaces/{workspace_id}/devices/topologies
    if (method === 'GET' && url.includes('/topolog')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: []
        });
        return;
    }

    // ── Device binding ───────────────────────────────────────────────────
    // POST /manage/api/v1/devices/{device_sn}/binding
    if (method === 'POST' && url.includes('/binding')) {
        const body = await readBody(req);
        console.log(`[BIND] ${url}: ${body}`);
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {}
        });
        return;
    }

    // ── Device list / info ───────────────────────────────────────────────
    if (url.includes('/devices')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: { list: [] }
        });
        return;
    }

    // ── Token refresh ────────────────────────────────────────────────────
    if (method === 'POST' && url.includes('/token/refresh')) {
        currentToken = makeToken();
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                access_token: currentToken
            }
        });
        return;
    }

    // ── Platform config / capability ─────────────────────────────────────
    if (url.includes('/config') || url.includes('/capability')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {}
        });
        return;
    }

    // ── Service list ─────────────────────────────────────────────────────
    // Pilot 2 v16+ checks this before showing "connected".
    // Return enabled DJI Cloud API service modules.
    if (url.includes('/service-list')) {
        console.log(`[HTTP] service-list → modules`);
        json(res, 200, {
            code: 0,
            message: 'success',
            data: [
                { module: 'thing',   enabled: true },
                { module: 'live',    enabled: false },
                { module: 'map',     enabled: true },
                { module: 'media',   enabled: false },
                { module: 'wayline', enabled: false },
                { module: 'tsa',     enabled: true }
            ]
        });
        return;
    }

    // ── MQTT config (if fetched separately) ──────────────────────────────
    if (url.includes('/mqtt') || url.includes('/broker')) {
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {
                mqtt_addr: `ssl://${HOST}:8883`,
                mqtt_username: '',
                mqtt_password: ''
            }
        });
        return;
    }

    // ── Catch-all for any other DJI API endpoint ─────────────────────────
    if (url.startsWith('/api/') || url.startsWith('/manage/')) {
        console.log(`[HTTP] Unhandled DJI endpoint: ${method} ${url}`);
        const body = await readBody(req);
        if (body) console.log(`[HTTP] Body: ${body.slice(0, 500)}`);
        json(res, 200, {
            code: 0,
            message: 'success',
            data: {}
        });
        return;
    }

    // ── Default ──────────────────────────────────────────────────────────
    json(res, 200, {
        code: 0,
        message: 'success',
        data: { server: 'FieldReport Cloud', version: '1.0.0' }
    });
});

// ── WebSocket (MQTT for iPhone, status for RC) ──────────────────────────────
const wss = new ws.WebSocketServer({ server: httpServer });
wss.on('connection', (socket, req) => {
    const proto = req.headers['sec-websocket-protocol'] || '';
    const urlPath = req.url || '/';
    console.log(`[WS] Connection from ${req.socket.remoteAddress} path=${urlPath} proto=${proto}`);

    // If the WS request uses the MQTT subprotocol or /mqtt path, treat as MQTT
    if (proto.includes('mqtt') || urlPath.includes('/mqtt')) {
        const stream = createBufferedWSStream(socket);
        aedes.handle(stream);
    } else {
        // DJI status/notification WebSocket — keep alive, send periodic status
        console.log(`[WS] Non-MQTT WebSocket — treating as DJI status channel`);
        socket.on('message', (data) => {
            console.log(`[WS-STATUS] Received: ${data.toString().slice(0, 200)}`);
        });
        socket.on('close', () => {
            console.log(`[WS-STATUS] Closed`);
        });
    }
});

httpServer.listen(WS_PORT, () => console.log(`MQTT WS + HTTP API :${WS_PORT}`));

// ── DJI Cloud API v2 — MQTT status handshake ────────────────────────────────
aedes.on('publish', (packet, client) => {
    if (!client) return;

    const topic = packet.topic;
    const parts = topic.split('/');

    console.log(`[PUB] ${client.id} → ${topic} (${packet.payload.length}B)`);

    // Handle sys/product/{SN}/status → reply to acknowledge device online
    if (parts[0] === 'sys' && parts[1] === 'product' && parts[3] === 'status' && parts.length === 4) {
        const sn = parts[2];
        try {
            const msg = JSON.parse(packet.payload.toString());
            console.log(`[DJI] Device online: ${sn} tid=${msg.tid}`);

            const reply = JSON.stringify({
                tid: msg.tid || '',
                bid: msg.bid || '',
                timestamp: Date.now(),
                data: { result: 0 }
            });

            aedes.publish({
                topic: `sys/product/${sn}/status_reply`,
                payload: Buffer.from(reply),
                qos: 0,
                retain: false
            }, () => {
                console.log(`[DJI] → status_reply to ${sn}`);
            });
        } catch (e) {
            console.log(`[DJI] Failed to parse status from ${sn}: ${e.message}`);
        }
    }

    // Log OSD frames
    if (parts[0] === 'thing' && parts[1] === 'product' && parts[3] === 'osd') {
        console.log(`[OSD] ${parts[2]} (${packet.payload.length}B)`);
    }
});

// ── Accept all MQTT credentials (DJI SDK may send username/password) ─────────
aedes.authenticate = (client, username, password, callback) => {
    console.log(`[AUTH-MQTT] ${client.id} user=${username || '(anon)'}`);
    callback(null, true);
};

// ── Logging ─────────────────────────────────────────────────────────────────
aedes.on('client', (client) => {
    console.log(`[+] ${client.id}  clean=${client.clean}`);
});
aedes.on('clientDisconnect', (client) => {
    console.log(`[-] ${client.id}`);
});
aedes.on('clientError', (client, err) => {
    console.log(`[ERR] ${client.id}: ${err.message}`);
});
aedes.on('subscribe', (subscriptions, client) => {
    const topics = subscriptions.map(s => s.topic).join(', ');
    console.log(`[SUB] ${client.id} → ${topics}`);
});

// Graceful shutdown
process.on('SIGINT',  () => { aedes.close(); process.exit(0); });
process.on('SIGTERM', () => { aedes.close(); process.exit(0); });
