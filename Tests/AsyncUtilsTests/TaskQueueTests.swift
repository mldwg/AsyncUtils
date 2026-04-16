//
//  TaskQueueTests.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 24.04.24.
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


final class TaskQueueTests: XCTestCase {
    var queue: TaskQueue = .init()
    var store: TestingStorage = .init()
    
    override func setUpWithError() throws {
        self.store = TestingStorage()
        self.queue = .init(maxConcurrentSlots: 3)
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    
    func testAdd() async throws {
        self.queue = .init(maxConcurrentSlots: 1)
        for _ in 0..<500 {
            await self.queue.add {
                try? await Task.sleep(for: .microseconds(1))
            }
        }
        let count1 = await self.queue.count
        let runningCount1 = await self.queue.runningCount
        let queuedCount1 = await self.queue.queuedCount
        XCTAssertGreaterThan(count1, 1)
        XCTAssertGreaterThan(queuedCount1, 1)
        XCTAssertEqual(runningCount1, 1)
    }
    
    
    func testAddAndWait() async throws {
        for _ in 0..<10 {
            await self.queue.add {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let counts1 = await self.queue.counts
        XCTAssertGreaterThan(counts1.count, 1)
        XCTAssertGreaterThan(counts1.queued, 1)
        XCTAssertEqual(counts1.running, 3)
        
        try await self.queue.addAndWait {
            try? await Task.sleep(for: .milliseconds(10))
        }
        
        let counts2 = await self.queue.counts
        XCTAssertEqual(counts2, .init(queued: 0, running: 0))
        
        await self.queue.add {
            try? await Task.sleep(for: .milliseconds(10))
        }
        
        let counts3 = await self.queue.counts
        XCTAssertEqual(counts3, .init(queued: 0, running: 1))
        
        await self.queue.cancelAll()
    }
    
    
    
    func testWaitForAll() async throws {
        for i in 0..<100 {
            await self.queue.add {
                try! await Task.sleep(for: .milliseconds(10))
                await self.store.ended(i)
            }
        }
        
        try! await self.queue.waitForAll()
        let ts = Date()
        
        let count2 = await self.queue.count
        XCTAssertEqual(count2, 0)
        
        let lastTaskCompletion = await self.store.ends.map {$0.1}.max()!
        
        XCTAssertGreaterThan(ts, lastTaskCompletion)
        XCTAssertEqual(lastTaskCompletion.timeIntervalSinceReferenceDate, ts.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }
    
    func testWaitForAllCancellation() async throws {
        self.queue = .init(maxConcurrentSlots: 2)
        for _ in 0..<3 {
            await self.queue.add {
                try? await Task.sleep(for: .seconds(0.1))
            }
        }
        await self.queue.add {
            try? await Task.sleep(for: .seconds(1.0))
        }
        
        
        
        
        let start1 = Date()
        // Try to cancel waitForAll while the queue has no free running slots (2 tasks running)
        try await Task.withTimeout(cancelAfter: .seconds(0.05)) {
            try? await self.queue.waitForAll()
        }
        let delta1 = Date().timeIntervalSince(start1)
        XCTAssertEqual(delta1, 0.05, accuracy: 0.01)
        
        try? await Task.sleep(for: .seconds(0.06))
        
        let start2 = Date()
        // Try to cancel waitForAll while the queue has no free running slots (2 tasks running)
        try await Task.withTimeout(cancelAfter: .seconds(0.05)) {
            try? await self.queue.waitForAll()
        }
        let delta2 = Date().timeIntervalSince(start2)
        XCTAssertEqual(delta2, 0.05, accuracy: 0.01)
        
        let start3 = Date()
        // Try to cancel waitForAll while the queue has free running slots (1 tasks running)
        try await Task.withTimeout(cancelAfter: .seconds(0.1)) {
            try? await self.queue.waitForAll()
        }
        let delta3 = Date().timeIntervalSince(start3)
        XCTAssertEqual(delta3, 0.1, accuracy: 0.1)

        try await queue.cancelAllAndWait()
    }
    
    func testAddAndWaitCancelWhileRunningRaceCondition() async throws {
        self.queue = .init(maxConcurrentSlots: 2)
        await self.queue.add {
            try? await Task.sleep(for: .seconds(0.1))
        }
        
        let spamTask = Task {
            while true {
                try await queue.addAndWait {
                    try? await Task.sleep(nanoseconds: 1)
                }
            }
        }
        
        try await Task.sleep(for: .seconds(0.01))
        spamTask.cancel()
        try await Task.sleep(for: .seconds(0.1))
    }
    
    func testAddAndWaitThrowsCancelWhileRunningRaceCondition() async throws {
        self.queue = .init(maxConcurrentSlots: 2)
        await self.queue.add {
            try? await Task.sleep(for: .seconds(0.1))
        }
        
        let spamTask = Task {
            while true {
                try await queue.addAndWait {
                    try await Task.sleep(nanoseconds: 1)
                }
            }
        }
        
        try await Task.sleep(for: .seconds(0.01))
        spamTask.cancel()
        try await Task.sleep(for: .seconds(0.1))
    }
    
    func testCancelQueued() async throws {
        for i in 0..<500 {
            await self.queue.add {
                await self.store.started(i)
                await self.store.incrementCounter()
                do {
                    try await Task.sleep(for: .milliseconds(1))
                    await self.store.ended(i)
                } catch {}
            }
        }
        
        await self.queue.cancelQueued()
        try! await self.queue.waitForAll()
        
        let counter = await self.store.counter
        XCTAssertLessThan(counter, 500)
        
        let starts = await self.store.starts
        let ends = await self.store.ends
        
        XCTAssertEqual(starts.count, counter)
        XCTAssertEqual(ends.count, counter)
    }
    
    func testCancelAll() async throws {
        let cancellationStore = TestingStorage()
        self.queue = .init(maxConcurrentSlots: 20)
        for i in 0..<500 {
            await self.queue.add {
                await self.store.started(i)
                await self.store.incrementCounter()
                do {
                    try await Task.sleep(for: .milliseconds(1000))
                    try Task.checkCancellation()
                    await self.store.ended(i)
                } catch is CancellationError {
                    await cancellationStore.incrementCounter()
                } catch {
                    
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(70))
        try! await self.queue.cancelAllAndWait()
        
        let counter1 = await self.store.counter
        XCTAssertLessThan(counter1, 500)
        
        let cancellationCounter = await cancellationStore.counter
        XCTAssertGreaterThanOrEqual(cancellationCounter, 1)
        
        let starts = await self.store.starts
        let ends = await self.store.ends
        
        XCTAssertEqual(starts.count, counter1)
        XCTAssertLessThan(ends.count, counter1)
        
        // Check that the queue still works
        for _ in 0..<100 {
            await self.queue.add {
                await self.store.incrementCounter()
            }
        }
        try! await self.queue.waitForAll()
        let counter2 = await self.store.counter
        XCTAssertEqual(counter1 + 100, counter2)
    }
    
    func testOrderOfOperationsSerial() async throws {
        self.queue = .init(maxConcurrentSlots: 1)
        for i in 0..<500 {
            await self.queue.add {
                await self.store.started(i)
                try! await Task.sleep(for: .microseconds(1))
                await self.store.ended(i)
            }
        }

        try! await self.queue.waitForAll()
     
        let starts = await self.store.starts
        let ends = await self.store.ends
        
        for i in 0..<500 {
            XCTAssertLessThanOrEqual(starts[i]!, ends[i]!)
        }
        
        for i in 1..<500 {
            XCTAssertLessThanOrEqual(ends[i-1]!, starts[i]!)
        }
    }
    
    func testOrderOfOperationsParallel() async throws {
        for i in 0...7 {
            await self.queue.add {
                await self.store.started(i)
                try! await Task.sleep(for: .microseconds(1000*i))
                await self.store.ended(i)
            }
        }

        try! await self.queue.waitForAll()
     
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
    
    func testAddAndWaitCancellationWhileRunning() async throws {
        let task = Task {
            await self.store.started(0)
            try await self.queue.addAndWait {
                if !Task.isCancelled {
                    await self.store.incrementCounter()
                }
                
                try? await Task.sleep(for: .seconds(0.2))
                
                if !Task.isCancelled {
                    await self.store.incrementCounter()
                }
            }
            
  
            await self.store.ended(0)
            return 1
        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 1)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }
    
    func testAddAndWaitCancellationWhileQueued() async throws {
        for _ in 0..<3 {
            await self.queue.add {
                try! await Task.sleep(for: .seconds(0.2))
            }
        }
        
        let task = Task {
            await self.store.started(0)
            
            try await self.queue.addAndWait {
                if !Task.isCancelled {
                    await self.store.incrementCounter()
                }
                await self.store.incrementCounter()
                try? await Task.sleep(for: .seconds(0.2))
                if !Task.isCancelled {
                    await self.store.incrementCounter()
                }
            }
  
            await self.store.ended(0)
        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 0)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }
    
    func testAddAndWaitCancellationBeforeQueued() async throws {
        for _ in 0..<3 {
            await self.queue.add {
                try! await Task.sleep(for: .seconds(0.2))
            }
        }
        
        let task = Task {
            await self.store.started(0)
            
            try await self.queue.addAndWait {
                await self.store.incrementCounter()
            }
  
            await self.store.ended(0)
        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 0)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }
    
    func testAddAndWaitThrowsCancellationWhileRunning() async throws {
        
        
        let task = Task {
            await self.store.started(0)
            try await self.queue.addAndWait {
                await self.store.incrementCounter()
                try await Task.sleep(for: .seconds(0.2))
                await self.store.incrementCounter()
            }
            await self.store.ended(0)

        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 1)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }
    
    func testAddAndWaitThrowsCancellationWhileQueued() async throws {
        
        for _ in 0..<3 {
            await self.queue.add {
                try! await Task.sleep(for: .seconds(0.2))
            }
        }
        
        let task = Task {
            await self.store.started(0)
            try await self.queue.addAndWait {
                await self.store.incrementCounter()
                try await Task.sleep(for: .seconds(0.2))
                await self.store.incrementCounter()
            }
            await self.store.ended(0)

        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 0)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }
    

    func testAddAndWaitThrowsCancellationBeforeQueued() async throws {
        
        for _ in 0..<3 {
            await self.queue.add {
                try! await Task.sleep(for: .seconds(0.2))
            }
        }
        
        let task = Task {
            await self.store.started(0)
            if !Task.isCancelled {
                await Task.yield()
            }
            
            try await self.queue.addAndWait {
                await self.store.incrementCounter()
            }
            await self.store.ended(0)

        }

        try! await Task.sleep(for: .seconds(0.1))
        task.cancel()
        let cancellationTime = Date()
        
        let result = await task.result
        
        let (starts, ends, counter) = await self.store.data
        
        XCTAssertEqual(counter, 0)
        XCTAssertLessThan(starts[0]!, cancellationTime)
        XCTAssertEqual(ends.count, 0)
        XCTAssertTrue(result.isCancellationResult)
    }

    // MARK: - TaskProvider Tests

    /// Provider set in init fires as soon as all slots are free.
    func testProviderCalledOnInit() async throws {
        let store = TestingStorage()
        self.queue = TaskQueue(maxConcurrentSlots: 1, taskProvider: { _ in
            await store.incrementCounter()
            return nil
        })
        try await Task.sleep(for: .milliseconds(50))
        let count = await store.counter
        XCTAssertEqual(count, 1)
    }

    /// A task returned by the provider is actually enqueued and executed.
    func testProviderTaskIsExecuted() async throws {
        let store = TestingStorage()
        // isProviderActive serialises calls, so reading then incrementing counter is race-free.
        self.queue = TaskQueue(maxConcurrentSlots: 1, taskProvider: { _ in
            let alreadyProvided = await store.counter > 0
            await store.incrementCounter()
            guard !alreadyProvided else { return nil }
            return TaskQueue.QueueableTask {
                await store.started(0)
                await store.ended(0)
            }
        })
        try await Task.sleep(for: .milliseconds(100))
        let ends = await store.ends
        XCTAssertNotNil(ends[0])
    }

    /// With N free slots the provider is called in rapid succession until all slots are
    /// filled or it returns nil, producing exactly N tasks.
    func testProviderFillsAllFreeSlots() async throws {
        let store = TestingStorage()
        let slotCount = 3
        // counter doubles as a unique task ID; provider returns a task for IDs 0..<slotCount.
        self.queue = TaskQueue(maxConcurrentSlots: slotCount, taskProvider: { _ in
            let id = await store.counter
            guard id < slotCount else { return nil }
            await store.incrementCounter()
            return TaskQueue.QueueableTask {
                await store.started(id)
                await store.ended(id)
            }
        })
        try await Task.sleep(for: .milliseconds(200))
        let (starts, ends, _) = await store.data
        XCTAssertEqual(starts.count, slotCount)
        XCTAssertEqual(ends.count, slotCount)
    }

    /// Provider must not fire while there are tasks waiting in the explicit queue.
    func testProviderNotCalledWhileExplicitQueueNonEmpty() async throws {
        let store = TestingStorage()
        self.queue = TaskQueue(maxConcurrentSlots: 1, taskProvider: { _ in
            await store.incrementCounter()
            return nil
        })
        // Let the init-time provider call settle before adding tasks.
        try await Task.sleep(for: .milliseconds(50))
        let counter1 = await store.counter
        XCTAssertEqual(counter1, 1)

        // Fill the single slot and create a two-task backlog.
        await self.queue.add { try? await Task.sleep(for: .milliseconds(200)) }
        await self.queue.add { }
        await self.queue.add { }

        // Halfway through the slow task the backlog still exists; provider must stay silent.
        try await Task.sleep(for: .milliseconds(100))
        let counterMidway = await store.counter
        XCTAssertEqual(counterMidway, 1)
        try await self.queue.cancelAllAndWait()
    }

    /// After a provider-generated task finishes and a slot frees up, the provider is called again.
    func testProviderRetriggeredAfterTaskCompletes() async throws {
        let store = TestingStorage()
        self.queue = TaskQueue(maxConcurrentSlots: 1, taskProvider: { _ in
            let callNumber = await store.counter
            await store.incrementCounter()
            guard callNumber == 0 else { return nil }
            return TaskQueue.QueueableTask {
                try? await Task.sleep(for: .milliseconds(50))
            }
        })
        // Allow: init call (returns task) + post-completion call (returns nil).
        try await Task.sleep(for: .milliseconds(200))
        let providerCallCount = await store.counter
        XCTAssertEqual(providerCallCount, 2)
    }

    /// waitForAll returns after explicitly-queued tasks are done even when the provider
    /// subsequently generates long-running tasks.
    func testWaitForAllDoesNotWaitForProviderTasksAddedAfter() async throws {
        let store = TestingStorage()
        // Provider returns nil until the explicit task has started (counter > 0),
        // then yields a 10-second task that waitForAll must not block on.
        self.queue = TaskQueue(maxConcurrentSlots: 1, taskProvider: { _ in
            guard await store.counter > 0 else { return nil }
            return TaskQueue.QueueableTask {
                try? await Task.sleep(for: .seconds(10))
            }
        })
        await self.queue.add {
            await store.incrementCounter()   // arms the provider
            await store.started(0)
            try? await Task.sleep(for: .milliseconds(50))
            await store.ended(0)
        }
        let start = Date()
        try await self.queue.waitForAll()
        let elapsed = Date().timeIntervalSince(start)

        // Must return in roughly the explicit task's duration, not 10 s.
        XCTAssertLessThan(elapsed, 1.0)
        let ends = await store.ends
        XCTAssertNotNil(ends[0])
        await self.queue.cancelAll()
    }

    // MARK: - Bug regression tests

    /// QueueableTask.slots is hardcoded to 1; the init parameter is silently ignored.
    func testQueueableTaskSlotsStoredCorrectly() {
        let task1 = TaskQueue.QueueableTask(slots: 1) {}
        XCTAssertEqual(task1.slots, 1)

        let task3 = TaskQueue.QueueableTask(slots: 3) {}
        XCTAssertEqual(task3.slots, 3)

        let task5 = TaskQueue.QueueableTask(slots: 5) {}
        XCTAssertEqual(task5.slots, 5)
    }

    /// A task that requires 2 slots on a queue with maxConcurrentSlots:2 should
    /// occupy all slots and block any subsequent 1-slot task until it finishes.
    func testMultiSlotTaskBlocksQueue() async throws {
        let q = TaskQueue(maxConcurrentSlots: 2)
        let storage = TestingStorage()

        // Task 0 consumes both available slots.
        await q.add(slots: 2) {
            await storage.started(0)
            try? await Task.sleep(for: .milliseconds(150))
            await storage.ended(0)
        }

        // Task 1 only needs 1 slot but must wait until Task 0 releases its 2.
        await q.add(slots: 1) {
            await storage.started(1)
            await storage.ended(1)
        }

        try await q.waitForAll()

        let (starts, ends, _) = await storage.data
        XCTAssertNotNil(starts[0])
        XCTAssertNotNil(ends[0])
        XCTAssertNotNil(starts[1])
        // Task 1 must not start before Task 0 finishes.
        XCTAssertGreaterThanOrEqual(starts[1]!, ends[0]!)
    }
}

extension Result {
    var isCancellationResult: Bool {
        switch self {
        case .success:
            return false
        case .failure(let failure):
            if failure is CancellationError {
                return true
            }
            return false
        }
    }
}
