import SwiftUI

/// Snapshots the CLI captures before it changes anything, plus the diff nobody
/// could see until now: what changed between a capture and this machine right
/// now (or between two consecutive captures).
struct SnapshotsSectionView: View {
    @Bindable var manager: ManagerState

    var body: some View {
        Group {
            if manager.snapshotsLoading && manager.snapshots.isEmpty {
                ProgressView(String(localized: "Reading snapshots…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = manager.snapshotsError {
                SectionPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not read snapshots"),
                    message: error
                )
            } else if manager.snapshots.isEmpty {
                SectionPlaceholder(
                    systemImage: "camera.viewfinder",
                    title: String(localized: "No snapshots yet"),
                    message: String(localized: "BrewTUI-Bar captures one before every batch action.")
                )
            } else {
                HSplitView {
                    snapshotList
                        .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
                    diffPane
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var snapshotList: some View {
        List(manager.snapshots, selection: Binding(
            get: { manager.selectedSnapshotID },
            set: { newValue in
                manager.selectedSnapshotID = newValue
                Task { await manager.computeDiff() }
            }
        )) { snapshot in
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                Text(String(format: String(localized: "%lld packages"), Int64(snapshot.packageCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(snapshot.id)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GlassDivider().padding(.horizontal, CrystalGlass.Spacing.md)

            if let diff = manager.snapshotDiff {
                if diff.isEmpty {
                    SectionPlaceholder(
                        systemImage: "equal.circle",
                        title: String(localized: "No differences"),
                        message: manager.diffIsAgainstNow
                            ? String(localized: "This machine matches the snapshot.")
                            : String(localized: "Nothing changed between these two captures.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            group(
                                title: String(localized: "Updated"),
                                systemImage: "arrow.up.circle",
                                color: CrystalGlass.glassCyan,
                                rows: diff.changed.map { "\($0.name)  \($0.from) → \($0.to)" }
                            )
                            group(
                                title: String(localized: "Added"),
                                systemImage: "plus.circle",
                                color: .green,
                                rows: diff.added
                            )
                            group(
                                title: String(localized: "Removed"),
                                systemImage: "minus.circle",
                                color: CrystalGlass.warmAccent,
                                rows: diff.removed
                            )
                        }
                        .padding(CrystalGlass.Spacing.md)
                    }
                }
            } else if manager.diffLoading {
                ProgressView(String(localized: "Comparing…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Never an unconditional spinner: when the installed list
                // cannot be read the diff has no second side, and a spinner
                // there just hangs forever.
                SectionPlaceholder(
                    systemImage: "questionmark.circle",
                    title: String(localized: "Nothing to compare"),
                    message: manager.diffUnavailableReason
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Picker(String(localized: "Compare with"), selection: Binding(
                get: { manager.diffIsAgainstNow },
                set: { againstNow in
                    Task {
                        if againstNow {
                            await manager.computeDiff()
                        } else {
                            await manager.computeDiffAgainstPrevious()
                        }
                    }
                }
            )) {
                Text(String(localized: "This Mac now")).tag(true)
                Text(String(localized: "Previous snapshot")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            if let diff = manager.snapshotDiff, !diff.isEmpty {
                Text(String(format: String(localized: "%lld changes"), Int64(diff.totalCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
    }

    @ViewBuilder
    private func group(title: String, systemImage: String, color: Color, rows: [String]) -> some View {
        if !rows.isEmpty {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.top, CrystalGlass.Spacing.xs)
            ForEach(rows, id: \.self) { row in
                Text(row)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CrystalGlass.Spacing.sm)
                    .padding(.vertical, 3)
            }
        }
    }
}
