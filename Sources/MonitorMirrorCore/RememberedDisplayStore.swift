import Foundation

public protocol RememberedDisplayStore: AnyObject {
    func load() -> [RememberedDisplay]
    func save(_ displays: [RememberedDisplay])
}

/// Persists the known-display registry so a display that was switched off — and has
/// therefore vanished from the window server — still has a cell to switch back on
/// after the app is relaunched.
public final class UserDefaultsDisplayStore: RememberedDisplayStore {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "remembered-displays.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [RememberedDisplay] {
        guard let data = defaults.data(forKey: key) else { return [] }
        // Corrupt or stale-schema data must not stop the app from launching; an empty
        // registry just means offline displays are forgotten once.
        return (try? JSONDecoder().decode([RememberedDisplay].self, from: data)) ?? []
    }

    public func save(_ displays: [RememberedDisplay]) {
        guard let data = try? JSONEncoder().encode(displays) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Non-persistent store, for tests and for `--no-persist` diagnostics runs.
public final class InMemoryDisplayStore: RememberedDisplayStore {
    private var displays: [RememberedDisplay]
    public init(_ displays: [RememberedDisplay] = []) { self.displays = displays }
    public func load() -> [RememberedDisplay] { displays }
    public func save(_ displays: [RememberedDisplay]) { self.displays = displays }
}
