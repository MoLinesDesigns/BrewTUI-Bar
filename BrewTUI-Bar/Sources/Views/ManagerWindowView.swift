import SwiftUI
import AppKit

/// The manager window: everything that does not fit in a 340 pt popover.
///
/// Six sheets stacked on the popover was the alternative, and at that width a
/// service list or a snapshot diff is unreadable. This is a real window, opened
/// from the popover footer through the same `AppState` hook shape the package
/// detail window uses.
struct ManagerWindowView: View {
    let appState: AppState
    @Bindable var manager: ManagerState
    let onClose: () -> Void

    static let windowSize = CGSize(width: 860, height: 600)
    static let minimumSize = CGSize(width: 720, height: 460)

    var body: some View {
        // Hand-built sidebar instead of NavigationSplitView: the window is a
        // fixed two-pane utility, the split view's stock List selection reads
        // as a flat black block against this app's dark glass, and its toolbar
        // lives in a titlebar we deliberately hide. A plain HStack also renders
        // identically offscreen, which is what the screenshot suite captures.
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                header
                GlassDivider().padding(.horizontal, CrystalGlass.Spacing.md)
                if let notice = appState.actionNotice {
                    noticeBanner(notice)
                        .padding(.horizontal, CrystalGlass.Spacing.md)
                        .padding(.top, CrystalGlass.Spacing.sm)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CrystalAmbientBackground())
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .task(id: manager.selection) {
            await manager.loadIfNeeded(manager.selection)
        }
        .onExitCommand(perform: onClose)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "BrewTUI-Bar")
                .font(.headline)
                .padding(.horizontal, CrystalGlass.Spacing.md)
                .padding(.top, CrystalGlass.Spacing.lg)
                .padding(.bottom, CrystalGlass.Spacing.sm)
                .accessibilityAddTraits(.isHeader)

            ForEach(ManagerState.Section.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
        }
        .frame(width: 190, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.18))
    }

    private func sidebarRow(_ section: ManagerState.Section) -> some View {
        let isSelected = manager.selection == section
        return Button {
            manager.selection = section
        } label: {
            HStack(spacing: CrystalGlass.Spacing.sm) {
                Image(systemName: section.systemImage)
                    .font(.caption)
                    .frame(width: 18)
                Text(section.title)
                    .font(.callout)
                Spacer(minLength: 0)
                if section.requiresPro && !manager.isPro {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, CrystalGlass.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? CrystalGlass.glassCyan.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CrystalGlass.glassCyan.opacity(isSelected ? 0.45 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CrystalGlass.Spacing.sm)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var header: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Label(manager.selection.title, systemImage: manager.selection.systemImage)
                .font(.title3)
                .fontWeight(.semibold)
                .labelStyle(.titleOnly)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                Task { await manager.reload(manager.selection) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glassIcon)
            .help(String(localized: "Reload"))
            .accessibilityLabel(String(localized: "Reload"))

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glassIcon)
            .keyboardShortcut("w", modifiers: .command)
            .help(String(localized: "Close"))
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.md - 2)
    }

    @ViewBuilder
    private var detail: some View {
        if manager.selection.requiresPro && !manager.isPro {
            proGate
        } else {
            switch manager.selection {
            case .services:    ServicesSectionView(appState: appState)
            case .inventory:   InventorySectionView(appState: appState, manager: manager)
            case .history:     HistorySectionView(manager: manager)
            case .snapshots:   SnapshotsSectionView(manager: manager)
            case .profiles:    ProfilesSectionView(manager: manager)
            case .maintenance: MaintenanceSectionView(manager: manager)
            }
        }
    }

    /// Basic/expired licenses see the section framed, not hidden: knowing the
    /// data is there is the point of a funnel, and these sections mirror what
    /// the CLI already gates.
    private var proGate: some View {
        VStack(spacing: CrystalGlass.Spacing.md) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(CrystalGlass.warmAccent)
                .accessibilityHidden(true)
            Text(String(format: String(localized: "%@ is part of BrewTUI-Bar Pro"), manager.selection.title))
                .font(.headline)
            Text(String(localized: "Your Homebrew history, snapshots and profiles are already on this Mac — activate Pro to browse them here."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                NSWorkspace.shared.open(Self.pricingURL)
            } label: {
                Text(String(localized: "See plans"))
            }
            .buttonStyle(.glassPill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private static let pricingURL = URL(string: "https://molinesdesigns.com/brewtui-bar/#pricing")!

    private func noticeBanner(_ notice: ActionNotice) -> some View {
        HStack(alignment: .top, spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? BrewTUIBarTheme.critical(highContrast: false) : .green)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let command = notice.terminalCommand {
                Button {
                    do {
                        try TerminalHandoff.run(
                            command: command,
                            label: "action",
                            announcement: String(localized: "This needs your administrator password.")
                        )
                        appState.dismissActionNotice()
                    } catch {
                        TerminalHandoff.presentFailure(error)
                    }
                } label: {
                    Label(String(localized: "Run in Terminal"), systemImage: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.glassPill)
            }
            Button {
                appState.dismissActionNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.glassIcon)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(CrystalGlass.Spacing.md)
        .glassPanel(
            tint: notice.isError ? BrewTUIBarTheme.critical(highContrast: false) : .clear,
            strokeOpacity: 0.4
        )
    }
}

/// Shared empty-state scaffolding so every section reports "nothing here" the
/// same way. Sections differ in content, not in how they render emptiness.
struct SectionPlaceholder: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
