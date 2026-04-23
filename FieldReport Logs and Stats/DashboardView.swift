//
//  DashboardView.swift
//  FieldReport: Logs and Stats
//
//  Live telemetry dashboard with incident-timeline log style.
//  Adapts to system light / dark mode.
//

import SwiftUI

// MARK: - FlightEvent.Kind view helpers

private extension FlightEvent.Kind {
    var color: Color {
        switch self {
        case .info:     return .blue
        case .success:  return .green
        case .warning:  return .orange
        case .critical: return .red
        case .pending:  return Color(.systemGray3)
        }
    }

    var systemImage: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .success:  return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .pending:  return "circle"
        }
    }
}

// MARK: - Hero header shape (flat top, rounded bottom corners)

private struct HeroShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(0),   endAngle: .degrees(90),  clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(90),  endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
        }
    }
}

// MARK: - Dashboard Root

struct DashboardView: View {
    @Environment(TelemetryBridge.self) private var bridge
    @Environment(FlightLogger.self)   private var logger

    @AppStorage("sessionCode") private var sessionCode: String = ""

    private var allEvents: [FlightEvent] {
        (bridge.events + logger.events).sorted { $0.time > $1.time }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    statusHeader

                    VStack(spacing: 14) {
                        statsRow
                        gpsCard
                        signalAttitudeCard
                        if !allEvents.isEmpty {
                            eventsSection
                        }
                        lifelineCard(at: timeline.date)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [headerColor, headerColor.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(HeroShape(radius: 22))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 50, height: 50)
                        Image(systemName: "airplane")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bridge.latestFrame?.deviceSn ?? "FieldReport")
                            .font(.headline)
                            .foregroundStyle(.white)
                        HStack(spacing: 5) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption2)
                            Text("MQTT · HiveMQ Cloud")
                                .font(.caption2)
                        }
                        .foregroundStyle(.white.opacity(0.70))
                    }

                    Spacer()
                    stateBadge
                }

                Text(sessionTitle)
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(bridge.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Label("Session  \(sessionCode)", systemImage: "number.square.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer()
                    if logger.isLogging {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("REC · \(logger.recordCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.red.opacity(0.30))
                        .clipShape(Capsule())
                    }
                }

                // Connect / Disconnect button
                connectButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    private var headerColor: Color {
        switch bridge.sessionState {
        case .live:
            return bridge.droneConnected
                ? Color(hue: 0.37, saturation: 0.72, brightness: 0.42)
                : Color(hue: 0.60, saturation: 0.72, brightness: 0.50)
        case .waiting:    return Color(hue: 0.60, saturation: 0.72, brightness: 0.50)
        case .connecting: return Color(hue: 0.09, saturation: 0.80, brightness: 0.58)
        case .idle:       return Color(hue: 0.00, saturation: 0.65, brightness: 0.42)
        }
    }

    private var stateBadge: some View {
        let (label, bg): (String, Color) = {
            switch bridge.sessionState {
            case .live where bridge.droneConnected: return ("LIVE",       .green)
            case .live:                             return ("WAITING",    .blue)
            case .waiting:                          return ("WAITING",    .blue)
            case .connecting:                       return ("CONNECTING", .orange)
            case .idle:                             return ("OFFLINE",    .red)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(bg.opacity(0.40))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1))
    }

    private var sessionTitle: String {
        guard let frame = bridge.latestFrame else {
            switch bridge.sessionState {
            case .connecting: return "Connecting to Broker…"
            case .waiting:    return "Waiting for Drone…"
            default:          return "Tap Connect to Start"
            }
        }
        return (frame.data.inTheSky ?? false)
            ? "Airborne · \(frame.deviceSn)"
            : "On Ground · \(frame.deviceSn)"
    }

    private var connectButton: some View {
        Group {
            if bridge.sessionState == .idle {
                Button {
                    bridge.autoConnect()
                } label: {
                    Label("Connect", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                .foregroundStyle(.white)
            } else {
                Button {
                    bridge.endSession()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.15))
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let d         = bridge.latestFrame?.data
        let battLevel = d?.batteryLevel ?? .unknown
        return HStack(spacing: 12) {
            StatChip(icon: "arrow.up.circle.fill", color: .blue,
                     value: d?.height.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "m", label: "Altitude MSL")
            StatChip(icon: "speedometer", color: .indigo,
                     value: d?.effectiveHorizontalSpeed.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "m/s", label: "Horiz Speed")
            StatChip(icon: "bolt.fill", color: batteryColor(battLevel),
                     value: d?.battery?.capacityPercent.map { "\($0)" } ?? "—",
                     unit: "%", label: "Battery")
        }
    }

    // MARK: - GPS Card

    private var gpsCard: some View {
        let d = bridge.latestFrame?.data
        return SectionCard(title: "GPS Position", icon: "location.fill", color: .blue) {
            if let lat = d?.latitude, let lon = d?.longitude {
                VStack(spacing: 10) {
                    HStack(alignment: .top) {
                        DataColumn(label: "Latitude",  value: String(format: "%.6f°", lat))
                        Spacer()
                        DataColumn(label: "Longitude", value: String(format: "%.6f°", lon))
                    }
                    Divider()
                    HStack {
                        DataColumn(label: "AGL",
                                   value: d?.elevation.map     { String(format: "%.1f m",    $0) } ?? "—")
                        Spacer()
                        DataColumn(label: "Home Dist",
                                   value: d?.homeDistance.map  { String(format: "%.0f m",    $0) } ?? "—")
                        Spacer()
                        DataColumn(label: "Vert Speed",
                                   value: d?.verticalSpeed.map { String(format: "%+.1f m/s", $0) } ?? "—")
                    }
                }
            } else {
                Label("No GPS fix yet", systemImage: "location.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Signal + Attitude Card

    private var signalAttitudeCard: some View {
        let d     = bridge.latestFrame?.data
        let level = d?.signalLevel ?? .unknown
        return SectionCard(title: "Signal & Attitude",
                           icon: "antenna.radiowaves.left.and.right",
                           color: signalColor(level)) {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    SignalColumn(label: "Downlink",  quality: d?.signalQuality   ?? 0)
                    SignalColumn(label: "RC Uplink", quality: d?.rcSignalQuality ?? 0)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        StateChip(label: (d?.motorsOn ?? false) ? "ARMED"    : "SAFE",
                                  color: (d?.motorsOn ?? false) ? .orange    : Color(.systemGray3))
                        StateChip(label: (d?.inTheSky ?? false) ? "AIRBORNE" : "ON GROUND",
                                  color: (d?.inTheSky ?? false) ? .green     : Color(.systemGray3))
                    }
                }
                Divider()
                HStack {
                    DataColumn(label: "Pitch",
                               value: d?.attitudePitch.map { String(format: "%+.1f°",   $0) } ?? "—")
                    Spacer()
                    DataColumn(label: "Roll",
                               value: d?.attitudeRoll.map  { String(format: "%+.1f°",   $0) } ?? "—")
                    Spacer()
                    DataColumn(label: "Heading",
                               value: d?.attitudeHead.map  { String(format: "%.0f°",    $0) } ?? "—")
                    Spacer()
                    DataColumn(label: "Wind",
                               value: d?.windSpeed.map     { String(format: "%.1f m/s", $0) } ?? "—")
                }
            }
        }
    }

    // MARK: - Flight Events Timeline

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("FLIGHT EVENTS")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(allEvents.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(allEvents.enumerated()), id: \.element.id) { idx, event in
                    EventTimelineRow(event: event, isLast: idx == allEvents.count - 1)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Lifeline Card

    private func lifelineCard(at now: Date) -> some View {
        let age     = bridge.lastFrameReceivedAt.map { now.timeIntervalSince($0) } ?? -1
        let hasData = bridge.latestFrame != nil
        let encoded = bridge.latestFrame.map { BitPackEncoder.encode($0) } ?? "—"

        let (ageColor, ageLabel): (Color, String) = {
            guard hasData, age >= 0 else { return (.secondary, "No data yet") }
            switch age {
            case ..<2:  return (.green,  String(format: "%.1f s ago  ·  Fresh", age))
            case ..<5:  return (.orange, String(format: "%.1f s ago  ·  Slow",  age))
            default:    return (.red,    String(format: "%.0f s ago  ·  Stale", age))
            }
        }()

        return SectionCard(title: "Link Health  ·  Sat-SMS Lifeline",
                           icon: "waveform.path.ecg", color: ageColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ageColor.opacity(0.15)).frame(height: 5)
                            Capsule()
                                .fill(ageColor)
                                .frame(
                                    width: hasData
                                        ? geo.size.width * CGFloat(max(0, 1 - min(age, 10) / 10))
                                        : 0,
                                    height: 5
                                )
                                .animation(.linear(duration: 0.5), value: age)
                        }
                    }
                    .frame(height: 5)
                    Text(ageLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ageColor)
                        .fixedSize()
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SAT-SMS / APRS PAYLOAD")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                        Spacer()
                        Text("\(hasData ? encoded.count : 0) chars")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(encoded)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(hasData ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("If internet fails: copy and transmit via Iridium SMS or APRS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Color helpers

    private func batteryColor(_ level: BatteryLevel) -> Color {
        switch level {
        case .good:     return .green
        case .warn:     return .orange
        case .critical: return .red
        case .unknown:  return Color(.systemGray3)
        }
    }

    private func signalColor(_ level: SignalLevel) -> Color {
        switch level {
        case .good:    return .green
        case .warn:    return .orange
        case .poor:    return .red
        case .unknown: return Color(.systemGray3)
        }
    }
}

// MARK: - Sub-views

private struct StatChip: View {
    let icon:  String
    let color: Color
    let value: String
    let unit:  String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let icon:  String
    let color: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct DataColumn: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

private struct SignalColumn: View {
    let label:   String
    let quality: Int

    private var color: Color {
        guard quality > 0 else { return Color(.systemGray3) }
        return quality >= 70 ? .green : quality >= 40 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let active = i < Int((Double(quality) / 100.0) * 5 + 0.5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? color : color.opacity(0.20))
                        .frame(width: 5, height: CGFloat(6 + i * 3))
                }
            }
            Text("\(quality)%")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(color)
        }
    }
}

private struct StateChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
    }
}

private struct EventTimelineRow: View {
    let event:  FlightEvent
    let isLast: Bool

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Dot + connecting line
            VStack(spacing: 0) {
                Image(systemName: event.kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(event.kind.color)
                    .frame(width: 22, height: 22)
                if !isLast {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(width: 2)
                        .padding(.top, 3)
                        .frame(minHeight: 28)
                }
            }

            // Title + detail
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.kind.color)
                    Spacer()
                    Text(Self.timeFmt.string(from: event.time))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
    }
}
