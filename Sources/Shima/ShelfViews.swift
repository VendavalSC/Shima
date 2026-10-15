import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Shelf section

/// The shelf page: files in a grid that scrolls vertically (horizontal swipes belong to paging),
/// and a bottom row with the count on the leading side and Clear on the trailing side.
struct ShelfSection: View {
    let model: IslandModel
    let shelf: ShelfStore

    private var width: CGFloat { Metrics.openWidth - 2 * Metrics.padding }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Metrics.shelfTileWidth), spacing: Metrics.shelfSpacing), count: 5)
    }

    var body: some View {
        let row = Metrics.controlsCenterY
        ZStack(alignment: .topLeading) {
            if shelf.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24, weight: .light))
                    Text("Drag files to the notch to keep them here")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: width, height: Metrics.shelfGridHeight)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, thumbnail: shelf.thumbnails[item.id], shelf: shelf)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
                .frame(width: width, height: Metrics.shelfGridHeight)
            }

            Text(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .contentTransition(.numericText())
                .opacity(shelf.isEmpty ? 0 : 1)
                .frame(width: width, alignment: .leading)
                .position(x: width / 2, y: row)

            NotchButton(model: model, symbol: "xmark.circle", center: CGPoint(x: width - Metrics.edgeButtonInset, y: row),
                        enabled: !shelf.isEmpty) {
                withAnimation(Motion.compact) { shelf.clear() }
            }
            .help("Clear Shelf")
        }
        .frame(width: width, height: Metrics.sectionHeight, alignment: .topLeading)
    }
}

/// A file on the shelf, Finder-style: thumbnail and name. Drag it out to use it anywhere,
/// double-click to open it, right-click for more.
private struct ShelfTile: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let shelf: ShelfStore

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: Metrics.shelfThumb, height: Metrics.shelfThumb)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: Metrics.shelfTileWidth, height: Metrics.shelfTileHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy") { FileActions.copy([item.url]) }
            Button("AirDrop…") { FileActions.airDrop([item.url]) }
            Divider()
            Button("Remove from Shelf") { withAnimation(Motion.compact) { shelf.remove(item) } }
        }
    }
}

// MARK: Drop targets

/// Shown while files are dragged to the notch: keep them on the shelf, or AirDrop them.
struct DropTargets: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: Metrics.dropTileSpacing) {
            DropTile(title: "Keep on Shelf", active: model.dropTarget == .shelf) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 24, weight: .medium))
            }
            .onDrop(of: [.fileURL], isTargeted: targeting(.shelf)) { receive($0, on: .shelf) }

            if AppSettings.shared.airDropTarget {
                DropTile(title: "AirDrop", active: model.dropTarget == .airDrop) {
                    Image(nsImage: FileActions.airDropIcon).resizable().frame(width: 30, height: 30)
                }
                .onDrop(of: [.fileURL], isTargeted: targeting(.airDrop)) { receive($0, on: .airDrop) }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, model.geometry.contentTop)
        .padding(.bottom, Metrics.padding)
    }

    private func targeting(_ target: DropTarget) -> Binding<Bool> {
        Binding(
            get: { model.dropTarget == target },
            set: { isOver in
                Log.drag.notice("drag over \(String(describing: target), privacy: .public): \(isOver)")
                if isOver {
                    model.dropTarget = target
                } else if model.dropTarget == target {
                    model.dropTarget = nil
                }
            })
    }

    private func receive(_ providers: [NSItemProvider], on target: DropTarget) -> Bool {
        Log.drag.notice("dropped on \(String(describing: target), privacy: .public): \(providers.count) item(s)")
        FileActions.fileURLs(from: providers) { urls in
            Log.drag.notice("drop carried \(urls.count) file(s)")
            guard !urls.isEmpty else { return }
            model.onDropFiles?(urls, target)
        }
        return true
    }
}

private struct DropTile<Icon: View>: View {
    let title: String
    let active: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        VStack(spacing: 8) {
            icon
                .foregroundStyle(.white.opacity(active ? 1 : 0.8))
                .scaleEffect(active ? 1.1 : 1)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.white.opacity(active ? 0.16 : 0.06)))
        .overlay(shape.strokeBorder(.white.opacity(active ? 0.22 : 0.08), lineWidth: 1))
        .scaleEffect(active ? 1.03 : 1)
        .animation(.snappy(duration: 0.25), value: active)
        .contentShape(shape)
    }
}

// MARK: File actions

enum FileActions {
    /// The system's own AirDrop glyph, as shown in share menus (there is no SF Symbol for it).
    static let airDropIcon: NSImage = NSSharingService(named: .sendViaAirDrop)?.image
        ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "AirDrop")
        ?? NSImage()

    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        NSApp.activate()   // the AirDrop sheet needs us frontmost to take focus
        service.perform(withItems: urls)
    }

    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// File URLs carried by a drop; calls back on the main thread.
    static func fileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}
