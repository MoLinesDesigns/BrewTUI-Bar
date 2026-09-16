import Foundation
@preconcurrency import UserNotifications
import os

private let notifLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "NotificationSender")

// ARQ-009: extracted from SchedulerService so notification dispatch can be
// stubbed in tests and re-used from any caller (security daemon, sync poller).
// All identifiers carry a per-call timestamp so macOS does not silently drop
// follow-up notifications with the same id (UX-001).
/// Identifiers shared by the sender (which stamps them on the payload) and
/// AppDelegate (which acts on them when the user clicks). Kept in one place so
/// a rename cannot silently break the button — a wrong identifier produces a
/// notification whose actions do nothing at all.
enum NotificationAction {
    static let outdatedCategory = "brewtui-bar.outdated"
    static let cveCategory = "brewtui-bar.cve"
    static let syncCategory = "brewtui-bar.sync"
    static let upgradeAll = "brewtui-bar.action.upgrade-all"
    static let open = "brewtui-bar.action.open"

    /// Registers the categories so macOS renders the buttons. Must run before
    /// the first notification is posted; re-registering is harmless.
    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let upgradeAllAction = UNNotificationAction(
            identifier: upgradeAll,
            title: String(localized: "Upgrade all"),
            options: []
        )
        let openAction = UNNotificationAction(
            identifier: open,
            title: String(localized: "Open BrewTUI-Bar"),
            options: [.foreground]
        )
        let outdated = UNNotificationCategory(
            identifier: outdatedCategory,
            actions: [upgradeAllAction, openAction],
            intentIdentifiers: [],
            options: []
        )
        let cve = UNNotificationCategory(
            identifier: cveCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let sync = UNNotificationCategory(
            identifier: syncCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([outdated, cve, sync])
    }
}

protocol Notifying: Sendable {
    func sendOutdatedNotification(count: Int)
    func sendSyncNotification(machineCount: Int)
    func sendCVENotification(alerts: [CVEAlert])
}

struct NotificationSender: Notifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func sendOutdatedNotification(count: Int) {
        notifLogger.info("Sending notification for \(count) outdated packages")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Homebrew Updates")
        content.body = String(format: String(localized: "%lld packages can be updated."), Int64(count))
        content.sound = .default
        // Without a category the banner is a dead end: the user has to find the
        // menu bar icon, open the popover and click again to do the one thing
        // the notification is about.
        content.categoryIdentifier = NotificationAction.outdatedCategory
        post(content, idPrefix: "brewtui-bar-outdated")
    }

    func sendSyncNotification(machineCount: Int) {
        notifLogger.info("Sending sync notification (\(machineCount) machines)")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sync activity detected")
        content.body = String(
            format: String(localized: "%lld machine(s) updated their packages."),
            Int64(machineCount)
        )
        content.sound = .default
        content.categoryIdentifier = NotificationAction.syncCategory
        post(content, idPrefix: "brewtui-bar-sync")
    }

    func sendCVENotification(alerts: [CVEAlert]) {
        guard !alerts.isEmpty else { return }
        let sorted = alerts.sorted { $0.severity.sortOrder < $1.severity.sortOrder }
        let hasCriticalOrHigh = sorted.first.map { $0.severity == .critical || $0.severity == .high } ?? false
        let count = alerts.count
        notifLogger.info("Sending CVE notification for \(count) new vulnerabilities")

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = NotificationAction.cveCategory
        if hasCriticalOrHigh, let worst = sorted.first {
            content.title = String(localized: "Security Alert — BrewTUI-Bar")
            content.body = String(
                format: String(localized: "%lld vulnerable packages found, including %@"),
                Int64(count),
                worst.packageName
            )
            content.userInfo = ["cveId": worst.id]
        } else {
            content.title = String(localized: "Security Notice — BrewTUI-Bar")
            content.body = String(format: String(localized: "%lld vulnerable packages found"), Int64(count))
            if let worst = sorted.first {
                content.userInfo = ["cveId": worst.id]
            }
        }
        post(content, idPrefix: "brewtui-bar-cve")
    }

    private func post(_ content: UNMutableNotificationContent, idPrefix: String) {
        let request = UNNotificationRequest(
            identifier: "\(idPrefix)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
