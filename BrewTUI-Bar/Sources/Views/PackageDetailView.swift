import AppKit
import SwiftUI

/// Contents of the centred package detail window, opened by clicking a row of
/// the outdated list (the row's upgrade arrow keeps its own, separate action).
///
/// Three jobs in one surface:
///  1. Extended `brew info` metadata for the package.
///  2. An Update button that runs the upgrade **immediately** — no grace
///     countdown, unlike the list row — and streams the live progress here.
///  3. On a clean run, an auto-close countdown so the window gets out of the
///     way on its own.
///
/// `package` is held **by value**. `runUpgradeStream` fires a refresh when it
/// finishes, so the package disappears from `appState.outdatedPackages` the
/// moment the upgrade succeeds; looking it up by name would blank the window
/// mid-countdown.
struct PackageDetailView: View {
    let package: OutdatedPackage
    let appState: AppState
    /// Content size of the window that hosts this view.
    static let windowSize = CGSize(width: 460, height: 480)

    /// Seconds the window stays up after a successful install. Injectable so
    /// the integration test can drive the whole arm → tick → close sequence
    /// without a five-second sleep.
    var autoCloseSeconds: Int = 5
    let onClose: () -> Void

    @State private var detail: PackageDetail?
    @State private var detailError: String?
    @State private var isLoadingDetail = true
    @State private var autoCloseRemaining: Int?

    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var highContrast: Bool { colorSchemeContrast == .increased }

    /// Live progress, but only while this window owns it (see
    /// `AppState.ProgressPresentation`).
    private var progress: InstallProgress? {
        guard appState.progressPresentation == .detailWindow else { return nil }
        return appState.installProgress
    }

    private var isInstalling: Bool {
        guard let progress else { return false }
        return !progress.isFinished
    }

    private var succeeded: Bool {
        guard let progress else { return false }
        return progress.isFinished && progress.finalError == nil
    }

    private var canInstall: Bool {
        appState.canUpgrade && !package.pinned && !isInstalling && !succeeded
    }

