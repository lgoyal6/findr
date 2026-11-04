import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
    CLI.run(arguments[index + 1])
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
