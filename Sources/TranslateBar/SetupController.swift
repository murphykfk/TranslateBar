import AppKit
import Combine

enum SetupStep: Int, CaseIterable {
    case key, permissions, ready
    var title: String {
        switch self { case .key: return "API Key"; case .permissions: return "文字权限"; case .ready: return "开始使用" }
    }
}

struct SetupReadiness: Equatable {
    var keyLoaded: Bool
    var keyConfigured: Bool
    var accessibilityGranted: Bool
    var keyboardActive: Bool
    var textReady: Bool { accessibilityGranted && keyboardActive }
    var canFinish: Bool { keyLoaded && keyConfigured && textReady }
    var firstStep: SetupStep { !keyConfigured ? .key : !textReady ? .permissions : .ready }
}

@MainActor final class SetupController: ObservableObject {
    private enum Status: String { case pending, deferred, completed }
    private static let storageKey = "setupGuide.status.v1"
    @Published private(set) var isPresented = false
    @Published var step: SetupStep = .key
    private let defaults: UserDefaults
    private var status: Status
    var needsAutomaticPresentation: Bool { status == .pending }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.storageKey), let status = Status(rawValue: stored) { self.status = status }
        else {
            // Existing installations get an entry point, without interrupting their workflow.
            status = defaults.bool(forKey: "hasOpenedTranslateBar") ? .deferred : .pending
            defaults.set(status.rawValue, forKey: Self.storageKey)
        }
    }
    func presentAutomatically(readiness: SetupReadiness) {
        guard needsAutomaticPresentation, readiness.keyLoaded, !isPresented else { return }
        present(readiness: readiness)
    }
    func present(readiness: SetupReadiness) {
        step = readiness.firstStep
        isPresented = true
    }
    func deferSetup() { persist(.deferred); isPresented = false }
    @discardableResult func finish(readiness: SetupReadiness) -> Bool {
        guard readiness.canFinish else { step = readiness.firstStep; return false }
        persist(.completed); isPresented = false
        return true
    }
    private func persist(_ status: Status) {
        self.status = status
        defaults.set(status.rawValue, forKey: Self.storageKey)
    }
}

@MainActor final class RecordingPermissionController: ObservableObject {
    @Published private(set) var granted = false
    @Published var isPresented = false
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }, requestAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight; self.requestAccess = requestAccess
        refresh()
    }
    func refresh() {
        let value = preflight()
        if granted != value { granted = value }
    }
    func prepareStart() -> Bool {
        refresh()
        if !granted { isPresented = true }
        return granted
    }
    // Only called by the explicit permission button, never by launch or polling.
    @discardableResult func request() -> Bool {
        _ = requestAccess()
        refresh()
        return granted
    }
}
