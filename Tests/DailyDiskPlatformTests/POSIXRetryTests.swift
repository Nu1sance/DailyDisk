import Darwin
import Testing

@testable import DailyDiskPlatform

@Test("Interrupted metadata calls retry and return the successful result")
func interruptedMetadataCallRetries() {
    var calls = 0
    let result = retryInterruptedPOSIX {
        calls += 1
        if calls < 3 {
            errno = EINTR
            return -1
        }
        return 42
    }
    #expect(result == 42)
    #expect(calls == 3)
}

@Test("Persistent interruptions are bounded and unrelated failures retain errno")
func interruptedMetadataRetryIsBounded() {
    var calls = 0
    #expect(
        retryInterruptedPOSIX {
            calls += 1
            errno = EINTR
            return -1
        } == -1)
    #expect(calls == 9)
    #expect(errno == EINTR)
    calls = 0
    #expect(
        retryInterruptedPOSIX {
            calls += 1
            errno = EIO
            return -1
        } == -1)
    #expect(calls == 1)
    #expect(errno == EIO)
}
