// RevealInFinderAction.swift
// OpenClip
//
// Implements Finder file reveal actions for file paths found in selected text using NSWorkspace.
import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Core

public struct RevealInFinderAction: Action {
    public let id = "builtin.reveal_in_finder"
    public var title: String { String(localized: "Reveal in Finder") }
    public let icon = ActionIcon.symbol("folder")
    
    public init() {}
    
    @MainActor
    public func isEnabled(for context: ActionContext) -> Bool {
        // Visibility only — never stat inside a TCC-protected folder here. See `isExistingPath`.
        return resolvePath(from: context.selection.text, probingProtectedDirectories: false) != nil
    }
    
    @MainActor
    public func perform(_ context: ActionContext) async throws -> ActionResult {
        guard let path = resolvePath(from: context.selection.text) else {
            return .failure(NSError(
                domain: Constants.actionErrorDomain,
                code: Constants.actionErrorCode,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "No existing file path found in selection.")]
            ))
        }
        
        #if canImport(AppKit)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        return .success
        #else
        return .failure(NSError(domain: Constants.actionErrorDomain, code: Constants.actionErrorCode, userInfo: nil))
        #endif
    }
    
    /// - Parameter probingProtectedDirectories: whether a candidate inside Desktop, Documents or
    ///   Downloads may be stat-ed. False for the visibility check that runs on every selection,
    ///   true when the user actually invoked the action. See `isExistingPath`.
    public func resolvePath(from text: String, probingProtectedDirectories: Bool = true) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // Fast path 1: Check entire selection directly
        if let directPath = checkSinglePath(trimmed, probingProtectedDirectories: probingProtectedDirectories) {
            return directPath
        }
        
        // Fast path 2: Instant bailout if no path indicators exist (0 filesystem stat calls)
        guard trimmed.contains("/") || trimmed.contains("~") else { return nil }
        
        // Fallback: Scan token candidates (capped at 5 to prevent UI stalls on massive text)
        let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var checksPerformed = 0
        let maxCandidateChecks = 5
        
        for token in tokens {
            guard checksPerformed < maxCandidateChecks else { break }
            
            let cleaned = stripDelimiters(token)
            guard cleaned.hasPrefix("/") || cleaned.hasPrefix("~") || cleaned.hasPrefix("file://") else {
                continue
            }
            
            checksPerformed += 1
            if let resolved = checkSinglePath(cleaned, probingProtectedDirectories: probingProtectedDirectories) {
                return resolved
            }
        }
        
        return nil
    }
    
    private func checkSinglePath(_ rawPath: String, probingProtectedDirectories: Bool) -> String? {
        var path = stripDelimiters(rawPath)
        guard !path.isEmpty else { return nil }
        
        // Handle file:// URIs
        if path.hasPrefix("file://") {
            if let url = URL(string: path) {
                path = url.path
            } else {
                path = String(path.dropFirst(7))
            }
        }
        
        // Unescape shell spaces: "\ " -> " "
        let unescaped = path.replacingOccurrences(of: "\\ ", with: " ")
        
        // Step A: Direct expansion (fastest, exact match)
        let expanded = (unescaped as NSString).expandingTildeInPath
        if isExistingPath(expanded, probingProtectedDirectories: probingProtectedDirectories) {
            return expanded
        }
        
        // Step B: Strip trailing line/column (:80:15) and sentence punctuation (. , ;)
        let stripped = stripLineNumbersAndPunctuation(expanded)
        let cleaned = stripDelimiters(stripped)
        let cleanedExpanded = (cleaned as NSString).expandingTildeInPath
        if isExistingPath(cleanedExpanded, probingProtectedDirectories: probingProtectedDirectories) {
            return cleanedExpanded
        }
        
        return nil
    }
    
    /// macOS gates Desktop, Documents and Downloads behind a TCC consent prompt, and it fires on a
    /// plain `fileExists` — attributed to OpenClip, not to whatever spawned the check. `isEnabled`
    /// runs on **every selection**, so stat-ing there makes an unexplained
    /// "OpenClip would like to access files in your Desktop folder" dialog appear the moment a
    /// selection happens to contain such a path. A passive visibility check must never cause that.
    ///
    /// So the visibility pass takes a path-shaped candidate under those three folders on trust —
    /// the action shows, nothing is touched — and `perform` does the real stat, where the prompt is
    /// user-initiated and obviously connected to clicking "Reveal in Finder". A candidate that
    /// turns out not to exist falls through to the action's existing "No existing file path found"
    /// failure.
    private func isExistingPath(_ path: String, probingProtectedDirectories: Bool) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if !probingProtectedDirectories && Self.isInProtectedDirectory(path) { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The three home subfolders macOS puts behind a consent prompt.
    private static let protectedDirectories = ["Desktop", "Documents", "Downloads"]

    static func isInProtectedDirectory(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        protectedDirectories.contains { path.hasPrefix(home + "/" + $0 + "/") }
    }
    
    private func stripDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [(String, String)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"),
            ("<", ">"), ("(", ")"), ("[", "]")
        ]
        for (lead, trail) in wrappers {
            if s.hasPrefix(lead) && s.hasSuffix(trail) && s.count >= (lead.count + trail.count) {
                s = String(s.dropFirst(lead.count).dropLast(trail.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let leadingWrappers = CharacterSet(charactersIn: "\"‘“'<([")
        while let first = s.unicodeScalars.first, leadingWrappers.contains(first) {
            s.removeFirst()
        }
        let trailingWrappers = CharacterSet(charactersIn: "\"'”’)>]")
        while let last = s.unicodeScalars.last, trailingWrappers.contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func stripLineNumbersAndPunctuation(_ raw: String) -> String {
        var s = raw
        // 1. Strip trailing sentence punctuation
        let trailingChars = CharacterSet(charactersIn: ".,;:!?\"'”’)]>")
        while let last = s.unicodeScalars.last, trailingChars.contains(last) {
            s.removeLast()
        }
        
        // 2. Strip compiler location suffix: :line:col or :line (e.g. :80:15 or :80)
        if let lastColon = s.lastIndex(of: ":") {
            let suffix = String(s[lastColon...])
            if suffix.count > 1 && suffix.dropFirst().allSatisfy({ $0.isNumber }) {
                s = String(s[..<lastColon])
                if let secondColon = s.lastIndex(of: ":") {
                    let secondSuffix = String(s[secondColon...])
                    if secondSuffix.count > 1 && secondSuffix.dropFirst().allSatisfy({ $0.isNumber }) {
                        s = String(s[..<secondColon])
                    }
                }
            }
        }
        return s
    }
}
