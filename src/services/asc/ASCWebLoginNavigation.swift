// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// A late navigation event or deadline must never complete a newer page load.
struct ASCWebLoginNavigation {
    private(set) var token: UUID?
    private(set) var isLoading = false
    private(set) var canValidate = false
    private(set) var isActive = true

    mutating func start() -> UUID? {
        guard isActive else { return nil }
        let token = UUID()
        self.token = token
        isLoading = true
        canValidate = false
        return token
    }

    @discardableResult mutating func finish(_ token: UUID) -> Bool {
        guard isActive, self.token == token, isLoading else { return false }
        isLoading = false
        canValidate = true
        return true
    }

    @discardableResult mutating func fail(_ token: UUID) -> Bool {
        guard isActive, self.token == token else { return false }
        self.token = nil
        isLoading = false
        canValidate = false
        return true
    }

    mutating func cancel() {
        isActive = false
        token = nil
        isLoading = false
        canValidate = false
    }
}

/// Ordinary reloads retain Apple's device-trust cookies. Only an explicit
/// account switch selects a fresh, app-scoped store; Safari/CLI are unrelated.
enum ASCWebLoginStoreIdentity {
    static let preferenceKey = "ASCWebLoginStoreIdentifier"
    static let original = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

    static func current(in defaults: UserDefaults = .standard) -> UUID {
        defaults.string(forKey: preferenceKey).flatMap(UUID.init(uuidString:)) ?? original
    }

    @discardableResult static func rotate(in defaults: UserDefaults = .standard) -> UUID {
        let previous = current(in: defaults)
        defaults.set(UUID().uuidString, forKey: preferenceKey)
        return previous
    }
}
