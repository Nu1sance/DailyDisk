import Darwin
import Testing

@testable import DailyDiskPlatform

@Test("POSIX device identifiers preserve the signed device bit pattern")
func posixDeviceIDRoundTrip() {
    for native in [dev_t(0), dev_t(1), dev_t.max, dev_t.min, dev_t(-1)] {
        let stored = UInt64(UInt32(bitPattern: native))
        #expect(nativeDeviceID(from: stored) == native)
    }
    #expect(nativeDeviceID(from: UInt64(UInt32.max) + 1) == nil)
}
