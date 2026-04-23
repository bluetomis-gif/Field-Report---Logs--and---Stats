//
//  TelemetryBridge.swift
//  FieldReport: Logs and Stats
//
//  Connects directly to an MQTT broker (default: HiveMQ public cloud)
//  and subscribes to  thing/product/+/osd  to receive DJI OSD frames
//  from any drone publishing to that broker.
//
//  Architecture (serverless):
//
//    DJI RC Pro  ──MQTT──▶  broker.hivemq.com:8883
//                                    │
//    iPhone  ──MQTT-over-WS──▶  broker.hivemq.com:8884
//                   ◀── PUBLISH thing/product/{SN}/osd ──
//
//  The session code is a UX identifier — it scopes the H5 URL fragment so
//  the pilot knows which page to load.  Routing is done by MQTT topic (SN).
//
//  Session lifecycle:
//    .idle       → no connection
//    .connecting → MQTTClient.connect() sent, awaiting CONNACK
//    .waiting    → CONNACK received, subscribed, no OSD yet
//    .live       → first PUBLISH received, dashboard active
//
//  Local broker fallback:
//    If you prefer the Node.js bridge on a local network instead of the
//    cloud broker, set host/port to your bridge server and port 8080.
//    The session-code routing in server.js still works — it reads the
//    clientId prefix to route MQTT → WebSocket.
//

import Foundation
import Observation
import UserNotifications

// MARK: - Session State

enum SessionState: Equatable {
    case idle
    case connecting
    /// Subscribed to OSD topic; waiting for the drone to publish.
    case waiting
    /// OSD frames are flowing.
    case live
}

// MARK: - Bridge

@Observable
@MainActor
final class TelemetryBridge {

    // MARK: - Published state

    private(set) var sessionState:       SessionState = .idle
    private(set) var latestFrame:        DJITelemetryFrame?
    /// Increments on every OSD frame — observe with .onChange to drive the logger.
    private(set) var frameCount:         Int    = 0
    private(set) var droneConnected:     Bool   = false   // true once first frame arrives
    private(set) var statusMessage:      String = "Ready"
    /// The H5 URL to show the pilot.  Computed from current settings + session code.
    private(set) var h5URL:              String = ""
    /// Wall-clock timestamp of the most recent OSD frame — drives the link-health ticker.
    private(set) var lastFrameReceivedAt: Date?
    /// Live flight event log — drives the timeline view on the dashboard.
    private(set) var events: [FlightEvent] = []

    // MARK: - Private

    private var mqtt:         MQTTClient?
    private var reconnectTask: Task<Void, Never>?

    private var currentHost:     String?
    private var currentPort:     Int?
    private var currentCode:     String?
    private var currentUsername: String?
    private var currentPassword: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Auto-connect

    /// Call on app launch — connects automatically using saved AppStorage settings.
    func autoConnect() {
        guard sessionState == .idle else { return }
        let defaults = UserDefaults.standard
        let host     = defaults.string(forKey: "mqttHost") ?? "fieldreport-mqtt.fly.dev"
        let port     = defaults.integer(forKey: "mqttPort")
        let realPort = port > 0 ? port : 443
        var code     = defaults.string(forKey: "sessionCode") ?? ""
        if code.isEmpty {
            let alphabet = Array("ACDEFGHJKLMNPQRTUVWXY3456789")
            code = String((0..<5).map { _ in alphabet.randomElement()! })
            defaults.set(code, forKey: "sessionCode")
        }
        let username = defaults.string(forKey: "mqttUsername") ?? ""
        let password = defaults.string(forKey: "mqttPassword") ?? ""
        startSession(host: host, port: realPort, code: code,
                     username: username, password: password)
    }

    // MARK: - Event log helper

    private func appendEvent(title: String, detail: String? = nil, kind: FlightEvent.Kind) {
        events.append(FlightEvent(time: Date(), title: title, detail: detail, kind: kind))
        if events.count > 100 { events.removeFirst() }
    }

    // MARK: - Session Management

    /// Open a new MQTT session.  Safe to call multiple times (tears down previous).
    func startSession(host: String, port: Int, code: String,
                      username: String = "", password: String = "") {
        endSession(reconnecting: false)
        events = []
        currentHost     = host
        currentPort     = port
        currentCode     = code
        currentUsername = username.isEmpty ? nil : username
        currentPassword = password.isEmpty ? nil : password
        appendEvent(title: "Session Started", detail: "Code: \(code) · \(host):\(port)", kind: .info)
        requestNotificationPermission()
        openMQTT()
    }

