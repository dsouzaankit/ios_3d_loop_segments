import Foundation

/// Last pCloud file used as context for LAN-page export / PC random triggers.
enum LANExportContext {
    private static let hrefKey = "lan_export_reference_href"
    private static let nameKey = "lan_export_reference_name"

    static func saveReference(_ item: WebDAVItem) {
        UserDefaults.standard.set(item.href, forKey: hrefKey)
        UserDefaults.standard.set(item.name, forKey: nameKey)
    }

    static func loadReference() -> WebDAVItem? {
        guard let href = UserDefaults.standard.string(forKey: hrefKey),
              !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = UserDefaults.standard.string(forKey: nameKey),
              !name.isEmpty else {
            return nil
        }
        return WebDAVItem(href: href, name: name, isDirectory: false, contentLength: nil)
    }

    @MainActor
    static func referenceOrActive(from session: AppSession) -> WebDAVItem? {
        if let active = session.activeExportItem { return active }
        return loadReference()
    }
}
