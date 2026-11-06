import AppKit

/// Spoken updates for VoiceOver. The search field keeps keyboard focus while arrows move
/// through results, so without these VoiceOver users hear nothing as the list changes.
@MainActor
enum Announcer {
    static func say(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
