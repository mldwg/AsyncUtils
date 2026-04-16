//
//  Ticket.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 05.06.25.
//

import Foundation

/// An opaque token that uniquely identifies a task added to a `TaskQueue`.
/// Returned by `TaskQueue.add` and can be passed to `TaskQueue.cancel(_:)` to cancel that specific task.
public final class Ticket: Identifiable, Hashable, Equatable {
#if DEBUG
    private var debugID: UUID = UUID()
#endif
    
    public static func == (lhs: Ticket, rhs: Ticket) -> Bool {
        return lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#if DEBUG
extension Ticket: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "Ticket(\(debugID.uuidString))"
    }
}
#endif
