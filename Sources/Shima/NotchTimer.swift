import AppKit
import Observation

/// A countdown timer, like the Clock app's. One wake-up at the end time; the countdown text is
/// drawn by the system (`Text(timerInterval:)`), so a running timer costs nothing per second.
@Observable
final class NotchTimer {
    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    static let minuteRange = 1...180
    /// A finished timer stops ringing in the notch on its own after this long.
    static let finishedTimeout: TimeInterval = 60

    private(set) var state: State = .idle
    /// The length it was started with, for Repeat.
    private(set) var duration: TimeInterval = 0
    /// Where the picker's ruler sits, in minutes. Fractional while it's being dragged or scrolled;
    /// settles on a whole minute, which is remembered for next time.
    var pickerMinutes: Double = Double(UserDefaults.standard.object(forKey: "timerMinutes") as? Int ?? 5)
    var pickedMinutes: Int {
        min(max(Int(pickerMinutes.rounded()), Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    /// Settles the picker on the nearest whole minute and remembers it.
    func settlePicker() {
        pickerMinutes = Double(pickedMinutes)
        UserDefaults.standard.set(pickedMinutes, forKey: "timerMinutes")
    }

    /// Moves the picker by a number of minutes (fractional while dragging), within its range.
    func movePicker(by minutes: Double) {
        let lower = Double(Self.minuteRange.lowerBound), upper = Double(Self.minuteRange.upperBound)
        pickerMinutes = min(max(pickerMinutes + minutes, lower - 0.4), upper + 0.4)
    }

    /// Where the picker was when the current drag on the ruler began.
    @ObservationIgnored var dragOrigin: Double?

    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var dismissTimer: Timer?

    var isActive: Bool { state != .idle }

    func start(minutes: Int) {
        start(seconds: TimeInterval(minutes * 60))
    }

    func start(seconds: TimeInterval) {
        duration = seconds
        run(for: seconds)
    }

    func pause() {
        guard case .running(let end) = state else { return }
        endTimer?.invalidate()
        state = .paused(remaining: max(end.timeIntervalSinceNow, 0))
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        run(for: remaining)
    }

    func repeatLast() {
        guard duration > 0 else { return }
        run(for: duration)
    }

    func stop() {
        endTimer?.invalidate()
        dismissTimer?.invalidate()
        state = .idle
    }

    private func run(for seconds: TimeInterval) {
        dismissTimer?.invalidate()
        endTimer?.invalidate()
        let end = Date().addingTimeInterval(seconds)
        state = .running(end: end)
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.finish() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func finish() {
        state = .finished
        NSSound(named: "Glass")?.play()
        let timer = Timer(timeInterval: Self.finishedTimeout, repeats: false) { [weak self] _ in self?.stop() }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}
