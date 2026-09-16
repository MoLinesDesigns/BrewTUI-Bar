import SwiftUI

/// Full `brew services` list with start / stop / restart.
///
/// The popover only ever rendered services that were *failing*, and only to
/// open a read-only diagnostics sheet: a menu bar app that can see a stopped
/// postgres but cannot start it is the asymmetry users notice first.
struct ServicesSectionView: View {
    let appState: AppState

    var body: some View {
        Group {
            if let error = appState.servicesError {
                SectionPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not read services"),
                    message: error
                )
            } else if appState.services.isEmpty {
                SectionPlaceholder(
                    systemImage: "bolt.horizontal.circle",
                    title: String(localized: "No Homebrew services"),
                    message: String(localized: "Formulae that ship a launchd service (postgresql, redis, nginx…) appear here once installed.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.sortedServices) { service in
                            row(service)
                        }
                    }
                    .padding(CrystalGlass.Spacing.md)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ service: BrewService) -> some View {
        HStack(spacing: CrystalGlass.Spacing.md) {
            statusDot(service)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(service.statusLabel)
                        .foregroundStyle(service.hasError ? BrewTUIBarTheme.critical(highContrast: false) : .secondary)
                    if let user = service.user, !user.isEmpty {
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                        Text(user)
                            .foregroundStyle(.tertiary)
                    }
                    if let code = service.exitCode, code != 0 {
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                        Text(String(format: String(localized: "exit %lld"), Int64(code)))
                            .foregroundStyle(BrewTUIBarTheme.critical(highContrast: false))
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: CrystalGlass.Spacing.sm)

            if appState.serviceActionInFlight == service.name {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 22, height: 22)
            } else {
                actionButtons(service)
            }
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm)
        .glassPanel(cornerRadius: 12, strokeOpacity: 0.25, ambientGlow: 0.04)
    }

    @ViewBuilder
    private func actionButtons(_ service: BrewService) -> some View {
        HStack(spacing: 6) {
            if service.isRunning {
                actionButton(.stop, service: service)
                actionButton(.restart, service: service)
            } else {
                actionButton(.start, service: service)
                if service.hasError {
                    actionButton(.restart, service: service)
                }
            }
            if service.hasError {
                Button {
                    Task { await appState.showServiceDiagnostics(for: service) }
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(.glassIcon)
                .help(String(localized: "Diagnostics"))
                .accessibilityLabel(String(format: String(localized: "Show diagnostics for %@"), service.name))
            }
        }
        // A second click while one action is in flight would race brew against
        // itself on the same plist.
        .disabled(appState.serviceActionInFlight != nil)
    }

    private func actionButton(_ action: BrewServiceAction, service: BrewService) -> some View {
        Button {
            Task { await appState.controlService(action, service: service) }
        } label: {
            Image(systemName: action.systemImage)
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.glassIcon)
        .help(action.label)
        .accessibilityLabel("\(action.label) \(service.name)")
    }

    private func statusDot(_ service: BrewService) -> some View {
        Circle()
            .fill(
                service.hasError
                    ? BrewTUIBarTheme.critical(highContrast: false)
                    : (service.isRunning ? Color.green : Color.secondary.opacity(0.4))
            )
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}
