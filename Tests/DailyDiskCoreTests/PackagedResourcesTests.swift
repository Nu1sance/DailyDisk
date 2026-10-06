import Foundation
import Testing

@testable import DailyDiskCore

@Test("Packaged GUI and helpers resolve their own resources without evaluating development fallback")
func packagedResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Fixture.app")
    let resources = app.appendingPathComponent("Contents/Resources/DailyDisk_DailyDiskCore.bundle")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: resources.appendingPathComponent("Product.json"))
    let info: [String: Any] = [
        "CFBundleIdentifier": "test.fixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "999", "CFBundleExecutable": "Fixture",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    for executable in ["MacOS/Fixture", "Helpers/DailyDiskAgent", "Helpers/dailydiskctl"] {
        let url = app.appendingPathComponent("Contents/" + executable)
        let bundle = DailyDiskResources.bundle(named: "DailyDisk_DailyDiskCore.bundle", executableURL: url) {
            Issue.record("Packaged execution must not use developer resources")
            return Bundle.main
        }
        #expect(
            try bundle?.url(forResource: "Product", withExtension: "json").map { try Data(contentsOf: $0) }
                == Data("fixture".utf8))
        #expect(
            DailyDiskResources.applicationBundle(executableURL: url)?
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String == "999")
        #expect(
            DailyDiskResources.bundle(named: "Missing.bundle", executableURL: url) {
                Issue.record("Missing packaged resources must not fall back")
                return Bundle.main
            } == nil)
    }
}

@Test("SwiftPM execution retains development resources; broken app paths never use them")
func developmentResources() {
    var called = false
    let bundle = DailyDiskResources.bundle(named: "Fixture.bundle", executableURL: URL(fileURLWithPath: "/tmp/tool")) {
        called = true
        return Bundle.main
    }
    #expect(called)
    #expect(bundle == Bundle.main)
    called = false
    #expect(
        DailyDiskResources.bundle(
            named: "Fixture.bundle",
            executableURL: URL(fileURLWithPath: "/missing/Fixture.app/Contents/Helpers/tool")
        ) {
            called = true
            return Bundle.main
        } == nil)
    #expect(!called)
}
