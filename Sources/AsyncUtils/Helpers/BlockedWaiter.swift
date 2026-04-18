//
//  Ticket.swift
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


/// Internal type to represent a task waiting for the semaphore.
internal struct BlockedWaiter: Sendable {
    /// Flag to indicate if the waiter has been cancelled.
    private(set) var isCancelled: Bool = false
    /// Continuation to resume the waiting task when the semaphore is signaled.
    /// This is set after the continuation is created.
    var continuation: CheckedContinuation<Void, Error>?
    
    init(continuation: CheckedContinuation<Void, Error>? = nil) {
        self.continuation = continuation
    }
    
    /// Cancels the waiter, resuming the continuation with a CancellationError if it exists.
    /// This method ensures that the waiter can only be cancelled once.
    mutating func cancel() {
        // ensure that we only cancel once
        guard !isCancelled else { return }
        isCancelled = true
        continuation?.resume(throwing: CancellationError())
    }
}