//
//  SettingsView.swift
//  FieldReport: Logs and Stats
//
//  All settings: session info, broker config, DJI setup, logger, and about.
//  MQTT connects automatically — this screen lets the user inspect and tweak.
//

import SwiftUI

struct SettingsView: View {
    @Environment(TelemetryBridge.self) private var bridge
    @Environment(FlightLogger.self)   private var logger

    @AppStorage("sessionCode")    private var sessionCode:     String = ""
    @AppStorage("mqttHost")       private var serverHost:      String = "fieldreport-mqtt.fly.dev"
    @AppStorage("mqttPort")       private var serverPort:      Int    = 443
    @AppStorage("mqttUsername")   private var serverUsername:   String = ""
    @AppStorage("mqttPassword")   private var serverPassword:  String = ""

    @State private var showBrokerEdit = false
    @State private var hostDraft      = ""
    @State private var portDraft      = ""
    @State private var usernameDraft  = ""
    @State private var passwordDraft  = ""
    @State private var codeCopied     = false
    @State private var urlCopied      = false

    private var displayH5URL: String {
        if !bridge.h5URL.isEmpty { return bridge.h5URL }
        let base = UserDefaults.standard.string(forKey: "mqttH5PageURL") ?? "https://bridge.bluetomis.com"
        return "\(base)#\(sessionCode)"
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Connection ─────────────────────────────────────────
                Section {
                    connectionStatusRow
                    droneStatusRow
                    reconnectRow
                } header: {
                    Text("Connection")
                }

                // ── Session Code ───────────────────────────────────────
                Section {
                    sessionCodeRow
                    copyCodeRow
                } header: {
                    Label("Session Code", systemImage: "number.square.fill")
                } footer: {
                    Text("Persists across flights. Regenerate only if needed.")
                }

                // ── MQTT Broker ────────────────────────────────────────
                Section {
                    brokerRow
                } header: {
                    Label("MQTT Broker", systemImage: "antenna.radiowaves.left.and.right")
                } footer: {
                    Text("HiveMQ Cloud · TLS port 8884 (WSS). Changes take effect on next reconnect.")
                }

                // ── DJI Pilot 2 Setup ──────────────────────────────────
                Section {
                    SetupStepRow(number: 1, title: "Open DJI Pilot 2",
                                 detail: "Launch on your RC Pro Enterprise")
                    SetupStepRow(number: 2, title: "Cloud Services → Open Platform",
                                 detail: "Tap the cloud icon in the top-right menu")
                    SetupStepRow(number: 3, title: "Enter URL below and tap Connect",
                                 detail: "Copy the URL into the Cloud Services field")
                    h5URLRow
                } header: {
                    Label("DJI Pilot 2 Setup", systemImage: "qrcode.viewfinder")
                } footer: {
                    Text("The H5 page configures MQTT automatically. No interaction on the RC is needed after loading the URL.")
                }

                // ── Flight Logger ──────────────────────────────────────
                Section {
                    loggingStatusRow
                    logDirectoryRow
                    if logger.isLogging {
                        forceStopRow
                    }
                } header: {
                    Text("Flight Logger")
                }

                // ── About ──────────────────────────────────────────────
                Section {
                    aboutRow("Protocol",    "DJI Cloud API 2.0 / OSD")
                    aboutRow("Transport",   "MQTT over WSS · HiveMQ Cloud")
                    aboutRow("Log Format",  "CSV + JSON sidecar (bit-packed)")
                    aboutRow("Compression", "40-byte payload · Base64 · ~60 chars")
                    aboutRow("App Build",   appVersion())
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showBrokerEdit) {
                brokerEditSheet
            }
        }
    }

    // MARK: - Connection Rows

    private var connectionStatusRow: some View {
        HStack {
            Label("Bridge", systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.sessionState == .live ? Color.green : Color.cyan)
                    .frame(width: 8, height: 8)
                Text(bridge.statusMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var droneStatusRow: some View {
        HStack {
            Label("Drone", systemImage: "airplane")
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.droneConnected ? Color.green : Color.red.opacity(0.7))
                    .frame(width: 8, height: 8)
                Text(bridge.droneConnected ? "Online" : "Offline")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reconnectRow: some View {
        Button {
            bridge.endSession()
            bridge.autoConnect()
        } label: {
            Label("Reconnect", systemImage: "arrow.clockwise")
        }
    }

    // MARK: - Session Code Rows

    private var sessionCodeRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(sessionCode.enumerated()), id: \.offset) { _, char in
                Text(String(char))
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var copyCodeRow: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = sessionCode
                withAnimation(.spring(duration: 0.3)) { codeCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { codeCopied = false }
                }
            } label: {
                Label(codeCopied ? "Copied!" : "Copy Code",
                      systemImage: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(codeCopied ? .green : .blue)

            Button {
                let alphabet = Array("ACDEFGHJKLMNPQRTUVWXY3456789")
                sessionCode = String((0..<5).map { _ in alphabet.randomElement()! })
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Color(.systemGray))
        }
    }

    // MARK: - Broker Row

    private var brokerRow: some View {
        Button {
            hostDraft     = serverHost
            portDraft     = String(serverPort)
            usernameDraft = serverUsername
            passwordDraft = serverPassword
            showBrokerEdit = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(serverHost)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("Port \(serverPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - H5 URL Row

    private var h5URLRow: some View {
        HStack(spacing: 10) {
            Text(displayH5URL)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = displayH5URL
                withAnimation { urlCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { urlCopied = false }
                }
            } label: {
                Image(systemName: urlCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(urlCopied ? .green : .blue)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Logger Rows

    private var loggingStatusRow: some View {
        HStack {
            Label("Auto-Log", systemImage: "waveform.path.ecg")
            Spacer()
            if logger.isLogging {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC · \(logger.recordCount)")
                        .font(.caption.monospaced())
                }
            } else {
                Text("Idle (starts on motor arm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logDirectoryRow: some View {
        HStack {
            Label("Log Directory", systemImage: "folder.fill")
            Spacer()
            Text("Documents/FlightLogs")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var forceStopRow: some View {
        Button(role: .destructive) {
            logger.forceStop()
        } label: {
            Label("Force Stop Recording", systemImage: "stop.circle")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Broker Edit Sheet

    private var brokerEditSheet: some View {
        NavigationStack {
            Form {
                Section("Broker Host") {
                    TextField("broker.hivemq.com", text: $hostDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section("WSS Port (iPhone)") {
                    TextField("8884", text: $portDraft)
                        .keyboardType(.numberPad)
                }
                Section("Credentials") {
                    TextField("Username", text: $usernameDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $passwordDraft)
                }
                Section {
                    Label("DJI RC Pro connects on port 8883 (TLS TCP). The port above is for the iPhone only. Credentials are required for private HiveMQ Cloud clusters.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MQTT Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showBrokerEdit = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        serverHost     = hostDraft.trimmingCharacters(in: .whitespaces)
                        serverUsername = usernameDraft.trimmingCharacters(in: .whitespaces)
                        serverPassword = passwordDraft
                        if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)) { serverPort = p }
                        showBrokerEdit = false
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func aboutRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}

// MARK: - Setup Step Row

private struct SetupStepRow: View {
    let number: Int
    let title:  String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.blue)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
