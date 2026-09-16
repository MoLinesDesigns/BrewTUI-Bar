import SwiftUI

/// `brew cleanup`, `brew autoremove` and `brew doctor` with the numbers up
/// front. "Smart Cleanup" was a Pro bullet the app could not act on: reclaiming
/// disk meant opening a terminal and reading the output yourself.
struct MaintenanceSectionView: View {
    @Bindable var manager: ManagerState
    @State private var showCleanupConfirm = false
    @State private var showAutoremoveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrystalGlass.Spacing.md) {
                if let error = manager.maintenanceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(BrewTUIBarTheme.critical(highContrast: false))
                        .padding(CrystalGlass.Spacing.sm)
                        .glassPanel(tint: BrewTUIBarTheme.critical(highContrast: false), strokeOpacity: 0.4)
                }
                cleanupCard
                autoremoveCard
                doctorCard
            }
            .padding(CrystalGlass.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack {
                Label(String(localized: "Reclaimable space"), systemImage: "trash.slash")
                    .font(.headline)
                Spacer()
                if manager.maintenanceBusy {
                    ProgressView().scaleEffect(0.5).frame(width: 20, height: 20)
                }
            }

            if let report = manager.cleanupReport {
                Text(report.totalBytes > 0 ? report.formattedTotal : String(localized: "Nothing to clean"))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(report.totalBytes > 0 ? CrystalGlass.glassCyan : .secondary)
                    .contentTransition(.numericText())

                if !report.entries.isEmpty {
                    Text(String(
                        format: String(localized: "%lld items: old versions, cached downloads and stale symlinks."),
                        Int64(report.entries.count)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // The five biggest entries answer "what is actually taking
                    // the space" without dumping a hundred Cellar paths.
                    ForEach(report.entries.sorted { $0.bytes > $1.bytes }.prefix(5)) { entry in
                        HStack {
                            Text(entry.displayName)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(entry.formattedSize)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if report.totalBytes > 0 {
                    Button {
                        showCleanupConfirm = true
                    } label: {
                        Label(String(localized: "Clean up now"), systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.glassPillProminent)
                    .disabled(manager.maintenanceBusy)
                    .confirmationDialog(
                        String(localized: "Run brew cleanup?"),
                        isPresented: $showCleanupConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Clean up")) {
                            Task { await manager.runCleanup() }
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    } message: {
                        Text(String(localized: "Homebrew deletes old versions and cached downloads. Installed packages are not affected."))
                    }
                }
            } else if !manager.maintenanceBusy {
                Button {
                    Task { await manager.previewMaintenance() }
                } label: {
                    Text(String(localized: "Check"))
                        .font(.caption)
                }
                .buttonStyle(.glassPill)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }

    private var autoremoveCard: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            Label(String(localized: "Unused dependencies"), systemImage: "arrow.triangle.branch")
                .font(.headline)

            if let candidates = manager.autoremoveCandidates {
                if candidates.isEmpty {
                    Text(String(localized: "Nothing left behind."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(candidates.joined(separator: "  ·  "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showAutoremoveConfirm = true
                    } label: {
                        Label(
                            String(format: String(localized: "Remove %lld"), Int64(candidates.count)),
                            systemImage: "trash"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.glassPill)
                    .disabled(manager.maintenanceBusy)
                    .confirmationDialog(
                        String(localized: "Remove unused dependencies?"),
                        isPresented: $showAutoremoveConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Remove"), role: .destructive) {
                            Task { await manager.runAutoremove() }
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    } message: {
                        Text(String(localized: "These formulae were installed as dependencies and nothing needs them any more."))
                    }
                }
            } else {
                Text(String(localized: "Not checked yet."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }

    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack {
                Label(String(localized: "Homebrew health"), systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await manager.runDoctor() }
                } label: {
                    Text(String(localized: "Run brew doctor"))
                        .font(.caption)
                }
                .buttonStyle(.glassPill)
                .disabled(manager.maintenanceBusy)
            }

            if let output = manager.doctorOutput {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else {
                Text(String(localized: "Checks taps, permissions, broken symlinks and outdated configuration."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }
}
