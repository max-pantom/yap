import AppKit
import ApplicationServices

/// Watches the text field for a little while after a paste. If you fix a word Yap got wrong ("Jon" → "John"),
/// it adds `Jon => John` to your dictionary so it's right next time. Reads the field through Accessibility,
/// on-device, and never stores or logs what you typed.
@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// Called with each new `(heard, written)` pair.
    var onLearn: (([(String, String)]) -> Void)?
    private var task: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.learnCorrections) }

    /// Starts watching the focused field for edits to `pasted`. Any previous watch is wrapped up first.
    func watch(pasted: String) {
        task?.cancel()
        guard Self.isEnabled, pasted.count >= 3, AXIsProcessTrusted() else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450)) // let the paste land
            guard let element = Self.focusedElement(), !Self.isSecure(element),
                  let base = Self.value(of: element), base.count < 200_000,
                  let range = base.range(of: pasted, options: .backwards) else { return }
            let prefix = String(base[..<range.lowerBound]), suffix = String(base[range.upperBound...])
            var latest = base
            let deadline = Date().addingTimeInterval(45)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let now = Self.focusedElement(), CFEqual(now, element), let v = Self.value(of: element) else { break }
                latest = v
            }
            // Wrap up even when cancelled by the next dictation: those edits were made before it started.
            guard latest != base, latest.hasPrefix(prefix), latest.hasSuffix(suffix),
                  latest.count >= prefix.count + suffix.count else { return }
            let edited = String(latest.dropFirst(prefix.count).dropLast(suffix.count))
            let pairs = Self.corrections(original: pasted, edited: edited)
            guard !pairs.isEmpty else { return }
            self?.learn(pairs)
        }
    }

    private func learn(_ pairs: [(String, String)]) {
        let d = UserDefaults.standard
        var lines = (d.string(forKey: Prefs.Key.dictionary) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        let known = Set(Prefs.dictionary.replacements.map { $0.0.lowercased() })
        let fresh = pairs.filter { !known.contains($0.0.lowercased()) }
        guard !fresh.isEmpty else { return }
        lines += fresh.map { "\($0.0) => \($0.1)" }
        d.set(lines.joined(separator: "\n"), forKey: Prefs.Key.dictionary)
        Log.write("learned \(fresh.count) correction(s)")
        onLearn?(fresh)
    }

    // MARK: Diffing

    /// Word-level substitutions between what Yap pasted and what's in the field now. Only small, similar-looking
    /// swaps count; a rewritten sentence or text typed after the dictation isn't a correction.
    nonisolated static func corrections(original: String, edited: String) -> [(String, String)] {
        let a = words(original), b = words(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // Longest common subsequence on exact words.
        let n = a.count, m = b.count
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = a[i] == b[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var blocks: [(del: [String], ins: [String], at: Int)] = []
        var i = 0, j = 0, del: [String] = [], ins: [String] = [], start = 0
        func flush() { if !del.isEmpty || !ins.isEmpty { blocks.append((del, ins, start)) }; del = []; ins = [] }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { flush(); i += 1; j += 1; continue }
            if del.isEmpty && ins.isEmpty { start = i }
            if j < m, i == n || L[i][j + 1] >= L[i + 1][j] { ins.append(b[j]); j += 1 } else { del.append(a[i]); i += 1 }
        }
        flush()
        // Lots of changes means a rewrite, not a fix.
        let changed = blocks.filter { !$0.del.isEmpty }
        guard changed.count <= 3, Double(changed.reduce(0) { $0 + $1.del.count }) <= max(1, Double(n) * 0.4) else { return [] }
        var out: [(String, String)] = []
        for blk in changed where (1...3).contains(blk.del.count) && (1...3).contains(blk.ins.count) {
            let heard = blk.del.joined(separator: " "), written = blk.ins.joined(separator: " ")
            guard written.count >= 2, heard != written else { continue }
            if heard.lowercased() == written.lowercased() {
                // Case-only fixes: keep "chatgpt → ChatGPT", skip plain sentence-start capitalisation.
                let innerCaps = written.dropFirst().contains { $0.isUppercase }
                guard innerCaps || blk.at > 0 else { continue }
            } else if similarity(heard.lowercased(), written.lowercased()) < 0.45 {
                continue // a different word, not a misspelling
            }
            out.append((heard, written))
        }
        return out
    }

    nonisolated private static func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-.@_")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'’")) }
            .filter { !$0.isEmpty }
    }

    /// 1 = identical, 0 = nothing in common (normalised Levenshtein).
    nonisolated static func similarity(_ x: String, _ y: String) -> Double {
        let a = Array(x), b = Array(y)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }

    // MARK: Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func isSecure(_ e: AXUIElement) -> Bool {
        var role: CFTypeRef?, sub: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sub)
        return (sub as? String) == (kAXSecureTextFieldSubrole as String) || (role as? String) == "AXSecureTextField"
    }

    private static func value(of e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
