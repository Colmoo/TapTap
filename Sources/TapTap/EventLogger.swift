import Foundation
import Observation

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let kind: Kind

    enum Kind: Sendable {
        case detection, execution, error, system
    }

    var sfSymbol: String {
        switch kind {
        case .detection:  "waveform"
        case .execution:  "bolt.fill"
        case .error:      "exclamationmark.triangle"
        case .system:     "info.circle"
        }
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }
}

@Observable
@MainActor
final class EventLogger {
    private(set) var entries: [LogEntry] = []
    private let maxEntries = 200

    func log(_ message: String, kind: LogEntry.Kind = .system) {
        let entry = LogEntry(timestamp: Date(), message: message, kind: kind)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    func clear() {
        entries = []
    }
}
