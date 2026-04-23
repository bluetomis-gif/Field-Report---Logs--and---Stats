//
//  TelemetryModels.swift
//  FieldReport: Logs and Stats
//
//  DJI Cloud API 2.0 OSD telemetry data models.
//  Topic: thing/product/{device_sn}/osd
//

import Foundation

// MARK: - Top-Level Frame

/// A single telemetry frame received from the DJI Cloud API bridge.
struct DJITelemetryFrame: Codable, Equatable {
    let deviceSn: String
    let timestamp: TimeInterval   // Unix milliseconds from DJI, converted to seconds on bridge
    let data: OSDData

    static func == (lhs: DJITelemetryFrame, rhs: DJITelemetryFrame) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.deviceSn == rhs.deviceSn
    }
}

// MARK: - OSD Payload

/// On-Screen Display data matching the DJI Cloud API v2 `osd` topic schema.
/// All fields are optional because the drone may omit fields between frames.
struct OSDData: Codable {
    // Position
    let latitude: Double?
    let longitude: Double?
    /// Height above sea level (MSL), metres
    let height: Double?
    /// Height above takeoff point (AGL), metres
    let elevation: Double?
    /// Distance from home point, metres
    let homeDistance: Double?

    // Motion
    let horizontalSpeed: Double?  // m/s
    let verticalSpeed: Double?    // m/s, positive = ascending
    let speedX: Double?           // m/s North
    let speedY: Double?           // m/s East
    let speedZ: Double?           // m/s Down

    // Attitude
    let attitudePitch: Double?    // degrees
    let attitudeRoll: Double?     // degrees
    let attitudeHead: Double?     // degrees, 0-360

    // Power
    let battery: BatteryInfo?

    // Comms
    let signalQuality: Int?       // 0-100, OcuSync downlink
    let rcSignalQuality: Int?     // 0-100, OcuSync uplink

    // Flight state
    /// true when rotors are spinning (armed)
    let motorsOn: Bool?
    /// true when drone has left the ground
    let inTheSky: Bool?
    /// DJI flight mode code (0=Standby, 1=Takeoff, 2=Auto, 11=Manual…)
    let modeCode: Int?
    /// Landing gear state (1=up, 2=down)
    let gear: Int?

    // Environment
    let windSpeed: Double?        // m/s
    let windDirection: Int?       // degrees

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, height, elevation, battery, gear
        case homeDistance    = "home_distance"
        case horizontalSpeed = "horizontal_speed"
        case verticalSpeed   = "vertical_speed"
        case speedX          = "speed_x"
        case speedY          = "speed_y"
        case speedZ          = "speed_z"
        case attitudePitch   = "attitude_pitch"
        case attitudeRoll    = "attitude_roll"
        case attitudeHead    = "attitude_head"
        case signalQuality   = "signal_quality"
        case rcSignalQuality = "rc_signal_quality"
        case motorsOn        = "motors_on"
        case inTheSky        = "in_the_sky"
        case modeCode        = "mode_code"
        case windSpeed       = "wind_speed"
        case windDirection   = "wind_direction"
    }
}

// MARK: - Battery

struct BatteryInfo: Codable {
    let capacityPercent: Int?     // 0-100
    let voltage: Double?          // Volts
    let temperature: Double?      // °C
    let landingPower: Bool?       // true when forced-landing voltage reached

    enum CodingKeys: String, CodingKey {
        case voltage, temperature
        case capacityPercent = "capacity_percent"
        case landingPower    = "landing_power"
    }
}

// MARK: - Computed Helpers

extension OSDData {
    /// Derived horizontal speed fallback: sqrt(vx²+vy²) when horizontal_speed absent.
    var effectiveHorizontalSpeed: Double? {
        if let h = horizontalSpeed { return h }
        if let x = speedX, let y = speedY { return sqrt(x*x + y*y) }
        return nil
    }

