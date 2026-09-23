import Darwin

/// Retry signal-interrupted metadata operations without hiding persistent I/O failures.
func retryInterruptedPOSIX(_ operation: () -> Int32) -> Int32 {
    var retries = 0
    while true {
        let result = operation()
        if result != -1 || errno != EINTR || retries == 8 { return result }
        retries += 1
    }
}
