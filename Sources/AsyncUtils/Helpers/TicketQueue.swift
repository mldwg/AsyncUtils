//
//  TicketQueue.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 16.04.26.
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

/// A doubly-linked-list FIFO queue of `Ticket` values.
///
/// Compared to `Deque`, this implementation provides O(1) removal at any `Index` obtained via
/// the `Collection` conformance, which `TaskQueue` uses to cancel queued-but-not-yet-started tasks
/// without having to scan the whole list.
///
/// - Important: Not thread-safe on its own. All access must be serialized externally
///   (in practice, by the `TaskQueue` or a comparable actor).
internal final class TicketQueue {

    /// A single node in the doubly-linked list.
    internal final class Node: @unchecked Sendable {
        let ticket: Ticket
        /// The next (newer) node, or `nil` if this is the tail.
        var next: Node?
        /// The previous (older) node. Unowned to avoid a retain cycle.
        unowned var prev: Node?

        init(ticket: Ticket) {
            self.ticket = ticket
        }
    }

    /// The oldest node (next to be dequeued), or `nil` when the queue is empty.
    private(set) var head: Node?
    /// The newest node (most recently enqueued), or `nil` when the queue is empty.
    private(set) var tail: Node?
    /// The number of tickets currently in the queue.
    private(set) var count: Int = 0

    /// `true` when the queue contains no tickets.
    var isEmpty: Bool {
        return count == 0
    }

    /// The ticket at the front of the queue (next to be dequeued), without removing it.
    var first: Ticket? {
        return head?.ticket
    }

    /// The ticket at the back of the queue (most recently enqueued), without removing it.
    var last: Ticket? {
        return tail?.ticket
    }

    /// Appends `ticket` to the back of the queue.
    /// - Complexity: O(1).
    @discardableResult
    func enqueue(_ ticket: Ticket) -> Node {
        let newNode = Node(ticket: ticket)
        enqueue(node: newNode)
        return newNode
    }

    /// Appends `node` to the back of the queue.
    /// - Complexity: O(1).
    func enqueue(node: Node) {
        if let tail = tail {
            tail.next = node
            node.prev = tail
        } else {
            head = node
        }
        tail = node
        count += 1
    }

    /// Removes and returns the ticket at the front of the queue, or `nil` if empty.
    /// - Complexity: O(1).
    @discardableResult
    func dequeue() -> Ticket? {
        guard let head: TicketQueue.Node = head else { return nil }
        self.head = head.next
        self.head?.prev = nil
        if self.head == nil {
            tail = nil
        }
        count -= 1
        head.next = nil
        return head.ticket
    }

    /// Removes the given node from the queue and returns its ticket.
    /// - Complexity: O(1).
    @discardableResult
    func remove(_ node: Node) -> Ticket {
        if node === head {
            return dequeue()!
        } else if node === tail {
            tail = node.prev
            tail?.next = nil
            node.prev = nil
            count -= 1
            return node.ticket
        } else {
            let prevNode = node.prev
            let nextNode = node.next
            prevNode?.next = nextNode
            nextNode?.prev = prevNode
            count -= 1
            node.prev = nil
            node.next = nil
            return node.ticket
        }
    }

    func isEnqueued(_ node: Node) -> Bool {
        return node.prev != nil || node.next != nil || head === node
    }
}

// MARK: - Collection

extension TicketQueue: Collection {
    typealias Element = Ticket

    /// An index into `TicketQueue` that wraps the underlying `Node` pointer.
    /// Comparisons use the integer position, while equality uses node identity so that
    /// `endIndex` compares correctly regardless of position value.
    struct Index: Comparable {
        fileprivate let node: Node?
        fileprivate let value: Int

        static func < (lhs: Index, rhs: Index) -> Bool {
            return lhs.value < rhs.value
        }

        static func == (lhs: Index, rhs: Index) -> Bool {
            return lhs.node === rhs.node
        }
    }

    var startIndex: Index { return Index(node: head, value: 0) }
    var endIndex: Index { return Index(node: nil, value: count) }

    func index(after i: Index) -> Index {
        return Index(node: i.node?.next, value: i.value + 1)
    }

    subscript(position: Index) -> Element {
        return position.node!.ticket
    }

    /// Removes the element at `index` in O(1) by relinking its neighbours.
    /// Removing the head delegates to `dequeue()`; removing the tail unlinks the last node directly.
    @discardableResult
    func remove(at index: Index) -> Element {
        return remove(index.node!)
    }
}