    var batteryLevel: BatteryLevel {
        guard let pct = battery?.capacityPercent else { return .unknown }
        switch pct {
        case 50...100: return .good
        case 25..<50:  return .warn
        default:       return .critical
        }
    }

    var signalLevel: SignalLevel {
        guard let q = signalQuality else { return .unknown }
        switch q {
        case 70...100: return .good
        case 40..<70:  return .warn
        default:       return .poor
        }
    }
}

extension OSDData {
    /// Empty frame — used as a safe fallback when the broker publishes a frame with no `data` key.
    init() {
        self.init(
            latitude: nil, longitude: nil, height: nil, elevation: nil,
            homeDistance: nil, horizontalSpeed: nil, verticalSpeed: nil,
            speedX: nil, speedY: nil, speedZ: nil,
            attitudePitch: nil, attitudeRoll: nil, attitudeHead: nil,
            battery: nil, signalQuality: nil, rcSignalQuality: nil,
            motorsOn: nil, inTheSky: nil, modeCode: nil, gear: nil,
            windSpeed: nil, windDirection: nil
        )
    }
}

enum BatteryLevel { case good, warn, critical, unknown }
enum SignalLevel   { case good, warn, poor, unknown }

// MARK: - Flight Event

/// A timestamped event entry for the live flight timeline view.
struct FlightEvent: Identifiable {
    let id     = UUID()
    let time:   Date
    let title:  String
    let detail: String?
    let kind:   Kind

    enum Kind {
        case info       // neutral informational
        case success    // positive milestone
        case warning    // degraded but still operational
        case critical   // failure / error
        case pending    // expected but not yet occurred
    }
}

// MARK: - Flight Log Record (in-memory)

/// A single timestamped snapshot written to the CSV log.
struct FlightLogRecord {
    let wallTime: Date
    let frame: DJITelemetryFrame

    /// CSV row (no newline)
    var csvRow: String {
        let d = frame.data
        let fields: [String] = [
            iso8601(wallTime),
            String(Int(frame.timestamp)),
            d.latitude.map  { String(format: "%.7f", $0) } ?? "",
            d.longitude.map { String(format: "%.7f", $0) } ?? "",
            d.height.map    { String(format: "%.2f", $0) } ?? "",
            d.elevation.map { String(format: "%.2f", $0) } ?? "",
            d.verticalSpeed.map          { String(format: "%.2f", $0) } ?? "",
            d.effectiveHorizontalSpeed.map { String(format: "%.2f", $0) } ?? "",
            d.battery?.capacityPercent.map { String($0) } ?? "",
            d.battery?.voltage.map         { String(format: "%.3f", $0) } ?? "",
            d.battery?.temperature.map     { String(format: "%.1f", $0) } ?? "",
            d.signalQuality.map   { String($0) } ?? "",
            d.rcSignalQuality.map { String($0) } ?? "",
            d.attitudeHead.map    { String(format: "%.1f", $0) } ?? "",
            d.attitudePitch.map   { String(format: "%.2f", $0) } ?? "",
            d.attitudeRoll.map    { String(format: "%.2f", $0) } ?? "",
            d.windSpeed.map       { String(format: "%.1f", $0) } ?? "",
            d.windDirection.map   { String($0) } ?? "",
            d.motorsOn.map  { $0 ? "1" : "0" } ?? "",
            d.inTheSky.map  { $0 ? "1" : "0" } ?? "",
            d.modeCode.map  { String($0) } ?? "",
            frame.deviceSn
        ]
        return fields.joined(separator: ",")
    }

    static let csvHeader = "wall_time,dji_timestamp,latitude,longitude,height_msl,height_agl,vertical_speed_ms,horizontal_speed_ms,battery_pct,battery_voltage,battery_temp_c,signal_quality,rc_signal_quality,heading_deg,pitch_deg,roll_deg,wind_speed_ms,wind_direction_deg,motors_on,in_sky,mode_code,device_sn"

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
