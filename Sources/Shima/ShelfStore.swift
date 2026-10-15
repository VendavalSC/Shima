import AppKit
import Observation
import QuickLookThumbnailing

struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL

    var name: String { url.lastPathComponent }
}

/// Files kept on the shelf. Holds references to the files where they are (nothing is copied), saved
/// across launches; items whose files have since been deleted or moved drop off when loaded.
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    /// Quick Look thumbnails, filled in as they're generated.
    private(set) var thumbnails: [UUID: NSImage] = [:]

    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        storeURL = support?.appendingPathComponent("Shima", isDirectory: true).appendingPathComponent("shelf.json")
        if persists { load() }
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        let fresh = urls.map(\.standardizedFileURL).filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        let added = fresh.map { ShelfItem(id: UUID(), url: $0) }
        items.append(contentsOf: added)
        added.forEach(makeThumbnail)
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    // MARK: Thumbnails

    private func makeThumbnail(for item: ShelfItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.url.path)   // until Quick Look answers
        let side = Metrics.shelfThumb
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        items.forEach(makeThumbnail)
        if items.count != saved.count { save() }
    }

    private func save() {
        guard persists, let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
    }
}
