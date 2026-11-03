import Foundation

public enum SafeHTML {
    public static let contentRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    public static func document(text: String, html: String, dark: Bool = false) -> String {
        let plain = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let content = html.isEmpty ? "<div class=\"plain\">\(plain)</div>" : html
        return """
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:\(dark ? "dark" : "light")}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.65;margin:22px;color:\(dark ? "oklch(0.94 0 0)" : "oklch(0.20 0 0)");background:\(dark ? "oklch(0.23 0 0)" : "oklch(1 0 0)");overflow-wrap:anywhere}.plain{white-space:pre-wrap;max-width:72ch}img{max-width:100%;height:auto}table{max-width:100%}a{color:\(dark ? "oklch(0.80 0.09 245)" : "oklch(0.43 0.10 245)")}</style></head><body>\(content)</body></html>
        """
    }
    public static func externalLinkAllowed(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
    }
}
