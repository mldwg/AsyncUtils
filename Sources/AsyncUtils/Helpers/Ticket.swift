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

import Foundation

/// An opaque token that uniquely identifies a task added to a `TaskQueue`.
/// Returned by `TaskQueue.add` and can be passed to `TaskQueue.cancel(_:)` to cancel that specific task.
final class Ticket: Identifiable, Hashable, Equatable, Sendable {
#if DEBUG
    private let debugID: UUID = UUID()
#endif
    
    static func == (lhs: Ticket, rhs: Ticket) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#if DEBUG
extension Ticket: CustomDebugStringConvertible {
    var debugDescription: String {
        return "Ticket(\(debugID.uuidString))"
    }
}
#endif
