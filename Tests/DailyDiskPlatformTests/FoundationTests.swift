import Foundation
import Testing

@testable import DailyDiskPlatform

@Test("Test host satisfies the deployment target")
func testHostSatisfiesDeploymentTarget() {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    #expect(version.majorVersion >= 15)
}
