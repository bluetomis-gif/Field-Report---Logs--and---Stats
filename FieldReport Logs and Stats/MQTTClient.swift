//
//  MQTTClient.swift
//  FieldReport: Logs and Stats
//
//  Minimal MQTT 3.1.1 over WebSocket — zero external dependencies.
//
//  Supported packet types:
//    Send:    CONNECT, SUBSCRIBE, PINGREQ, DISCONNECT
//    Receive: CONNACK, SUBACK, PUBLISH (QoS 0), PINGRESP
//
//  QoS 0 only — correct for high-frequency telemetry (best-effort, lowest latency).
//
//  Usage:
//    let client = MQTTClient()
//    client.onConnected    = { client.subscribe(topic: "thing/product/+/osd") }
//    client.onMessage      = { topic, payload in … }
//    client.onDisconnected = { _ in /* reconnect logic */ }
//    client.connect(host: "broker.hivemq.com", port: 8884, clientId: "fr_HAWK5")
//

import Foundation

// MARK: - MQTTClient

final class MQTTClient: @unchecked Sendable {

    /// Called on the main thread after CONNACK(0) is received.
    var onConnected:    (() -> Void)?
    /// Called on the main thread when the WebSocket closes or errors.
    var onDisconnected: ((Error?) -> Void)?
    /// Called on the main thread for every incoming PUBLISH.
    var onMessage:      ((_ topic: String, _ payload: Data) -> Void)?

    // MARK: Private — all access serialized on `queue`

    private let queue = DispatchQueue(label: "mqtt.client", qos: .userInitiated)
    private var wsTask:    URLSessionWebSocketTask?
    private var pingTimer: Task<Void, Never>?
    private var generation = 0   // bumped on each connect to ignore stale callbacks

    // MARK: - Public API

