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
        
        for operation in operations {
            XCTAssertFalse(operation.isExecuting)
            XCTAssertTrue(operation.isFinished)
        }
    }

    // MARK: - Bug regression tests

    /// Regression: cancel() manually fires willChangeValue/didChangeValue for
    /// "isCancelled", then calls super.cancel() which fires them again.
    /// Observers must receive exactly one notification per cancellation.
    func testCancelFiresIsCancelledKVOExactlyOnce() {
        let op = AsyncOperation { }
        var changeCount = 0
        let obs = op.observe(\.isCancelled, options: [.new]) { _, _ in
            changeCount += 1
        }
        op.cancel()
        obs.invalidate()
        XCTAssertEqual(changeCount, 1,
            "cancel() must fire isCancelled KVO exactly once, not twice")
    }

    /// Regression: finish() has no guard against double-calls - a second call fires
    /// spurious isExecuting and isFinished KVO notifications on an already-finished
    /// operation, which can confuse NSOperationQueue.
    func testFinishIsIdempotent() {
        let op = AsyncOperation { }
        var isFinishedNotificationCount = 0
        let obs = op.observe(\.isFinished, options: [.new]) { _, _ in
            isFinishedNotificationCount += 1
        }

        op.finish()
        op.finish()
        obs.invalidate()

        XCTAssertEqual(isFinishedNotificationCount, 1,
            "finish() must not fire isFinished KVO more than once")
    }
    
    /// Regression: start() has no guard against double-calls - a second call
    /// starts another task while the first is still running, which can cause unpredictable behavior.
    func testStartIsIdempotentOnExecutingOperation() async throws {
        let runCount = TestingStorage()
        let started = expectation(description: "operation started")

        let op = AsyncOperation {
            await runCount.incrementCounter()
            started.fulfill()
            // Stay running long enough for us to call start() a second time.
            try? await Task.sleep(for: .seconds(0.2))
        }

        op.start()
        await fulfillment(of: [started], timeout: 1.0)

        // isExecuting is true - a second start() must be a no-op.
        op.start()

        try await Task.sleep(for: .seconds(0.3))
        let count = await runCount.counter
        XCTAssertEqual(count, 1, "start() on an already-executing operation must not launch a second task")
    }

    /// Regression: start() has no guard against double-calls - a second call
    /// starts another task after the task of the operation has already finished, which can cause unpredictable behavior.
    func testStartIsIdempotentOnFinishedOperation() async throws {
        let runCount = TestingStorage()
        let finished = expectation(description: "operation finished")

        let op = AsyncOperation {
            await runCount.incrementCounter()
        }

        // Use KVO to confirm isFinished is true before calling start() again -
        // finish() is called asynchronously after the closure returns, so a plain
        // sleep would be racy.
        let obs = op.observe(\.isFinished, options: [.new]) { _, change in
            if change.newValue == true { finished.fulfill() }
        }

        op.start()
        await fulfillment(of: [finished], timeout: 1.0)
        obs.invalidate()

        // isFinished is true - a second start() must be a no-op.
        op.start()
        try await Task.sleep(for: .milliseconds(50))

        let count = await runCount.counter
        XCTAssertEqual(count, 1, "start() on a finished operation must not restart it")
    }

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

    func testCancelledQueuedOperationIsFinished() async throws {
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
        let cancelledOp = AsyncOperation {
            try? await Task.sleep(for: .seconds(0.1))
        }
        queue.addOperation(cancelledOp)
        cancelledOp.cancel()

        // Wait long enough for the blocker to finish and the queue to drain.
        try await Task.sleep(for: .seconds(0.5))

        XCTAssertTrue(cancelledOp.isCancelled, "Cancelled operation must be cancelled")
        XCTAssertTrue(cancelledOp.isFinished, "Cancelled operation must be finished")
    }
}
