//
//  ContentView.swift
//  FieldReport: Logs and Stats
//
//  Root view — always shows the tab bar.
//  MQTT connects automatically on launch; the dashboard
//  reflects connection state in real time.
//

import SwiftUI

struct ContentView: View {
    @Environment(TelemetryBridge.self) private var bridge
    @Environment(FlightLogger.self)   private var logger

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.high") }

            LogListView()
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle.portrait") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.cyan)
        .onChange(of: bridge.frameCount) { _, _ in
            if let frame = bridge.latestFrame {
                logger.processFrame(frame)
            }
        }
        .onChange(of: bridge.droneConnected) { old, new in
            // Drone just came online → start post-flight snapshot if motors are off
            if new, !old, let frame = bridge.latestFrame {
                logger.droneReconnected(frame: frame)
            }
        }
        .onAppear {
            bridge.autoConnect()
        }
    }
}
