//
//  AsyncSemaphore.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 05.06.25.
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

import Foundation

/// A Semaphore that allows asynchronous waiting and signaling, mimicking the behavior of a DispatchSemaphore.
/// 
/// It supports cancellation of waiting tasks. 
/// Waiting tasks are signaled in FIFO order in regards to when they were blocked.
/// Using `.run` allows you to run an action while holding the semaphore, automatically signaling it after the action completes or if an error occurs.
public actor AsyncSemaphore {
    // MARK: Internals
    
    /// Current value of the semaphore, representing the number of available permits.
    /// - Important: In almost all cases, you should not to access this value, as doing so will only lead to race conditions.
    /// Use `wait()` to wait for a permit and `signal()` to release one.
    public private(set) var value: Int = 0

    /// All current blocked waiters, indexed by their ticket.
    /// This dictionary maps each `Ticket` to its corresponding `BlockedWaiter`.
    /// - Note: This is used to manage the waiters and their continuations.
    /// It allows for cancellation of waiters and resuming their continuations when a permit is signaled.
    private var blockedWaiters: [Ticket: BlockedWaiter] = [:]

    /// A queue of tickets representing the blocked waiters. The queue is used to manage the order in which waiters are signaled when a permit becomes available.
    private var queue: TicketQueue = .init()
    
    public init(value: Int) {
        self.value = value
    }
    
    /// Handles cancellation of a blocked waiter.
    /// This method removes the waiter from the queue and cancels its continuation.
    /// - Parameter ticket: The ticket representing the blocked waiter to be cancelled.
    private func cancelBlockedWaiter(_ ticket: Ticket) {
        if let queueIndex = queue.firstIndex(of: ticket) {
            queue.remove(at: queueIndex)
        }
        blockedWaiters[ticket]?.cancel()
        blockedWaiters.removeValue(forKey: ticket)
    }
    // MARK: Wait


    /// Waits for a permit from the semaphore.
    /// If a permit is available, it decrements the value and returns immediately.
    /// If no permits are available, it blocks the current task until a permit is signaled.
    /// If the task is cancelled while waiting, a `CancellationError` is thrown.
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    /// - Note: If the task calling this method is already cancelled at the moment of calling this method, the semaphore will not be waited on, and the method will throw a `CancellationError`.
    public func wait() async throws {
        try Task.checkCancellation()

        guard value == 0 else {
            value -= 1
            return
        }

        let ticket = Ticket()
        blockedWaiters[ticket] = .init()

        let _: Void = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard blockedWaiters[ticket]?.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                blockedWaiters[ticket]?.continuation = continuation
                queue.enqueue(ticket)
            }
        } onCancel: {
            Task {
                await self.cancelBlockedWaiter(ticket)
            }
        }

        // If signal() raced with the cancellation handler and delivered the permit before
        // cancelBlockedWaiter ran, the continuation was resumed successfully but the calling
        // task is still cancelled. Give the permit back so it isn't lost, then throw.
        if Task.isCancelled {
            self.signal()
            throw CancellationError()
        }
    }

    // MARK: Signal
    
    /// Signals the semaphore, waking up one waiting task if any are blocked, or incrementing the value if none are.
    /// - Returns: `true` if a waiting task was signaled, `false` if there were no waiting tasks.
    @discardableResult
    public func signal() -> Bool {
        guard let firstTicket = queue.dequeue() else {
            // No waiter - bank the permit so a future wait() can consume it.
            value += 1
            return false
        }
        guard let waiter = blockedWaiters[firstTicket] else {
            preconditionFailure("Missing waiter for ticket \(firstTicket)")
        }
        blockedWaiters.removeValue(forKey: firstTicket)
        guard !waiter.isCancelled else {
            preconditionFailure("Cancelled waiter for ticket \(firstTicket) should not have been in the queue")
        }
        // Permit transfers directly to the waiter; value stays unchanged.
        waiter.continuation?.resume(returning: ())
        return true
    }
    
    // MARK: Run

    /// Runs an asynchronous action while holding the semaphore.
    /// This method waits for a permit, executes the action, and signals the semaphore after the action completes or if an error occurs.
    /// - Parameter action: The asynchronous action to run while holding the semaphore.
    /// - Returns: The result of the action.
    /// - Throws: Any error thrown by the action or a `CancellationError` if the task is cancelled while waiting.
    public func run<T>(_ action: () async throws -> T) async throws -> T {
        try await self.wait()
        defer { self.signal() }
        return try await action()
    }
}
