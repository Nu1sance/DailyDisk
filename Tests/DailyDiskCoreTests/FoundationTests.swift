import Testing

@testable import DailyDiskCore

@Test("Product metadata is stable")
func productMetadata() {
    #expect(DailyDiskProduct.name == "DailyDisk")
    #expect(DailyDiskProduct.minimumMacOSVersion == "15.0")
}
