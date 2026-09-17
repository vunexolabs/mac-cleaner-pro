import Foundation

/// What the app needs from macOS, why, and what stops working without it.
///
/// Deliberately one place rather than a prompt per feature. macOS offers no API
/// to request Full Disk Access and no way to grant several permissions at once,
/// so the only honest design is to explain everything once, show live status,
/// and link straight to the right pane — never to ask repeatedly.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case fullDiskAccess
    case automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .automation:     return "Controlling other apps"
        }
    }

    /// Why we need it, in the user's terms.
    public var rationale: String {
        switch self {
        case .fullDiskAccess:
            return "Lets Mac Cleaner Pro see the caches and leftovers that live in protected "
                 + "parts of your Library — browser data, Mail downloads, and files left behind "
                 + "by apps you've deleted."
        case .automation:
            return "Lets Quit Selected ask an app to quit the polite way, so anything unsaved "
                 + "prompts you to save first instead of being killed outright."
        }
    }

    /// What is measurably worse without it — shown verbatim in the UI, so it
    /// has to be specific rather than reassuring.
    public var costOfDenial: String {
        switch self {
        case .fullDiskAccess:
            return "Scans miss most of what's reclaimable, and the sizes shown will be lower "
                 + "than what a clean would actually free."
        case .automation:
            return "Quitting an app can't offer it the chance to save, so unsaved work in that "
                 + "app would be lost."
        }
    }

    /// True when macOS grants this only through System Settings, with no API to
    /// ask for it — which is why we link out instead of prompting.
    public var requiresSystemSettings: Bool {
        switch self {
        case .fullDiskAccess: return true
        case .automation:     return false
        }
    }

    /// Whether a running process picks up a change, or must be relaunched.
    /// FDA is applied at process start, so granting it mid-session does nothing
    /// until the app restarts — the single most common "it didn't work" report.
    public var needsRelaunchAfterGranting: Bool {
        switch self {
        case .fullDiskAccess: return true
        case .automation:     return false
        }
    }

    /// Features degraded while this is missing, named as the user sees them.
    public var gatedFeatures: [String] {
        switch self {
        case .fullDiskAccess:
            return ["Smart Scan", "App Uninstaller", "Space Lens", "Large & Old Files"]
        case .automation:
            return ["Memory · Quit Selected"]
        }
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// macOS asks the first time the feature is used and won't tell us in
    /// advance — claiming to know would be a guess dressed as a fact.
    case decidedOnFirstUse
}

public enum PermissionsCenter {

    public static func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            return FullDiskAccess.isGranted() ? .granted : .denied
        case .automation:
            return .decidedOnFirstUse
        }
    }

    /// Everything the user can act on right now, worst first, so the UI leads
    /// with what actually needs doing.
    public static func outstanding() -> [Permission] {
        Permission.allCases.filter { status(of: $0) == .denied }
    }

    /// True when every permission we can detect is in place.
    public static var allClear: Bool { outstanding().isEmpty }
}
