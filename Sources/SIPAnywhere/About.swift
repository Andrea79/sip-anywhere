import AppKit

/// The About window: the standard panel with the credits (Resources/Credits.rtf) and,
/// when the build names one (PROJECT_URL in build_app.sh), a link to the source code.
@MainActor
enum About {
    /// The project's page, e.g. on GitHub; empty until the build sets it.
    static var projectURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SSPProjectURL") as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = projectURL,
           let rtf = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
           let credits = try? NSMutableAttributedString(url: rtf, options: [:], documentAttributes: nil) {
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let shown = (url.host ?? "") + url.path
            credits.append(NSAttributedString(string: "\n\nSource code: ", attributes: [
                .font: font, .paragraphStyle: centered, .foregroundColor: NSColor.labelColor]))
            credits.append(NSAttributedString(string: shown, attributes: [
                .font: font, .paragraphStyle: centered, .link: url]))
            options[.credits] = credits
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