    /// Tear down the session completely and return to .idle.
    func endSession(reconnecting: Bool = false) {
        reconnectTask?.cancel()
        reconnectTask        = nil
        mqtt?.disconnect()
        mqtt                 = nil
        droneConnected       = false
        latestFrame          = nil
        frameCount           = 0
        h5URL                = ""
        lastFrameReceivedAt  = nil

        if !reconnecting {
            currentHost     = nil
            currentPort     = nil
            currentCode     = nil
            currentUsername = nil
            currentPassword = nil
            sessionState    = .idle
            statusMessage   = "Ready"
        }
    }

    // MARK: - MQTT connection

    private func openMQTT() {
        guard let host = currentHost,
              let port = currentPort,
              let code = currentCode else { return }

        sessionState  = .connecting
        statusMessage = "Connecting to MQTT broker…"

        // H5 URL for the pilot: Cloudflare Pages URL with code as URL fragment.
        // Users set their Pages URL in mqttH5PageURL (AppStorage default below).
        let h5Base = UserDefaults.standard.string(forKey: "mqttH5PageURL")
                     ?? "https://bridge.bluetomis.com"
        h5URL = "\(h5Base)#\(code)"

        let client = MQTTClient()
        mqtt = client

        // clientId encodes the session code — useful for debugging on the broker dashboard
        let clientId = "fr_\(code)_\(Int(Date().timeIntervalSince1970))"

        client.onConnected = { [weak self] in
            guard let self else { return }
            self.sessionState  = .waiting
            self.statusMessage = "Subscribed — waiting for drone…"
            self.appendEvent(title: "Broker Connected",
                             detail: "Subscribed to thing/product/+/osd",
                             kind: .success)
            // Subscribe to ALL drones on this broker (first message wins for this session).
            // Security: topic = thing/product/{SN}/osd — SN is not publicly broadcast.
            client.subscribe(topic: "thing/product/+/osd")
        }

        client.onMessage = { [weak self] topic, payload in
            self?.handlePublish(topic: topic, payload: payload)
        }

        client.onDisconnected = { [weak self] error in
            guard let self else { return }
            let wasLive = self.sessionState == .live
            self.droneConnected = false
            self.sessionState   = wasLive ? .waiting : .idle
            self.statusMessage  = wasLive
                ? "MQTT lost — reconnecting…"
                : "Connection failed: \(error?.localizedDescription ?? "unknown")"
            self.appendEvent(title: "Connection Lost",
                             detail: error?.localizedDescription ?? "MQTT disconnected",
                             kind: .warning)
            self.scheduleReconnect()
        }

        client.connect(host: host, port: port, clientId: clientId,
                       username: currentUsername ?? "",
                       password: currentPassword ?? "")
    }

    private func scheduleReconnect() {
        guard currentHost != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            endSession(reconnecting: true)
            openMQTT()
        }
    }

    // MARK: - OSD frame handling

    private func handlePublish(topic: String, payload: Data) {
        // Expect DJI Cloud API format:
        //   { "tid": "…", "bid": "…", "timestamp": 1748…, "data": { …osd fields… } }
        guard let raw = try? JSONDecoder().decode(DJIRawOSD.self, from: payload) else { return }

        // Extract device SN from topic: thing/product/{SN}/osd
        let parts = topic.split(separator: "/")
        let deviceSn = parts.count >= 3 ? String(parts[2]) : "unknown"

        let frame = DJITelemetryFrame(
            deviceSn:  deviceSn,
            timestamp: (raw.timestamp ?? Double(Date().timeIntervalSince1970 * 1000)) / 1000.0,
            data:      raw.data ?? OSDData()
        )

        latestFrame          = frame
        frameCount          += 1
        lastFrameReceivedAt  = Date()

        if !droneConnected {
            droneConnected = true
            appendEvent(title: "Drone Online",
                        detail: "\(deviceSn) · First OSD frame received",
                        kind: .success)
            notify(id: "drone_connected",
                   title: "Drone Online",
                   body:  "\(deviceSn) · Logging starts when motors arm.")
        }

        if sessionState != .live {
            sessionState  = .live
            statusMessage = "Live · \(deviceSn)"
        }
    }

    // MARK: - Local notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(id: String, title: String, body: String) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        content.sound     = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }
}

// MARK: - DJI raw OSD envelope (direct broker publish format)

/// The DJI SDK publishes this on  thing/product/{sn}/osd
private struct DJIRawOSD: Decodable {
    let tid:       String?
    let bid:       String?
    let timestamp: Double?
    let data:      OSDData?
}
