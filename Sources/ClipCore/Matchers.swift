import Foundation
import os

/// Lets a new keystroke stop the search that is still running.
public final class CancelToken: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isCancelled: Bool { flag.withLock { $0 } }
    public func cancel() { flag.withLock { $0 = true } }
}

public enum FuzzyMatcher {
    /// Scores `query` as a byte subsequence of `text`; both must already be
    /// normalized. Returns `nil` when some byte is missing.
    public static func score(query: UnsafeBufferPointer<UInt8>, text: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !query.isEmpty, query.count <= text.count,
              let base = text.baseAddress else { return nil }
        var position = 0
        var score = 0
        var first = -1
        var previous = -2
        for byte in query {
            let remaining = text.count - position
            guard remaining > 0, let hit = memchr(base + position, Int32(byte), remaining) else { return nil }
            let index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            if first < 0 { first = index }
            var gain = 16
            if index == previous + 1 { gain += 12 }
            if index == 0 || isBoundary(text[index - 1]) { gain += 8 }
            score += gain
            previous = index
            position = index + 1
        }
        let spread = previous - first + 1 - query.count
        return score - min(first, 32) - min(spread, 64)
    }

    private static func isBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, 0x2F, 0x2D, 0x5F, 0x2E: return true
        default: return false
        }
    }
}

/// Bounded best-first list. Ties keep insertion order, which is recency.
public struct TopScores {
    public private(set) var entries: [(score: Int, id: Int64)] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(capacity + 1)
    }

    public mutating func offer(score: Int, id: Int64) {
        if entries.count == capacity, let last = entries.last, score <= last.score { return }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].score >= score { low = middle + 1 } else { high = middle }
        }
        entries.insert((score, id), at: low)
        if entries.count > capacity { entries.removeLast() }
    }
}
