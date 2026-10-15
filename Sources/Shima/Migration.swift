import Foundation

/// Shima was called Isle while it was being made, with its own settings and shelf. Brought over
/// once, before anything reads them; Isle's copies are left as they were.
enum Migration {
    private static let oldDomain = "local.isle"
    private static let doneKey = "migratedFromIsle"

    static func fromIsle() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("debug") {
                defaults.set(value, forKey: key)
            }
        }
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldFolder = support.appendingPathComponent("Isle"), newFolder = support.appendingPathComponent("Shima")
        if fileManager.fileExists(atPath: oldFolder.path), !fileManager.fileExists(atPath: newFolder.path) {
            try? fileManager.copyItem(at: oldFolder, to: newFolder)
        }
    }
}
