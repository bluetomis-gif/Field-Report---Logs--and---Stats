//
//  FieldReport__Logs_and_StatsApp.swift
//  FieldReport: Logs and Stats
//

import SwiftUI

@main
struct FieldReport__Logs_and_StatsApp: App {
    @State private var bridge = TelemetryBridge()
    @State private var logger = FlightLogger()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bridge)
                .environment(logger)
        }
    }
}
