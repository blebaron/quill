import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)
        RecordingsAgentsDoc.ensureUpToDate(root: root)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        // SIGINT (Ctrl-C) is the interactive case; SIGTERM is what
        // `launchctl`/shutdown/kill send to stop the LaunchAgent, and SIGHUP
        // fires if a controlling terminal goes away out from under a
        // manually-started process. All three used to fall through to the
        // OS default (instant termination, no cleanup) — losing a
        // recording's meta.json and orphaning its audio with no chance for
        // the transcription queue to ever pick it up. Route all three
        // through the same graceful shutdown as SIGINT.
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            signal(sig, SIG_IGN)
            signalSources.append(source)
        }

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var watchTimer: Timer?
    private var reminderIntervalSeconds: TimeInterval = 0
    private var nextReminderAt: TimeInterval = 0

    /// How often to re-scan the recordings root for sessions this process
    /// didn't create itself — e.g. a mobile companion dropping a folder in
    /// via iCloud Drive sync. `resumePending` only runs at launch otherwise,
    /// so without this a synced-in session would sit untranscribed until the
    /// next restart.
    private static let watchIntervalSeconds: TimeInterval = 30

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForExternalSessions() }
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        watchTimer?.invalidate()
        watchTimer = nil
        stopSession()
        NSApp.terminate(nil)
    }

    private func scanForExternalSessions() {
        Task { [transcription, root] in await transcription.resumePending(root: root) }
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        let reminderMinutes = Config.reminderIntervalMinutes()
        reminderIntervalSeconds = reminderMinutes > 0 ? TimeInterval(reminderMinutes * 60) : 0
        nextReminderAt = reminderIntervalSeconds
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Date().timeIntervalSince(session.startedAt)
        menuBar.update(recording: true, elapsed: Self.format(elapsed))

        // Nothing else interrupts a long-forgotten recording, so nudge the
        // user periodically instead of relying on them to notice the menu
        // bar. reminderIntervalSeconds is 0 when disabled via config.
        if reminderIntervalSeconds > 0, elapsed >= nextReminderAt {
            FileHandle.standardError.write(Data("reminder · still recording · \(Self.format(elapsed))\n".utf8))
            notifyUser(title: "quill — still recording", body: "still recording · \(Self.format(elapsed))")
            nextReminderAt += reminderIntervalSeconds
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
