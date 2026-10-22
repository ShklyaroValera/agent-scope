import Foundation

enum HookCommand {
    static func run(arguments: [String]) {
        if isatty(STDIN_FILENO) == 0 {
            _ = FileHandle.standardInput.readDataToEndOfFile()
        }
    }
}
