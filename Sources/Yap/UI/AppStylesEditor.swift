import AppKit
import SwiftUI

/// Clean-up styles for particular apps: "Terminal → Verbatim", "Mail → Formal". Apps not listed use the main style.
struct AppStylesEditor: View {
    @ObservedObject var history: HistoryStore
    @Local private var styles: [String: String] = Prefs.appStyles

    /// Apps you've dictated into, then other open apps, without the ones already set.
    private var candidates: [String] {
        var seen = Set(styles.keys), out: [String] = []
        let recent = history.entries.compactMap(\.app)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        for name in recent + running.sorted() where !seen.contains(name) && name != "Yap" { seen.insert(name); out.append(name) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(styles.keys.sorted(), id: \.self) { app in
                HStack(spacing: 8) {
                    Text(app).frame(minWidth: 110, alignment: .leading)
                    Picker(app, selection: Binding(get: { styles[app] ?? CleanupStyle.polished.rawValue }, set: { set(app, $0) })) {
                        ForEach(CleanupStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                    Button { set(app, nil) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Use the main style in \(app)")
                }
            }
            Menu("Add an App") {
                ForEach(candidates.prefix(25), id: \.self) { app in Button(app) { set(app, Self.suggested(for: app).rawValue) } }
            }
            .fixedSize()
            .disabled(candidates.isEmpty)
        }
    }

    private func set(_ app: String, _ style: String?) {
        var s = Prefs.appStyles
        s[app] = style
        Prefs.appStyles = s
        styles = s
    }

    /// A sensible first pick, changed with the menu next to it.
    static func suggested(for app: String) -> CleanupStyle {
        let a = app.lowercased()
        if ["terminal", "iterm", "warp", "ghostty", "xcode", "code", "cursor", "zed"].contains(where: { a.contains($0) }) { return .verbatim }
        if ["mail", "outlook", "spark", "superhuman", "word", "pages"].contains(where: { a.contains($0) }) { return .formal }
        if ["messages", "slack", "whatsapp", "discord", "telegram", "signal"].contains(where: { a.contains($0) }) { return .casual }
        return .polished
    }
}
