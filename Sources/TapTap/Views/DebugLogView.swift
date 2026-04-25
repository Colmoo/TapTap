import SwiftUI

struct DebugLogView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Event Log")
                    .font(.headline)
                Spacer()
                Button("Clear") { env.logger.clear() }
                    .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            if env.logger.entries.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "waveform",
                    description: Text("Start listening or tap Simulate to see events here.")
                )
            } else {
                List(env.logger.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.sfSymbol)
                            .foregroundStyle(color(for: entry.kind))
                            .frame(width: 16)

                        Text(entry.timeString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .detection:  .blue
        case .execution:  .green
        case .error:      .red
        case .system:     .secondary
        }
    }
}
