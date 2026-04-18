//
//  AsyncOperation.swift
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

import Foundation


/// An `Operation` subclass that performs an asynchronous operation using swift concurrency.
public class AsyncOperation: Operation, @unchecked Sendable {
    private static let lockQueue = DispatchQueue(label: "de.mludwig.AsyncUtils.AsyncOperation.LockQueue")

    // MARK: - Property Overrides

    /// An `AsyncOperation` is always asynchronous.
    override public var isAsynchronous: Bool { true }

    /// We have to override the `isExecuting` and `isFinished` properties to make sure that KVO notifications are sent correctly.
    private var _isExecuting: Bool = false
    override public private(set) var isExecuting: Bool {
        get {
            return Self.lockQueue.sync { self._isExecuting }
        }
        set {
            willChangeValue(forKey: "isExecuting")
            Self.lockQueue.sync(flags: [.barrier]) {
                self._isExecuting = newValue
            }
            didChangeValue(forKey: "isExecuting")
        }
    }

    private var _isFinished: Bool = false
    override public private(set) var isFinished: Bool {
        get {
            return Self.lockQueue.sync { self._isFinished }
        }
        set {
            willChangeValue(forKey: "isFinished")
            Self.lockQueue.sync(flags: [.barrier]) {
                self._isFinished = newValue
            }
            didChangeValue(forKey: "isFinished")
        }
    }
    
    // MARK: Async Operation State

    private var _task: Task<Void, Never>? = nil

    /// The asynchronous operation to be performed. This is set in the initializer and executed in `main()`.
    public let operation: @Sendable () async -> Void
    
    
    /// Crates a new `AsyncOperation` with the given asynchronous operation.
    /// - Parameter operation: The asynchronous operation to be performed when the `AsyncOperation` is executed.
    public init(operation: @Sendable @escaping () async -> Void) {
        self.operation = operation
    }

    /// Starts the operation. 
    /// 
    /// This method checks if the operation has been cancelled, and if not, calls `main()`.
    /// - Note: If using with an `OperationQueue`, do not call this method directly - the `OperationQueue` will call it when the operation is started. If you need to start the operation manually, call this method, which will check for cancellation and trigger the normal start flow.
    override public func start() {
        guard !self.isCancelled else {
            finish()
            return
        }
        let (isFinished, isExecuting) = Self.lockQueue.sync {
            return (self._isFinished, self._isExecuting)
        }
        guard !isFinished && !isExecuting else {
            return
        }

        main()
    }

    /// The main entry point for the operation. 
    /// 
    /// This method sets the `isExecuting` property to `true`, creates a new `Task` to perform the asynchronous operation, and calls `finish()` when the operation completes.
    /// - Note: If using with an `OperationQueue`, do not call this method directly - the `OperationQueue` will call it when the operation is started. If you need to start the operation manually, call `start()` instead, which will check for cancellation and trigger the normal start flow.
    override public func main() {
        willChangeValue(forKey: "isExecuting")
        Self.lockQueue.sync(flags: [.barrier]) {
            self._isExecuting = true
            self._task = Task {
                await operation()
                self.finish()
            }
        }
        didChangeValue(forKey: "isExecuting")
    }
    
    /// Cancels the operation. 
    /// 
    /// If the operation is already started, this method cancels the underlying `Task` and calls `super.cancel()` to set the `isCancelled` flag and fire KVO notifications.
    override public func cancel() {
        Self.lockQueue.sync(flags: [.barrier]) {
            self._task?.cancel()
        }
        // super.cancel() sets isCancelled and fires its KVO notification exactly once,
        // with the correct old=false/new=true transition. It also updates NSOperation's
        // internal state for dependency tracking and cancelAllOperations().
        super.cancel()
    }

    /// Finishes the operation. 
    /// 
    /// This method sets the `isExecuting` property to `false`, the `isFinished` property to `true`, and clears the underlying `Task`.
    /// - Note: If using with an `OperationQueue`, do not call this method directly - the `OperationQueue` will call it when the operation is finished. If you need to finish the operation manually, call `cancel()` instead, which will cancel the underlying `Task` and trigger the normal cancellation flow.
    public func finish() {
        let (wasFinished, wasExecuting) = Self.lockQueue.sync {
            return (self._isFinished, self._isExecuting)
        }
        guard !wasFinished else {
            return
        }
        if wasExecuting {
            self.willChangeValue(forKey: "isExecuting")
        }
        self.willChangeValue(forKey: "isFinished")
        Self.lockQueue.sync(flags: [.barrier]) {
            self._isExecuting = false
            self._isFinished = true
            self._task = nil
        }
        if wasExecuting {
            self.didChangeValue(forKey: "isExecuting")
        }
        self.didChangeValue(forKey: "isFinished")
    }
}

public extension OperationQueue {
    /// Adds an `AsyncOperation` to the operation queue.
    /// - Parameter operation: The asynchronous operation to be executed.
    /// - Returns: The `AsyncOperation` instance that was added to the queue.
    @discardableResult
    func addOperation(_ operation: @Sendable @escaping () async -> Void) -> AsyncOperation {
        let asyncOperation = AsyncOperation(operation: operation)
        self.addOperation(asyncOperation)
        return asyncOperation
    }
}
