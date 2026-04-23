//
//  LogListView.swift
//  FieldReport: Logs and Stats
//
//  Browse, share, and delete past flight log files.
//

import SwiftUI

struct LogListView: View {
    @Environment(FlightLogger.self) private var logger
    @State private var shareItem: URL?
    @State private var confirmDelete: FlightLogMeta?

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if logger.allLogs.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            .navigationTitle("Flight Logs")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { logger.refreshLogs() }
            .sheet(item: $shareItem) { url in
                ShareSheet(activityItems: [url])
            }
            .confirmationDialog(
                "Delete \(confirmDelete?.displayName ?? "")?",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let m = confirmDelete { logger.deleteLog(m) }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("This will permanently delete the CSV and JSON sidecar.")
            }
        }
    }

    // MARK: - List

    private var logList: some View {
        List {
            ForEach(logger.allLogs) { meta in
                LogRow(meta: meta, df: df)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            confirmDelete = meta
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            shareItem = meta.csvURL
                        } label: {
                            Label("Share CSV", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)

                        if meta.hasSidecar {
                            Button {
                                shareItem = meta.sidecarURL
                            } label: {
                                Label("Share JSON", systemImage: "doc.text")
                            }
                            .tint(.purple)
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Flight Logs",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Logs are created automatically\nwhen the drone's motors arm.")
        )
    }
}

// MARK: - Log Row

private struct LogRow: View {
    let meta: FlightLogMeta
    let df: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meta.displayName)
                .font(.system(size: 13, design: .monospaced).bold())
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 14) {
                Label(df.string(from: meta.createdAt), systemImage: "calendar")
                Label("\(meta.fileSizeKB) KB", systemImage: "doc.fill")
                if meta.hasSidecar {
                    Label("+ JSON", systemImage: "waveform.path.ecg")
                        .foregroundStyle(.purple)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
