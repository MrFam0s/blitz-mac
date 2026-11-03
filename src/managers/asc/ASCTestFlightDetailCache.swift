import Foundation
import Observation

/// Session-only relation data: tester identities must never enter a disk snapshot.
@MainActor @Observable
final class ASCTestFlightDetailCache<Value> {
    private(set) var values: [String: Value] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var operations: [String: UUID] = [:]
    @ObservationIgnored private var scopes: [String: @MainActor () -> Bool] = [:]
    @ObservationIgnored private var valueScopes: [String: @MainActor () -> Bool] = [:]
    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private var touchedAt: [String: Date] = [:]
    private let capacity: Int

    nonisolated init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        operations.removeAll()
        scopes.removeAll()
        valueScopes.removeAll()
        loading.removeAll()
        values.removeAll()
        errors.removeAll()
        loadedAt.removeAll()
        touchedAt.removeAll()
    }

    func retain(ids: Set<String>) {
        let known = Set(touchedAt.keys).union(tasks.keys)
        for id in known.subtracting(ids) { remove(id) }
    }

    @discardableResult
    func refresh(
        id: String,
        force: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        load: @escaping @MainActor () async throws -> Value
    ) async -> Bool {
        guard !id.isEmpty, isCurrent(), !Task.isCancelled else { return false }
        if values[id] != nil, valueScopes[id]?() != true {
            values.removeValue(forKey: id)
            errors.removeValue(forKey: id)
            loadedAt.removeValue(forKey: id)
            valueScopes.removeValue(forKey: id)
        }
        touchedAt[id] = Date()
        if let task = tasks[id] {
            if scopes[id]?() == true { return await task.value }
            // A new target must not join an older, cancelled scope's request.
            task.cancel()
            tasks.removeValue(forKey: id)
            operations.removeValue(forKey: id)
        }
        if !force, values[id] != nil, errors[id] == nil, let date = loadedAt[id],
           Date().timeIntervalSince(date) < 120 { return true }
        let operation = UUID()
        operations[id] = operation
        scopes[id] = isCurrent
        loading.insert(id)
        let task = Task { [self] in
            defer {
                if operations[id] == operation {
                    loading.remove(id)
                    tasks.removeValue(forKey: id)
                    operations.removeValue(forKey: id)
                    scopes.removeValue(forKey: id)
                    trim(keeping: id)
                }
            }
            do {
                let value = try await load()
                guard operations[id] == operation, isCurrent(), !Task.isCancelled else { return false }
                values[id] = value
                valueScopes[id] = isCurrent
                errors.removeValue(forKey: id)
                loadedAt[id] = Date()
                return true
            } catch {
                guard operations[id] == operation, isCurrent(), !Task.isCancelled else { return false }
                // A failed refresh keeps the last confirmed relation list visible.
                errors[id] = error.localizedDescription
                return false
            }
        }
        tasks[id] = task
        return await task.value
    }

    private func trim(keeping id: String) {
        let removable = touchedAt.keys.filter { $0 != id && !loading.contains($0) }
            .sorted { touchedAt[$0, default: .distantPast] < touchedAt[$1, default: .distantPast] }
        let excess = max(0, touchedAt.count - capacity)
        for key in removable.prefix(excess) {
            remove(key)
        }
    }

    private func remove(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        operations.removeValue(forKey: id)
        scopes.removeValue(forKey: id)
        valueScopes.removeValue(forKey: id)
        loading.remove(id)
        values.removeValue(forKey: id)
        errors.removeValue(forKey: id)
        loadedAt.removeValue(forKey: id)
        touchedAt.removeValue(forKey: id)
    }
}
