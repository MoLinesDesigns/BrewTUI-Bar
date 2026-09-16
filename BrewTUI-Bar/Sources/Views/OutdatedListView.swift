import SwiftUI
import AppKit

struct OutdatedListView: View {
    let appState: AppState
    @State private var showUpgradeAllConfirm = false
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    // La cuenta atrás vive en AppState, no en `@State`. AppDelegate recrea el
    // NSHostingController en cada apertura del popover, así que un `@State`
    // aquí se destruía con la vista: el upgrade seguía disparándose pero el
    // botón para cancelarlo desaparecía, y reabrir el popover permitía encolar
    // el mismo paquete otra vez.

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: String(localized: "%lld updates available"), Int64(appState.outdatedCount)))
                    .font(.subheadline)
                    .fontWeight(legibilityWeight == .bold ? .bold : .regular)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if appState.canUpgrade {
                    Button {
                        showUpgradeAllConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.caption)
                            Text(String(localized: "Upgrade All"))
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.glassPillProminent)
                    .disabled(appState.isLoading)
                    .accessibilityLabel(String(localized: "Upgrade All"))
                    .confirmationDialog(
                        String(localized: "Upgrade all packages?"),
                        isPresented: $showUpgradeAllConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Upgrade All")) {
                            // Sin handle retenido: el popover puede ocultarse
                            // (click fuera) y el upgrade debe completar igual.
                            Task { await appState.upgradeAll() }
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, CrystalGlass.Spacing.md)
            .padding(.vertical, CrystalGlass.Spacing.sm)

            GlassDivider().padding(.horizontal, CrystalGlass.Spacing.md)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appState.visibleOutdatedPackages) { pkg in
                        packageRow(pkg)
                    }
                    if appState.ignoredCount > 0 {
                        ignoredFooter
                    }
                }
                .padding(.horizontal, CrystalGlass.Spacing.sm)
                .padding(.vertical, CrystalGlass.Spacing.sm)
            }
        }
    }

    /// Silenced packages are hidden, not deleted — without this line the user
    /// has no way to tell "nothing to update" apart from "I muted four things
    /// last month", and no way back.
    private var ignoredFooter: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: "bell.slash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(String(format: String(localized: "%lld ignored"), Int64(appState.ignoredCount)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                appState.stopIgnoringAll()
            } label: {
                Text(String(localized: "Show all"))
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CrystalGlass.glassCyan)
            .accessibilityLabel(String(localized: "Stop ignoring every package"))
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.xs)
    }

    private func packageRow(_ pkg: OutdatedPackage) -> some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            // El bloque de texto es un Button de pleno derecho, no un
            // `.onTapGesture` sobre la fila: así abrir la ficha funciona
            // también con teclado y VoiceOver, y el botón de la flecha
            // conserva su propia zona de click sin ambigüedad.
            Button {
                appState.showPackageDetail(pkg)
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pkg.name)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        HStack(spacing: 4) {
                            Text(pkg.installedVersion)
                                .foregroundStyle(BrewTUIBarTheme.installedVersion(highContrast: colorSchemeContrast == .increased))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(pkg.currentVersion)
                                .foregroundStyle(BrewTUIBarTheme.currentVersion(highContrast: colorSchemeContrast == .increased))
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // ACC-002: read each row as a single VoiceOver element so the
            // package, both versions and the pin badge come through together.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pkg.name), \(pkg.installedVersion) → \(pkg.currentVersion)")
            .accessibilityHint(String(localized: "Opens the package details window"))

            if pkg.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(CrystalGlass.warmAccent)
                    .accessibilityLabel(String(localized: "Pinned"))
            }

            // Note: Task in button action — .task modifier not applicable here
            if appState.canUpgrade {
                if let remaining = appState.countdownRemaining[pkg.name] {
                    // Cuenta atrás en curso: pulsar cancela y aborta el upgrade.
                    Button {
                        appState.cancelUpgradeCountdown(for: pkg.name)
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(remaining)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.glassPill)
                    .accessibilityLabel(
                        String(format: String(localized: "Cancel upgrade of %@ (%lld seconds left)", comment: "Accessibility label for cancelling the auto-upgrade countdown of a package"), pkg.name, Int64(remaining))
                    )
                } else {
                    Button {
                        appState.startUpgradeCountdown(for: pkg.name)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.glassIcon)
                    .disabled(appState.isLoading || pkg.pinned)
                    .accessibilityLabel(
                        String(format: String(localized: "Upgrade %@", comment: "Accessibility label for upgrading a single package"), pkg.name)
                    )
                }
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Upgrade not available — Pro license required"))
            }
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
        .glassPanel(
            cornerRadius: 12,
            strokeOpacity: 0.25,
            ambientGlow: 0.04
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: appState.countdownRemaining[pkg.name])
        .contextMenu { rowMenu(pkg) }
    }

    /// Right-click actions for a row. Pin is formula-only (Homebrew has no cask
    /// pin at all), so casks get the app-local ignore list in its place — both
    /// are offered to formulae because they mean different things: pinning also
    /// stops `brew upgrade` in the terminal, ignoring only quiets this app.
    @ViewBuilder
    private func rowMenu(_ pkg: OutdatedPackage) -> some View {
        Button {
            appState.showPackageDetail(pkg)
        } label: {
            Label(String(localized: "Show details"), systemImage: "info.circle")
        }

        Divider()

        if pkg.kind == .formula {
            Button {
                Task { await appState.setPin(!pkg.pinned, package: pkg) }
            } label: {
                Label(
                    pkg.pinned ? String(localized: "Unpin in Homebrew") : String(localized: "Pin in Homebrew"),
                    systemImage: pkg.pinned ? "pin.slash" : "pin"
                )
            }
        }

        Button {
            appState.skipVersion(pkg)
        } label: {
            Label(
                String(format: String(localized: "Skip version %@"), pkg.currentVersion),
                systemImage: "bell.slash"
            )
        }

        Button {
            appState.ignoreAlways(pkg)
        } label: {
            Label(String(localized: "Always ignore this package"), systemImage: "eye.slash")
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(upgradeCommand(for: pkg), forType: .string)
        } label: {
            Label(String(localized: "Copy upgrade command"), systemImage: "doc.on.doc")
        }
    }

    private func upgradeCommand(for pkg: OutdatedPackage) -> String {
        pkg.kind == .cask ? "brew upgrade --cask \(pkg.name)" : "brew upgrade \(pkg.name)"
    }
}

// MARK: - Previews

#Preview("5 Packages") {
    OutdatedListView(appState: PreviewData.makeAppState())
        .frame(width: 340, height: 300)
}

#Preview("1 Package") {
    OutdatedListView(
        appState: PreviewData.makeAppState(packages: [PreviewData.outdatedPackages[0]])
    )
    .frame(width: 340, height: 200)
}

#Preview("Pinned Package") {
    OutdatedListView(
        appState: PreviewData.makeAppState(packages: [PreviewData.outdatedPackages[2]])
    )
    .frame(width: 340, height: 200)
}

#Preview("Spanish") {
    OutdatedListView(appState: PreviewData.makeAppState())
        .frame(width: 340, height: 300)
        .environment(\.locale, Locale(identifier: "es"))
}
