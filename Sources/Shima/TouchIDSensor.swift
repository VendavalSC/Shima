import Foundation

/// What the Touch ID sensor is doing, read from the messages macOS's biometric services log as they
/// happen: a finger touching it, a read that didn't work, and a match. There's no API for this, so it
/// streams just those few messages, and only while something wants them (a Touch ID prompt is up, or
/// the Mac is locked). If the messages ever change, it simply reports nothing.
final class TouchIDSensor {
    enum Event: Equatable {
        /// Ready for a finger.
        case armed
        case fingerDown
        /// The finger couldn't be read or wasn't recognized; the sensor tries again.
        case tryAgain
        case matched
        case cancelled
    }

    static let shared = TouchIDSensor()

    private var listeners: [UUID: (Event) -> Void] = [:]
    private var process: Process?
    private var buffer = Data()

    /// Calls `handle` with each event until the returned token is passed to `stop`.
    func start(_ handle: @escaping (Event) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handle
        if process == nil { launch() }
        return token
    }

    func stop(_ token: UUID?) {
        guard let token else { return }
        listeners[token] = nil
        guard listeners.isEmpty, let process else { return }
        process.terminate()
        self.process = nil
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "ndjson", "--predicate",
                          #"(process == "biometrickitd" AND eventMessage CONTAINS "matchResult:timestamp") OR "#
                          + #"(process == "coreauthd" AND eventMessage BEGINSWITH "BKMatchTouchIDOperation::statusMessage:client:" "#
                          + #"AND NOT eventMessage CONTAINS "->")"#]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(data) }
        }
        // Should the stream end on its own while still wanted, start it again.
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, self.process === ended else { return }
                self.process = nil
                if !self.listeners.isEmpty { self.launch() }
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            Log.activity.error("touch id sensor: couldn't stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String, let event = Self.event(in: message) else { continue }
            Log.activity.debug("touch id sensor: \(String(describing: event), privacy: .public)")
            listeners.values.forEach { $0(event) }
        }
    }

    /// "matchResult:timestamp: MATCH …", or "statusMessage:client: <status>, <client>".
    private static func event(in message: String) -> Event? {
        if message.contains("matchResult:timestamp") {
            return message.contains(": MATCH") ? .matched : .tryAgain
        }
        guard let range = message.range(of: "statusMessage:client: ") else { return nil }
        let status = Int(message[range.upperBound...].prefix { $0.isNumber }) ?? -1
        switch status {
        case 90: return .armed
        case 63: return .fingerDown
        case 70: return .tryAgain
        case 80: return .cancelled
        default: return nil
        }
    }
}
