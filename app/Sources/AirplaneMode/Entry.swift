import SwiftUI

@main
struct Entry {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            // No args = default to "start" (resume with existing domains or prompt)
            await CLI.run(["start"])
            return
        }
        if args == ["--gui"] {
            AirplaneModeApp.main()
            return
        }
        await CLI.run(args)
    }
}
