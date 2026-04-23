//
//  BitPackEncoder.swift
//  FieldReport: Logs and Stats
//
//  Packs a telemetry frame into a compact binary payload, then Base64-encodes
//  it into a ≤100 character ASCII string suitable for satellite SMS / APRS.
//
//  Binary layout (40 bytes total):
//  ┌───────┬──────┬────────┬───────────────────────────────────────────────────┐
//  │ Offset│ Size │ Type   │ Field                                             │
//  ├───────┼──────┼────────┼───────────────────────────────────────────────────┤
//  │  0    │  2   │ UInt8  │ Magic: 0x46 'F', 0x52 'R'                        │
//  │  2    │  1   │ UInt8  │ Version: 0x01                                     │
//  │  3    │  1   │ UInt8  │ Flags (bit0=motorsOn,bit1=inSky,bit2=hasGPS,      │
//  │       │      │        │        bit3=hasBatt,bit4=hasSignal)               │
//  │  4    │  4   │ UInt32 │ Unix timestamp (seconds, big-endian)              │
//  │  8    │  4   │ UInt32 │ Latitude * 1e5 + 9_000_000 (unsigned bias)       │
//  │ 12    │  4   │ UInt32 │ Longitude * 1e5 + 18_000_000 (unsigned bias)     │
//  │ 16    │  2   │ Int16  │ Altitude MSL (whole metres)                       │
//  │ 18    │  2   │ Int16  │ Vertical speed (cm/s)                             │
//  │ 20    │  2   │ UInt16 │ Horizontal speed (cm/s)                           │
//  │ 22    │  1   │ UInt8  │ Battery percent (0-100)                           │
//  │ 23    │  2   │ UInt16 │ Battery voltage (mV)                              │
//  │ 25    │  1   │ UInt8  │ Signal quality (0-100)                            │
//  │ 26    │  2   │ UInt16 │ Heading (degrees * 10, 0-3599)                    │
//  │ 28    │  1   │ UInt8  │ Wind speed (dm/s, decimetres/sec)                 │
//  │ 29    │  2   │ Int16  │ Pitch (degrees * 100)                             │
//  │ 31    │  2   │ Int16  │ Roll (degrees * 100)                              │
//  │ 33    │  1   │ UInt8  │ RC signal quality (0-100)                         │
//  │ 34    │  2   │ UInt16 │ Home distance (whole metres, max 65535 m)         │
//  │ 36    │  1   │ UInt8  │ Mode code                                         │
//  │ 37    │  1   │ UInt8  │ Battery temperature (°C + 40 bias, 0=−40°C)      │
//  │ 38    │  2   │ UInt16 │ CRC-16/CCITT checksum of bytes 0-37              │
//  └───────┴──────┴────────┴───────────────────────────────────────────────────┘
//
//  40 bytes binary → 56 chars Base64 → "FR1:" prefix → 60 chars total (≤100 ✓)
//

import Foundation

enum BitPackEncoder {

    static let prefix = "FR1:"

    // MARK: - Encode