    /// What is rendered while `brew info` is still running: everything the
    /// outdated row already knew. The window paints instantly instead of
    /// waiting on a subprocess.
    private var shownDetail: PackageDetail {
        detail ?? .placeholder(for: package)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.lg) {
            header
                // El titlebar es transparente y `fullSizeContentView` mete el
                // contenido debajo, así que el semáforo de cerrar caería justo
                // encima del icono de la cabecera. AppDelegate lo oculta (el
                // pie ya tiene su botón Cerrar) y este inset deja el aire que
                // ocupaba, para que la ficha no arranque pegada al borde.
                .padding(.top, CrystalGlass.Spacing.sm)
            ScrollView {
                VStack(alignment: .leading, spacing: CrystalGlass.Spacing.md) {
                    versionCard
                    if let notice = statusNotice {
                        noticeRow(notice)
                    }
                    infoCard
                    if let progress {
                        installCard(progress)
                    }
                }
                .padding(.horizontal, 2)
            }
            footer
        }
        .padding(CrystalGlass.Spacing.lg)
        // Tamaño fijo, fijado por AppDelegate en la ventana. Dejar que la
        // ventana siguiera al contenido no funciona: medido en ejecución, la
        // ScrollView no repropaga su alto ideal cuando llega `brew info`
        // (`intrinsicContentSize` sube a 382,5 y la ventana se queda en 332),
        // así que la ficha cargada quedaba media oculta. Con alto fijo la
        // ventana está siempre exactamente centrada y lo que se pase —caveats
        // largos— hace scroll.
        // Sólo el ancho: el alto lo fija la ventana y el contenido lo rellena.
        // Clavar aquí el alto dejaba 32 pt sin ocupar, porque
        // `fullSizeContentView` extiende la content view bajo el titlebar.
        .frame(width: PackageDetailView.windowSize.width)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                Color.clear
                CrystalAmbientBackground()
                GlassPanelBackground(cornerRadius: CrystalGlass.Radius.panel, strokeOpacity: 0.6)
            }
            .ignoresSafeArea()
        }
        .task { await loadDetail() }
        // Arms the auto-close exactly once, when a run this window owns
        // succeeds. Ownership is enough of a gate on its own: only this
        // window's Update button calls `upgradeFromDetailWindow`, and closing
        // the window hands ownership straight back.
        .onChange(of: succeeded) { _, isDone in
            guard isDone, autoCloseRemaining == nil else { return }
            autoCloseRemaining = autoCloseSeconds
        }
        // Driving the tick from `.task(id:)` instead of a stored Task means
        // SwiftUI cancels it for us when the window goes away — no dangling
        // timer calling `onClose` on a torn-down window.
        .task(id: autoCloseRemaining) {
            guard let remaining = autoCloseRemaining else { return }
            guard remaining > 0 else {
                onClose()
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            autoCloseRemaining = remaining - 1
        }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: CrystalGlass.Spacing.md) {
            Image(systemName: package.kind == .cask ? "app.dashed" : "shippingbox.fill")
                .font(.title)
                .foregroundStyle(CrystalGlass.glassCyan)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: CrystalGlass.Spacing.sm) {
                    Text(package.kind == .cask
                        ? String(localized: "Cask")
                        : String(localized: "Formula"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CrystalGlass.glassCyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(CrystalGlass.glassCyan.opacity(0.16)))

                    if let title = shownDetail.title, !title.isEmpty, title != package.name {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: CrystalGlass.Spacing.sm)

            if package.pinned {
                Label(String(localized: "Pinned"), systemImage: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CrystalGlass.warmAccent)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: - Versions

    private var versionCard: some View {
        HStack(spacing: CrystalGlass.Spacing.lg) {
            versionColumn(
                title: String(localized: "Installed"),
                value: package.installedVersion,
                color: BrewTUIBarTheme.installedVersion(highContrast: highContrast)
            )

            Image(systemName: "arrow.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            versionColumn(
                title: String(localized: "Available"),
                value: shownDetail.latestVersion ?? package.currentVersion,
                color: BrewTUIBarTheme.currentVersion(highContrast: highContrast)
            )

            Spacer(minLength: 0)
        }
        .padding(CrystalGlass.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.25, ambientGlow: 0.04)
        .accessibilityElement(children: .combine)
    }

    private func versionColumn(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(legibilityWeight == .bold ? .bold : .medium)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    // MARK: - Notices

    /// Single most important caveat about this package, if any. Deprecation
    /// beats auto-updates beats pinning — they are rendered one at a time so
    /// the card does not turn into a wall of warnings.
    private var statusNotice: (icon: String, text: String, color: Color)? {
        if shownDetail.disabled {
            return ("xmark.octagon.fill",
                    shownDetail.deprecationReason.map {
                        String(format: String(localized: "Disabled in Homebrew: %@"), $0)
                    } ?? String(localized: "Disabled in Homebrew"),
                    BrewTUIBarTheme.critical(highContrast: highContrast))
        }
        if shownDetail.deprecated {
            return ("exclamationmark.triangle.fill",
                    shownDetail.deprecationReason.map {
                        String(format: String(localized: "Deprecated: %@"), $0)
                    } ?? String(localized: "Deprecated in Homebrew"),
                    BrewTUIBarTheme.warning(highContrast: highContrast))
        }
        if package.pinned {
            return ("pin.fill",
                    String(localized: "Pinned packages are not upgraded. Unpin it first with brewtui-bar."),
                    CrystalGlass.warmAccent)
        }
        if shownDetail.autoUpdates {
            return ("arrow.triangle.2.circlepath",
                    String(localized: "This cask updates itself — Homebrew may report nothing to do."),
                    BrewTUIBarTheme.warning(highContrast: highContrast))
        }
        return nil
    }

    private func noticeRow(_ notice: (icon: String, text: String, color: Color)) -> some View {
        HStack(alignment: .top, spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: notice.icon)
                .font(.caption)
                .foregroundStyle(notice.color)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(CrystalGlass.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(notice.color.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - brew info

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack(spacing: CrystalGlass.Spacing.sm) {
                Text(String(localized: "Package details"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if isLoadingDetail {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                }
                Spacer(minLength: 0)
            }

            if let description = shownDetail.desc, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !isLoadingDetail {
                Text(String(localized: "No description available"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let tap = shownDetail.tap, !tap.isEmpty {
                infoRow(label: String(localized: "Tap"), value: tap)
            }
            if let license = shownDetail.license, !license.isEmpty {
                infoRow(label: String(localized: "License"), value: license)
            }
            if !shownDetail.dependencies.isEmpty {
                infoRow(
                    label: String(localized: "Dependencies"),
                    value: shownDetail.dependencies.joined(separator: ", ")
                )
            }
            if let homepage = shownDetail.homepage {
                homepageRow(homepage)
            }
            if let caveats = shownDetail.caveats, !caveats.isEmpty {
                caveatsBlock(caveats)
            }
            if let detailError {
                Text(detailError)
                    .font(.caption)
                    .foregroundStyle(BrewTUIBarTheme.critical(highContrast: highContrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CrystalGlass.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.25, ambientGlow: 0.04)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CrystalGlass.Spacing.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func homepageRow(_ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CrystalGlass.Spacing.sm) {
            Text(String(localized: "Homepage"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Button {
                openURL(url)
            } label: {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(CrystalGlass.glassCyan)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .accessibilityLabel(String(format: String(localized: "Open homepage of %@"), package.name))
            Spacer(minLength: 0)
        }
    }

    private func caveatsBlock(_ caveats: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Caveats"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(caveats.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption2, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(CrystalGlass.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
        }
    }

    // MARK: - Live install

    private func installCard(_ progress: InstallProgress) -> some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.sm) {
            HStack(spacing: CrystalGlass.Spacing.sm) {
                Image(systemName: progress.isFinished
                    ? (progress.finalError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    : "arrow.down.circle.fill")
                    .foregroundStyle(progress.finalError != nil
                        ? BrewTUIBarTheme.critical(highContrast: highContrast)
                        : CrystalGlass.glassCyan)
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, isActive: !progress.isFinished)
                    .accessibilityHidden(true)
                Text(installHeadline(progress))
                    .font(.caption.weight(.semibold))
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
                Text("\(Int((progress.overallFraction * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            CrystalProgressBar(fraction: progress.overallFraction)
                .frame(height: 6)

            // Sólo cuando brew arrastra dependencias. Con un único paquete la
            // fila repetiría palabra por palabra el titular de arriba.
            if progress.packages.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(progress.packages) { item in
                        HStack(spacing: CrystalGlass.Spacing.sm) {
                            stageGlyph(item.stage)
                            Text(item.name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.stage.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let remaining = autoCloseRemaining {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(String(
                        format: String(localized: "Closing automatically in %lld s…"),
                        Int64(remaining)
                    ))
                    .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(CrystalGlass.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.35, ambientGlow: 0.05)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progress.overallFraction)
    }

    @ViewBuilder
    private func stageGlyph(_ stage: InstallStage) -> some View {
        switch stage {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(colorSchemeContrast == .increased ? Color(red: 0, green: 0.6, blue: 0) : .green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.caption2)
                .foregroundStyle(BrewTUIBarTheme.critical(highContrast: highContrast))
        case .pending:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        default:
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(CrystalGlass.glassCyan)
        }
    }

    private func installHeadline(_ progress: InstallProgress) -> String {
        if progress.isFinished {
            if let error = progress.finalError { return error }
            return String(format: String(localized: "%@ updated"), package.name)
        }
        if let current = progress.currentPackage, !current.stage.isTerminal {
            return String(format: String(localized: "%@ — %@"), current.name, current.stage.label)
        }
        return String(localized: "Preparing…")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Button(action: onClose) {
                Text(String(localized: "Close"))
            }
            .buttonStyle(.glassPill)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close package details"))

            Spacer()

            if !appState.canUpgrade {
                Label(String(localized: "Pro required"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Sin `.defaultAction`: la fila de la lista da 3 s de gracia para
            // cancelar y aquí la instalación es inmediata, así que un Return
            // accidental sobre una ventana recién enfocada no debe lanzar un
            // `brew upgrade` irreversible.
            Button {
                Task { await appState.upgradeFromDetailWindow(package: package.name) }
            } label: {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: succeeded ? "checkmark" : "arrow.up.circle.fill")
                            .font(.caption)
                    }
                    Text(installButtonTitle)
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.glassPillProminent)
            .disabled(!canInstall)
            .accessibilityLabel(String(format: String(localized: "Update %@ now"), package.name))
        }
    }

    private var installButtonTitle: String {
        if succeeded { return String(localized: "Updated") }
        if isInstalling { return String(localized: "Updating…") }
        let target = shownDetail.latestVersion ?? package.currentVersion
        return String(format: String(localized: "Update to %@"), target)
    }

    // MARK: - Loading

    private func loadDetail() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            detail = try await PackageInfoService.shared.detail(for: package)
            detailError = nil
        } catch {
            // Degrade instead of blanking: the header, versions and actions all
            // come from the outdated row, which is already on screen.
            detailError = String(
                format: String(localized: "Could not load extended details: %@"),
                error.localizedDescription
            )
        }
    }
}

// MARK: - Previews

#Preview("Formula") {
    PackageDetailView(
        package: PreviewData.outdatedPackages[0],
        appState: PreviewData.makeAppState(),
        onClose: {}
    )
}

#Preview("Pinned") {
    PackageDetailView(
        package: PreviewData.outdatedPackages[2],
        appState: PreviewData.makeAppState(),
        onClose: {}
    )
}

#Preview("Spanish") {
    PackageDetailView(
        package: PreviewData.outdatedPackages[0],
        appState: PreviewData.makeAppState(),
        onClose: {}
    )
    .environment(\.locale, Locale(identifier: "es"))
}
