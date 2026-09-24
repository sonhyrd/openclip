// ActionBindingStore.swift
// OpenClip
//
// Persists per-action search aliases (exact-match jump keys for the palette). Hotkeys live in
// KeyboardShortcuts in the App target; this store is Core-pure and keyed by canonical action id.
import Foundation
import Combine

public enum AliasSetResult: Equatable, Sendable {
    case accepted
    case cleared
    case invalid
    case collision(existingActionID: String)
}

@MainActor
public final class ActionBindingStore: ObservableObject, Sendable {
    public static let shared = ActionBindingStore()

    @Published public private(set) var aliases: [String: String] = [:]
    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore = DefaultSettingsStore.shared) {
        self.settingsStore = settingsStore
        aliases = settingsStore.get(.actionAliases)
    }

    public func alias(for actionID: String) -> String? {
        let value = aliases[actionID]
        return (value?.isEmpty == false) ? value : nil
    }

    public func actionID(forAlias raw: String) -> String? {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        return aliases.first { $0.value == normalized }?.key
    }

    @discardableResult
    public func setAlias(_ raw: String?, for actionID: String) -> AliasSetResult {
        let normalized = Self.normalize(raw ?? "")
        if normalized.isEmpty {
            if aliases[actionID] == nil { return .cleared }
            aliases.removeValue(forKey: actionID)
            persist()
            return .cleared
        }
        guard Self.isValid(normalized) else { return .invalid }
        if let existing = aliases.first(where: { $0.value == normalized && $0.key != actionID }) {
            return .collision(existingActionID: existing.key)
        }
        aliases[actionID] = normalized
        persist()
        return .accepted
    }

    public func reset() {
        aliases = [:]
        persist()
    }

    private func persist() {
        settingsStore.set(.actionAliases, value: aliases)
    }

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isValid(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        return normalized.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }
}