    static func encode(_ frame: DJITelemetryFrame) -> String {
        let d = frame.data
        var buf = Data(count: 40)

        // Magic + version
        buf[0] = 0x46  // 'F'
        buf[1] = 0x52  // 'R'
        buf[2] = 0x01  // version

        // Flags
        var flags: UInt8 = 0
        if d.motorsOn   == true { flags |= 0x01 }
        if d.inTheSky   == true { flags |= 0x02 }
        if d.latitude   != nil  { flags |= 0x04 }
        if d.battery    != nil  { flags |= 0x08 }
        if d.signalQuality != nil { flags |= 0x10 }
        buf[3] = flags

        // Timestamp (4 bytes big-endian)
        let ts = UInt32(frame.timestamp) & 0xFFFFFFFF
        writeBEU32(&buf, offset: 4, value: ts)

        // GPS
        let latEnc = UInt32(clamp((d.latitude ?? 0.0) * 1e5 + 9_000_000, lo: 0, hi: 18_000_000))
        let lonEnc = UInt32(clamp((d.longitude ?? 0.0) * 1e5 + 18_000_000, lo: 0, hi: 36_000_000))
        writeBEU32(&buf, offset: 8,  value: latEnc)
        writeBEU32(&buf, offset: 12, value: lonEnc)

        // Altitude (Int16, whole metres)
        let alt = Int16(clamp(d.height ?? 0, lo: -32768, hi: 32767))
        writeBEI16(&buf, offset: 16, value: alt)

        // Vertical speed (Int16, cm/s)
        let vspd = Int16(clamp((d.verticalSpeed ?? 0) * 100, lo: -32768, hi: 32767))
        writeBEI16(&buf, offset: 18, value: vspd)

        // Horizontal speed (UInt16, cm/s)
        let hspd = UInt16(clamp((d.effectiveHorizontalSpeed ?? 0) * 100, lo: 0, hi: 65535))
        writeBEU16(&buf, offset: 20, value: hspd)

        // Battery
        buf[22] = UInt8(clamp(d.battery?.capacityPercent ?? 0, lo: 0, hi: 100))
        let battMv = UInt16(clamp((d.battery?.voltage ?? 0) * 1000, lo: 0, hi: 65535))
        writeBEU16(&buf, offset: 23, value: battMv)

        // Signal
        buf[25] = UInt8(clamp(d.signalQuality ?? 0, lo: 0, hi: 100))

        // Heading (UInt16, degrees*10)
        let hdg = UInt16(clamp((d.attitudeHead ?? 0) * 10, lo: 0, hi: 3599))
        writeBEU16(&buf, offset: 26, value: hdg)

        // Wind speed (UInt8, dm/s)
        buf[28] = UInt8(clamp((d.windSpeed ?? 0) * 10, lo: 0, hi: 255))

        // Pitch + Roll (Int16, degrees*100)
        let pitch = Int16(clamp((d.attitudePitch ?? 0) * 100, lo: -32768, hi: 32767))
        let roll  = Int16(clamp((d.attitudeRoll  ?? 0) * 100, lo: -32768, hi: 32767))
        writeBEI16(&buf, offset: 29, value: pitch)
        writeBEI16(&buf, offset: 31, value: roll)

        // RC signal + home distance + mode
        buf[33] = UInt8(clamp(d.rcSignalQuality ?? 0, lo: 0, hi: 100))
        let homeDist = UInt16(clamp(d.homeDistance ?? 0, lo: 0, hi: 65535))
        writeBEU16(&buf, offset: 34, value: homeDist)
        buf[36] = UInt8(clamp(d.modeCode ?? 0, lo: 0, hi: 255))

        // Battery temperature (°C + 40 bias, so 0°C → 40, -40°C → 0)
        let tempBiased = UInt8(clamp((d.battery?.temperature ?? 0) + 40, lo: 0, hi: 255))
        buf[37] = tempBiased

        // CRC-16/CCITT over bytes 0-37
        let crc = crc16ccitt(buf[0..<38])
        writeBEU16(&buf, offset: 38, value: crc)

        return prefix + buf.base64EncodedString()
    }

    // MARK: - Decode

