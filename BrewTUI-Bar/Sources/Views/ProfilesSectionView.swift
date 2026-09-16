import SwiftUI
import AppKit

/// Package profiles saved by the CLI, plus the exported Brewfile.
///
/// The CLI has no `profile apply` subcommand — profiles live inside its
/// interactive TUI — so this view computes the missing set against the
/// inventory and installs it with plain `brew install`, rather than printing a
/// command that does not exist.
struct ProfilesSectionView: View {
    @Bindable var manager: ManagerState
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if manager.profilesLoading && manager.profiles.isEmpty {
                ProgressView(String(localized: "Reading profiles…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = manager.profilesError {
                SectionPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not read profiles"),
                    message: error
                )
            } else if manager.profiles.isEmpty && manager.brewfile == nil {
                SectionPlaceholder(
                    systemImage: "person.2.crop.square.stack",
                    title: String(localized: "No profiles saved"),
                    message: String(localized: "Save a package set from BrewTUI-Bar and it shows up here, ready to apply on another Mac.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: CrystalGlass.Spacing.sm) {
                        ForEach(manager.profiles) { profile in
                            card(profile)
                        }
                        if let brewfile = manager.brewfile {
                            brewfileCard(brewfile)
                        }
                        exportCard
                    }
                    .padding(CrystalGlass.Spacing.md)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ profile: BrewProfile) -> some View {
        let missing = profile.missingPackages(installed: manager.inventory)
        let isExpanded = expanded.contains(profile.id)

        return VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: CrystalGlass.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                    if let description = profile.profile.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(String(format: String(localized: "%lld packages"), Int64(profile.packageCount)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: CrystalGlass.Spacing.sm) {
                if missing.isEmpty {
                    Label(String(localized: "Fully installed"), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label(
                        String(format: String(localized: "%lld missing"), Int64(missing.count)),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(CrystalGlass.warmAccent)

                    Button {
                        Task { await manager.applyProfile(profile) }
                    } label: {
                        Label(String(localized: "Install missing"), systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.glassPill)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BrewProfile.installCommand(for: missing), forType: .string)
                    } label: {
                        Label(String(localized: "Copy command"), systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.glassPill)
                }

                Spacer()

                Button {
                    if isExpanded { expanded.remove(profile.id) } else { expanded.insert(profile.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.glassIcon)
                .accessibilityLabel(isExpanded ? String(localized: "Hide packages") : String(localized: "Show packages"))
            }

            if isExpanded {
                let names = profile.profile.formulae + profile.profile.casks
                Text(names.joined(separator: "  ·  "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }

    private func brewfileCard(_ brewfile: BrewfileStatus) -> some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack {
                Label(String(localized: "Brewfile"), systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                if brewfile.entryCount > 0 {
                    Text(String(format: String(localized: "%lld entries"), Int64(brewfile.entryCount)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let modified = brewfile.modifiedAt {
                Text(String(
                    format: String(localized: "Exported %@"),
                    modified.formatted(.relative(presentation: .named))
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([brewfile.url])
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.glassPill)
        }
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }

    /// `brew bundle dump` is a real Homebrew command and writes a portable
    /// Brewfile — the practical way to carry this machine's setup to another.
    private var exportCard: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            Label(String(localized: "Export this Mac"), systemImage: "square.and.arrow.up")
                .font(.headline)
            Text(String(localized: "Writes a Brewfile with every formula, cask and tap installed here."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                exportBrewfile()
            } label: {
                Label(String(localized: "Save Brewfile…"), systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.glassPill)
            .disabled(manager.maintenanceBusy)
        }
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(strokeOpacity: 0.3, ambientGlow: 0.05)
    }

    private func exportBrewfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Brewfile")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.dumpBrewfile(to: url) }
    }
}
