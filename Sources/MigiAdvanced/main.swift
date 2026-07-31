import AppKit
import Darwin

private func acquireMigiInstanceOrExit() -> MigiSingleInstanceGate {
    let isIsolatedQACapture = CommandLine.arguments.contains {
        $0.hasPrefix("--qa-capture=")
    }
    let acquisition: MigiSingleInstanceAcquisition
    if isIsolatedQACapture {
        // Metal QA launches through LaunchServices like the installed app, but
        // it must neither replace nor wake the user's normal pet. A separate
        // advisory lock permits exactly one short-lived capture process while
        // preserving the production single-instance guarantee.
        let qaLockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "local.fdk.migi-advanced.qa-instance.lock",
                isDirectory: false
            )
        acquisition = MigiSingleInstanceGate.acquire(at: qaLockURL)
    } else {
        acquisition = MigiSingleInstanceGate.acquireDefault()
    }

    switch acquisition {
    case .acquired(let gate):
        return gate
    case .alreadyRunning:
        if !isIsolatedQACapture {
            MigiInstanceControl.requestShowExistingInstance()
        }
        Darwin.exit(EXIT_SUCCESS)
    case .failed(let message):
        fputs("Migi Advanced: \(message)\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
}

private let singleInstanceGate = acquireMigiInstanceOrExit()
private let app = NSApplication.shared
private let appDelegate = AppDelegate()

app.setActivationPolicy(.accessory)
app.delegate = appDelegate
withExtendedLifetime(singleInstanceGate) {
    app.run()
}
