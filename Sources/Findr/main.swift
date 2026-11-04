import Foundation

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
    CLI.run(arguments[index + 1])
}
