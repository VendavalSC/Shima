import AppKit
import Observation

/// Updates from GitHub Releases: a look once a day (and on request) at the latest release, and, if
/// it's newer, its DMG downloaded, the app inside put in place of this one, and Shima reopened.
@Observable
final class Updater {
    static let shared = Updater()
    private static let latest = URL(string: "https://api.github.com/repos/VendavalSC/Shima/releases/latest")!

    enum State: Equatable { case idle, checking, upToDate, available(String), installing, failed(String) }
    private(set) var state: State = .idle
    @ObservationIgnored private var download: URL?
    @ObservationIgnored private var timer: Timer?

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private init() {}

    /// Checks now, and then once a day (coalesced with other wake-ups).
    func start() {
        check(quietly: true)
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(quietly: true) }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(quietly: Bool = false) {
        guard state != .checking, state != .installing else { return }
        state = .checking
        URLSession.shared.dataTask(with: Self.latest) { [weak self] data, _, error in
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (release?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) ?? ""
            let assets = release?["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
            DispatchQueue.main.async {
                guard let self else { return }
                if tag.isEmpty {
                    self.state = quietly ? .idle : .failed(error?.localizedDescription ?? "Couldn't reach GitHub.")
                } else if Self.isNewer(tag, than: Self.currentVersion), let dmg, let url = URL(string: dmg) {
                    self.download = url
                    self.state = .available(tag)
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Downloads the DMG, replaces this app with the one inside, and reopens.
    func install() {
        guard let download, state != .installing else { return }
        state = .installing
        URLSession.shared.downloadTask(with: download) { [weak self] file, _, error in
            guard let file else {
                DispatchQueue.main.async { self?.state = .failed(error?.localizedDescription ?? "The download failed.") }
                return
            }
            let result = Self.replaceApp(fromDMG: file)
            DispatchQueue.main.async {
                if let message = result { self?.state = .failed(message); return }
                // Reopen the new copy once this one has quit.
                let path = Bundle.main.bundlePath
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 1; open \"\(path)\""]
                try? relaunch.run()
                NSApp.terminate(nil)
            }
        }.resume()
    }

    /// Mounts the DMG, copies Shima.app over this one, unmounts. Returns an error message, or nil.
    private static func replaceApp(fromDMG dmg: URL) -> String? {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ShimaUpdate-\(UUID().uuidString)")
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]) else {
            return "Couldn't open the update."
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        let newApp = mount.appendingPathComponent("Shima.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { return "The update didn't contain Shima." }
        let target = Bundle.main.bundleURL
        let staging = target.deletingLastPathComponent().appendingPathComponent(".Shima-update.app")
        try? FileManager.default.removeItem(at: staging)
        guard run("/usr/bin/ditto", [newApp.path, staging.path]) else { return "Couldn't copy the update." }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return "Couldn't replace Shima: \(error.localizedDescription)"
        }
        return nil
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
