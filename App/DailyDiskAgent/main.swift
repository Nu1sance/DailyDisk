import DailyDiskPlatform
import Darwin
import Foundation

@main
struct DailyDiskAgent {
    static func main() async {
        let dryRun = ProcessInfo.processInfo.environment["DAILYDISK_DRY_RUN"] == "1"
        exit(await DailyDiskAgentRunner().run(dryRun: dryRun))
    }
}