    static func decode(_ encoded: String) -> BitPackedFrame? {
        guard encoded.hasPrefix(prefix) else { return nil }
        let b64 = String(encoded.dropFirst(prefix.count))
        guard let buf = Data(base64Encoded: b64), buf.count == 40 else { return nil }

        // Verify magic
        guard buf[0] == 0x46, buf[1] == 0x52, buf[2] == 0x01 else { return nil }

        // Verify CRC
        let storedCRC = readBEU16(buf, offset: 38)
        guard crc16ccitt(buf[0..<38]) == storedCRC else { return nil }

        let flags = buf[3]
        let ts    = TimeInterval(readBEU32(buf, offset: 4))

        let latRaw = Double(readBEU32(buf, offset: 8))
        let lonRaw = Double(readBEU32(buf, offset: 12))
        let lat = (latRaw - 9_000_000) / 1e5
        let lon = (lonRaw - 18_000_000) / 1e5

        let alt   = Double(readBEI16(buf, offset: 16))
        let vspd  = Double(readBEI16(buf, offset: 18)) / 100.0
        let hspd  = Double(readBEU16(buf, offset: 20)) / 100.0
        let battPct  = Int(buf[22])
        let battMv   = Double(readBEU16(buf, offset: 23)) / 1000.0
        let signal   = Int(buf[25])
        let hdg      = Double(readBEU16(buf, offset: 26)) / 10.0
        let windSpd  = Double(buf[28]) / 10.0
        let pitch    = Double(readBEI16(buf, offset: 29)) / 100.0
        let roll     = Double(readBEI16(buf, offset: 31)) / 100.0
        let rcSignal = Int(buf[33])
        let homeDist = Double(readBEU16(buf, offset: 34))
        let mode     = Int(buf[36])
        let temp     = Double(buf[37]) - 40.0

        return BitPackedFrame(
            timestamp:        ts,
            motorsOn:         (flags & 0x01) != 0,
            inTheSky:         (flags & 0x02) != 0,
            latitude:         (flags & 0x04) != 0 ? lat : nil,
            longitude:        (flags & 0x04) != 0 ? lon : nil,
            altitudeMSL:      alt,
            verticalSpeedMs:  vspd,
            horizontalSpeedMs: hspd,
            batteryPercent:   battPct,
            batteryVoltage:   battMv,
            signalQuality:    signal,
            headingDeg:       hdg,
            windSpeedMs:      windSpd,
            pitchDeg:         pitch,
            rollDeg:          roll,
            rcSignalQuality:  rcSignal,
            homeDistanceM:    homeDist,
            modeCode:         mode,
            batteryTempC:     temp
        )
    }

    // MARK: - CRC-16/CCITT (poly 0x1021, init 0xFFFF)

    static func crc16ccitt<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    // MARK: - Buffer Helpers

    private static func writeBEU32(_ buf: inout Data, offset: Int, value: UInt32) {
        buf[offset + 0] = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8)  & 0xFF)
        buf[offset + 3] = UInt8( value         & 0xFF)
    }

    private static func writeBEU16(_ buf: inout Data, offset: Int, value: UInt16) {
        buf[offset + 0] = UInt8((value >> 8) & 0xFF)
        buf[offset + 1] = UInt8( value        & 0xFF)
    }

    private static func writeBEI16(_ buf: inout Data, offset: Int, value: Int16) {
        writeBEU16(&buf, offset: offset, value: UInt16(bitPattern: value))
    }

    private static func readBEU32(_ buf: Data, offset: Int) -> UInt32 {
        UInt32(buf[offset]) << 24 | UInt32(buf[offset+1]) << 16 |
        UInt32(buf[offset+2]) << 8 | UInt32(buf[offset+3])
    }

    private static func readBEU16(_ buf: Data, offset: Int) -> UInt16 {
        UInt16(buf[offset]) << 8 | UInt16(buf[offset+1])
    }

    private static func readBEI16(_ buf: Data, offset: Int) -> Int16 {
        Int16(bitPattern: readBEU16(buf, offset: offset))
    }

    private static func clamp<T: Comparable>(_ v: T, lo: T, hi: T) -> T {
        min(max(v, lo), hi)
    }
}

// MARK: - Decoded Frame

struct BitPackedFrame {
    let timestamp: TimeInterval
    let motorsOn: Bool
    let inTheSky: Bool
    let latitude: Double?
    let longitude: Double?
    let altitudeMSL: Double
    let verticalSpeedMs: Double
    let horizontalSpeedMs: Double
    let batteryPercent: Int
    let batteryVoltage: Double
    let signalQuality: Int
    let headingDeg: Double
    let windSpeedMs: Double
    let pitchDeg: Double
    let rollDeg: Double
    let rcSignalQuality: Int
    let homeDistanceM: Double
    let modeCode: Int
    let batteryTempC: Double
}
