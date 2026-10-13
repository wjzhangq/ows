import Foundation
import OWABridgeCore

let semaphore = DispatchSemaphore(value: 0)
var code: Int32 = 1
Task {
    code = await runBridgeSelfTests()
    semaphore.signal()
}
semaphore.wait()
exit(code)