    func connect(host: String, port: Int, clientId: String,
                 username: String = "", password: String = "") {
        queue.async { [self] in
            teardown()
            generation += 1
            let gen = generation

            let scheme = (port == 8883 || port == 8884 || port == 443) ? "wss" : "ws"
            guard let url = URL(string: "\(scheme)://\(host):\(port)/mqtt") else {
                DispatchQueue.main.async { self.onDisconnected?(URLError(.badURL)) }
                return
            }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url, protocols: ["mqtt"])
            wsTask = task
            task.resume()

            let packet = buildConnect(clientId: clientId, username: username,
                                      password: password, keepAlive: 60)

            // Use the async send path to ensure the WS handshake completes first.
            Task { [weak self] in
                do {
                    try await task.send(.data(packet))
                } catch {
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == gen else { return }
                        self.teardown()
                        DispatchQueue.main.async { self.onDisconnected?(error) }
                    }
                    return
                }
                guard let self else { return }
                self.queue.async {
                    guard self.generation == gen else { return }
                    self.receiveLoop(task: task, gen: gen)
                    self.startPingLoop(task: task, gen: gen)
                }
            }
        }
    }

    func subscribe(topic: String, qos: UInt8 = 0) {
        queue.async { [self] in
            var payload = Data()
            payload.append(UInt8(0x00))  // packet ID MSB
            payload.append(UInt8(0x01))  // packet ID LSB
            payload.appendMQTTString(topic)
            payload.append(min(qos, 2))

            var packet = Data([0x82])       // SUBSCRIBE fixed header
            packet.appendVariableLength(payload.count)
            packet.append(contentsOf: payload)
            self.wsTask?.send(.data(packet)) { _ in }
        }
    }

    func disconnect() {
        queue.async { [self] in
            let data = Data([0xE0, 0x00])
            wsTask?.send(.data(data)) { _ in }
            teardown()
        }
    }

    // MARK: - Internal (called on queue)

    /// Tear down without sending DISCONNECT — called from queue only.
    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    // MARK: - CONNECT packet builder

    private func buildConnect(clientId: String, username: String,
                              password: String, keepAlive: UInt16) -> Data {
        var body = Data()

        // Protocol name (MQTT 3.1.1)
        body.appendMQTTString("MQTT")
        body.append(0x04)              // protocol level

        // Connect flags
        var flags: UInt8 = 0x02        // clean session
        if !username.isEmpty { flags |= 0x80 }
        if !password.isEmpty { flags |= 0x40 }
        body.append(flags)

        // Keep-alive (seconds, big-endian)
        body.append(UInt8(keepAlive >> 8))
        body.append(UInt8(keepAlive & 0xFF))

        // Payload
        body.appendMQTTString(clientId)
        if !username.isEmpty { body.appendMQTTString(username) }
        if !password.isEmpty { body.appendMQTTString(password) }

        var packet = Data([0x10])      // CONNECT fixed header
        packet.appendVariableLength(body.count)
        packet.append(contentsOf: body)
        return packet
    }

    // MARK: - Receive loop

    private func receiveLoop(task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.generation == gen else { return }
                switch result {
                case .success(let msg):
                    switch msg {
                    case .data(let d):   self.handlePacket(d)
                    case .string(let s): self.handlePacket(Data(s.utf8))
                    @unknown default:    break
                    }
                    self.receiveLoop(task: task, gen: gen)

                case .failure(let error):
                    self.teardown()
                    DispatchQueue.main.async { self.onDisconnected?(error) }
                }
            }
        }
    }

    // MARK: - Packet parser

    private func handlePacket(_ data: Data) {
        guard !data.isEmpty else { return }
        let typeNibble = data[0] & 0xF0

        switch typeNibble {

        case 0x20:  // CONNACK
            guard data.count >= 4 else { return }
            let returnCode = data[3]
            if returnCode == 0 {
                DispatchQueue.main.async { self.onConnected?() }
            } else {
                let err = NSError(domain: "MQTT", code: Int(returnCode),
                                  userInfo: [NSLocalizedDescriptionKey: "CONNACK error \(returnCode)"])
                teardown()
                DispatchQueue.main.async { self.onDisconnected?(err) }
            }

        case 0x30:  // PUBLISH (QoS 0, 1, or 2 — we only care about the payload)
            parsePublish(data)

        case 0x90:  // SUBACK — acknowledged, nothing to do
            break

        case 0xD0:  // PINGRESP — keepalive ack
            break

        default:
            break
        }
    }

    // MARK: - PUBLISH parser

    private func parsePublish(_ data: Data) {
        guard data.count >= 4 else { return }

        // Decode variable-length "remaining length" field
        var pos = 1
        var remainingLength = 0
        var multiplier = 1
        repeat {
            guard pos < data.count else { return }
            let byte = Int(data[pos])
            remainingLength += (byte & 0x7F) * multiplier
            multiplier *= 128
            pos += 1
            if multiplier > 128 * 128 * 128 { return }  // malformed
        } while (data[pos - 1] & 0x80) != 0

        // Topic length (2-byte big-endian)
        guard pos + 2 <= data.count else { return }
        let topicLen = Int(data[pos]) << 8 | Int(data[pos + 1])
        pos += 2

        guard pos + topicLen <= data.count else { return }
        let topicData = data[pos ..< pos + topicLen]
        guard let topic = String(bytes: topicData, encoding: .utf8) else { return }
        pos += topicLen

        // Skip 2-byte packet ID for QoS 1 or 2
        let qos = (data[0] >> 1) & 0x03
        if qos > 0 { pos += 2 }

        guard pos <= data.count else { return }
        let payload = Data(data[pos...])

        DispatchQueue.main.async { self.onMessage?(topic, payload) }
    }

    // MARK: - Keepalive

    private func startPingLoop(task: URLSessionWebSocketTask, gen: Int) {
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                self.queue.async {
                    guard self.generation == gen else { return }
                    task.send(.data(Data([0xC0, 0x00]))) { _ in }
                }
            }
        }
    }
}

// MARK: - Data helpers

private extension Data {
    /// Append a UTF-8 string with the 2-byte length prefix MQTT uses.
    mutating func appendMQTTString(_ string: String) {
        let bytes = Array(string.utf8)
        append(UInt8(bytes.count >> 8))
        append(UInt8(bytes.count & 0xFF))
        append(contentsOf: bytes)
    }

    /// Append an integer using MQTT's variable-length encoding (1–4 bytes).
    mutating func appendVariableLength(_ length: Int) {
        var remaining = length
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            append(byte)
        } while remaining > 0
    }
}
