//
//  AsyncOperationTests.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 30.04.24.
//  Licensed under the MIT-License included in the project.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import XCTest
@testable import AsyncUtils

final class AsyncOperationTests: XCTestCase {

    var operationQueue = OperationQueue()
    var store = TestingStorage()
    
    override func setUpWithError() throws {
        self.operationQueue = OperationQueue()
        self.operationQueue.maxConcurrentOperationCount = 3
        
        self.store = .init()
    }

    func testOrderOfOperationsParallel() async throws {
        for i in 0...7 {
            self.operationQueue.addOperation {
                await self.store.started(i)
                try! await Task.sleep(for: .milliseconds(1*i))
                await self.store.ended(i)
            }
        }

        try! await Task.sleep(for: .milliseconds(100))
     
        let (starts, ends, _) = await self.store.data
        
        for i in 0...7 {
            XCTAssertLessThanOrEqual(starts[i]!, ends[i]!)
        }
        
     
        XCTAssertLessThanOrEqual(starts[0]!, starts[3]!)
        XCTAssertLessThanOrEqual(starts[1]!, starts[3]!)
        XCTAssertLessThanOrEqual(starts[2]!, starts[3]!)
        
        XCTAssertLessThanOrEqual(ends[0]!, starts[3]!)
        XCTAssertLessThanOrEqual(ends[1]!, starts[4]!)
        XCTAssertLessThanOrEqual(ends[2]!, starts[5]!)
        XCTAssertLessThanOrEqual(ends[3]!, starts[6]!)
        XCTAssertLessThanOrEqual(ends[4]!, starts[7]!)
    }
    
    func testCancellation() async throws {
        var operations: [Operation] = []
        for i in 0...7 {
            operations.append(self.operationQueue.addOperation {
                do {
                    await self.store.started(i)
                    try await Task.sleep(for: .milliseconds(10*i))
                    await self.store.ended(i)
                } catch {}
            })
        }
        
        try! await Task.sleep(for: .milliseconds(1))
        
        operations.reversed().forEach { $0.cancel() }

        try! await Task.sleep(for: .milliseconds(100))
     
        let (starts, ends, _) = await self.store.data
        
        XCTAssertEqual(starts.count, 4)
        XCTAssertEqual(ends.count, 1)
        
        XCTAssertLessThanOrEqual(starts[0]!, ends[0]!)
        
     
        XCTAssertLessThanOrEqual(starts[0]!, starts[3]!)
        XCTAssertLessThanOrEqual(starts[1]!, starts[3]!)
        XCTAssertLessThanOrEqual(starts[2]!, starts[3]!)
        
        XCTAssertLessThanOrEqual(ends[0]!, starts[3]!)
    }

    // MARK: - Bug regression tests

    /// cancel() does not call super.cancel(), so NSOperation's own cancelled
    /// flag is never set. At minimum, our isCancelled override must return true.
    func testCancelSetsisCancelledFlag() {
        let op = AsyncOperation { }
        XCTAssertFalse(op.isCancelled)
        op.cancel()
        XCTAssertTrue(op.isCancelled)
    }

    /// A queued operation that is cancelled before the queue starts it must
    /// never execute its closure.
    func testCancelledQueuedOperationDoesNotExecute() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        // Block the single slot with a long-running operation.
        let blockerStarted = expectation(description: "blockerStarted")
        queue.addOperation {
            blockerStarted.fulfill()
            try? await Task.sleep(for: .seconds(0.3))
        }
        await fulfillment(of: [blockerStarted], timeout: 1.0)

        // Add an operation, then immediately cancel it before the slot opens.
        let runCount = TestingStorage()
        let cancelledOp = AsyncOperation {
            await runCount.incrementCounter()
        }
        queue.addOperation(cancelledOp)
        cancelledOp.cancel()

        // Wait long enough for the blocker to finish and the queue to drain.
        try await Task.sleep(for: .seconds(0.5))

        let count = await runCount.counter
        XCTAssertEqual(count, 0, "Cancelled operation must not execute")
    }
}
