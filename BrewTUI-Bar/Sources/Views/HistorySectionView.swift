import SwiftUI

/// Everything the CLI has done on this Mac, read from `history.json`.
///
/// The popover has been advertising "Action History" as a Pro feature since
/// the first release while the app had no way to display it — the file was
/// already on disk the whole time.
struct HistorySectionView: View {
    @Bindable var manager: ManagerState

    var body: some View {
        Group {
            if manager.historyLoading && manager.history.isEmpty {
                ProgressView(String(localized: "Reading history…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = manager.historyError {
                SectionPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not read the history"),
                    message: error
                )
            } else if manager.history.isEmpty {
                SectionPlaceholder(
                    systemImage: "clock.arrow.circlepath",
                    title: String(localized: "No actions recorded yet"),
                    message: String(localized: "Installs, upgrades and removals run from BrewTUI-Bar show up here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groupedHistory, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    row(entry)
                                }
                            } header: {
                                HStack {
                                    Text(group.day)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.top, CrystalGlass.Spacing.sm)
                                .padding(.horizontal, CrystalGlass.Spacing.xs)
                            }
                        }
                    }
                    .padding(CrystalGlass.Spacing.md)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Day buckets keep a long log readable; `history.json` is append-only and
    /// goes back months.
    private var groupedHistory: [(day: String, entries: [ActionHistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [ActionHistoryEntry]] = [:]
        for entry in manager.history {
            let day = calendar.startOfDay(for: entry.timestamp)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }
        return order.map { day in
            (day: day.formatted(date: .abbreviated, time: .omitted), entries: buckets[day] ?? [])
        }
    }

    private func row(_ entry: ActionHistoryEntry) -> some View {
        HStack(spacing: CrystalGlass.Spacing.md) {
            Image(systemName: entry.systemImage)
                .font(.caption)
                .foregroundStyle(entry.success ? CrystalGlass.glassCyan : BrewTUIBarTheme.critical(highContrast: false))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .font(.callout)
                if let error = entry.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(BrewTUIBarTheme.critical(highContrast: false))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: CrystalGlass.Spacing.sm)

            if !entry.success {
                Text(String(localized: "failed"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BrewTUIBarTheme.critical(highContrast: false))
            }
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.22, ambientGlow: 0.03)
        .accessibilityElement(children: .combine)
    }
}
