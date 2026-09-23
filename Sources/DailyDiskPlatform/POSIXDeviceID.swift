import Darwin

/// Darwin dev_t is signed, but its full 32-bit pattern identifies a device.
/// Store the unsigned pattern without changing existing positive identifiers.
func nativeDeviceID(from stored: UInt64) -> dev_t? {
    guard let bits = UInt32(exactly: stored) else { return nil }
    return dev_t(bitPattern: bits)
}
