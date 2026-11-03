import Foundation

/// A folder the user picked, remembered across launches as a security-scoped
/// bookmark in UserDefaults.
struct BookmarkedFolder {
    let defaults: UserDefaults
    let key: String

    var url: URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: key)
        }
        return url
    }

    func set(_ url: URL?) throws {
        guard let url else {
            defaults.removeObject(forKey: key)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key)
    }

    /// Runs `body` with access to the folder, or nil when none is set.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T? {
        guard let url else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
