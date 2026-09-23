/// Counts unique inventory objects by their volume/device/inode identity.
///
/// The scanner needs exact coverage even when link counts change concurrently
/// or a non-regular filesystem object has multiple names. The set is released
/// immediately after the scan; durable canonical attribution remains in SQLite.
public struct InventoryObjectCounter: Sendable {
    private var identities: Set<FileIdentity> = []

    public init() {}

    public var count: UInt64 { UInt64(identities.count) }

    public mutating func register(_ object: InventoryObject) {
        identities.insert(object.identity)
    }
}
