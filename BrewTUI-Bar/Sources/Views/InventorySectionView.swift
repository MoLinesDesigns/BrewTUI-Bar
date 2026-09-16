import SwiftUI
import AppKit

/// Everything installed, not just what is outdated.
///
/// Sizes are computed on request (walking the Cellar for a few hundred
/// formulae is seconds of disk I/O, not something to do on every window open),
/// and the leaf filter is what makes "can I remove this?" answerable.
struct InventorySectionView: View {
    let appState: AppState
    @Bindable var manager: ManagerState
    @State private var pendingUninstall: InstalledPackage?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GlassDivider().padding(.horizontal, CrystalGlass.Spacing.md)

            if let warning = manager.inventoryWarning {
                HStack(spacing: CrystalGlass.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(CrystalGlass.warmAccent)
                        .accessibilityHidden(true)
                    Text(warning)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CrystalGlass.Spacing.md)
                .padding(.vertical, CrystalGlass.Spacing.xs)
            }

            if manager.inventoryLoading && manager.inventory.isEmpty {
                ProgressView(String(localized: "Reading installed packages…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = manager.inventoryError {
                SectionPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not read the package list"),
                    message: error
                )
            } else if manager.filteredInventory.isEmpty {
                SectionPlaceholder(
                    systemImage: "shippingbox",
                    title: String(localized: "Nothing to show"),
                    message: String(localized: "No installed package matches this filter.")
                )
            } else {
                list
            }
        }
        .confirmationDialog(
            pendingUninstall.map { String(format: String(localized: "Remove %@?"), $0.name) } ?? "",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let package = pendingUninstall {
                    Task { await manager.uninstall(package) }
                }
                pendingUninstall = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingUninstall = nil }
        } message: {
            Text(String(localized: "Homebrew will uninstall it from this Mac. Formulae that other packages depend on are kept by brew."))
        }
    }

    private var toolbar: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField(String(localized: "Filter packages"), text: $manager.inventoryQuery)
                .textFieldStyle(.plain)
                .frame(maxWidth: 220)

            Toggle(isOn: $manager.showLeavesOnly) {
                Text(String(localized: "Only leaves"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help(String(localized: "Formulae nothing else depends on"))

            Spacer()

            if let total = manager.inventoryTotalSize {
                Text(String(format: String(localized: "%@ on disk"), ByteFormat.string(from: total)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if manager.sizesLoading {
                ProgressView().scaleEffect(0.5).frame(width: 20, height: 20)
            } else if !manager.sizesComputed {
                Button {
                    Task { await manager.computeSizes() }
                } label: {
                    Label(String(localized: "Calculate sizes"), systemImage: "externaldrive")
                        .font(.caption)
                }
                .buttonStyle(.glassPill)
            }

            Text(String(format: String(localized: "%lld packages"), Int64(manager.filteredInventory.count)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(manager.filteredInventory) { package in
                    row(package)
                }
            }
            .padding(CrystalGlass.Spacing.md)
        }
    }

    private func row(_ package: InstalledPackage) -> some View {
        HStack(spacing: CrystalGlass.Spacing.md) {
            Image(systemName: package.kind == .cask ? "macwindow" : "terminal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.system(.body, design: .monospaced))
                HStack(spacing: 6) {
                    Text(package.versions.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    if package.hasMultipleVersions {
                        Text(String(localized: "old versions kept"))
                            .foregroundStyle(CrystalGlass.warmAccent)
                    }
                    if package.kind == .formula && !package.isLeaf {
                        Text(String(localized: "dependency"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }

            Spacer(minLength: CrystalGlass.Spacing.sm)

            if let size = package.formattedSize {
                Text(size)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                pendingUninstall = package
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.glassIcon)
            .disabled(!appState.canUpgrade)
            .help(String(localized: "Uninstall"))
            .accessibilityLabel(String(format: String(localized: "Uninstall %@"), package.name))
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.22, ambientGlow: 0.03)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    package.kind == .cask ? "brew info --cask \(package.name)" : "brew info \(package.name)",
                    forType: .string
                )
            } label: {
                Label(String(localized: "Copy info command"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
