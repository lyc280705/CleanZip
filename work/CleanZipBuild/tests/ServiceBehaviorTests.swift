import AppKit

@main
@MainActor
struct ServiceBehaviorTests {
    static func main() async {
        _ = NSApplication.shared
        let failures = await ArchiveSafetyTests.run()
        if failures.isEmpty {
            print("PASS: CleanZip Finder service safety tests")
            exit(EXIT_SUCCESS)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(EXIT_FAILURE)
    }
}
