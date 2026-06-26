import SwiftUI

struct OutdatedListView: View {
    let appState: AppState
    @State private var showUpgradeAllConfirm = false
    /// Segundos restantes por paquete (clave = `OutdatedPackage.id`). Cada
    /// paquete lleva su propia cuenta atrás independiente: arrancar una nueva
    /// no detiene las demás en curso.
    @State private var countdownRemaining: [OutdatedPackage.ID: Int] = [:]
    @State private var countdownTasks: [OutdatedPackage.ID: Task<Void, Never>] = [:]
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Segundos de margen antes de que un upgrade de un paquete arranque solo.
    private static let countdownSeconds = 3

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
                    ForEach(appState.outdatedPackages) { pkg in
                        packageRow(pkg)
                    }
                }
                .padding(.horizontal, CrystalGlass.Spacing.sm)
                .padding(.vertical, CrystalGlass.Spacing.sm)
            }
        }
    }

    private func packageRow(_ pkg: OutdatedPackage) -> some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
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
            // ACC-002: read each row as a single VoiceOver element so the
            // package, both versions and the pin badge come through together.
            .accessibilityElement(children: .combine)

            Spacer()

            if pkg.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(CrystalGlass.warmAccent)
                    .accessibilityLabel(String(localized: "Pinned"))
            }

            // Note: Task in button action — .task modifier not applicable here
            if appState.canUpgrade {
                if let remaining = countdownRemaining[pkg.id] {
                    // Cuenta atrás en curso: pulsar cancela y aborta el upgrade.
                    Button {
                        cancelCountdown(pkg.id)
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
                        startCountdown(for: pkg)
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
        .animation(.easeInOut(duration: 0.2), value: countdownRemaining[pkg.id])
    }

    // MARK: - Countdown

    /// Arranca la cuenta atrás de `countdownSeconds` para `pkg`; al agotarse,
    /// lanza el upgrade salvo que el usuario haya cancelado antes. Cada paquete
    /// tiene su propia cuenta atrás: pulsar otro paquete arranca una cuenta
    /// independiente sin detener las que ya están en marcha. Reclicar el mismo
    /// paquete reinicia solo su propia cuenta.
    private func startCountdown(for pkg: OutdatedPackage) {
        let id = pkg.id
        let name = pkg.name
        countdownTasks[id]?.cancel()
        countdownRemaining[id] = Self.countdownSeconds
        countdownTasks[id] = Task {
            for second in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                countdownRemaining[id] = second
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdownRemaining[id] = nil
            countdownTasks[id] = nil
            // Sin handle retenido: el upgrade debe sobrevivir al cierre del
            // popover (click fuera, foco a otra app).
            await appState.upgrade(package: name)
        }
    }

    private func cancelCountdown(_ id: OutdatedPackage.ID) {
        countdownTasks[id]?.cancel()
        countdownTasks[id] = nil
        countdownRemaining[id] = nil
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
