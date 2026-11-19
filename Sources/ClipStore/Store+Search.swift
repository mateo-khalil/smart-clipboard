import ClipCore
import Foundation

extension Store {
    /// Runs on the reader queue and walks the history row by row without
    /// loading it. Exact and Regexp stop at `limit`; Fuzzy must see every row
    /// to rank them, and all modes stop as soon as `token` is cancelled.
    public func search(
        query: String, mode: SearchMode, sort: HistorySort, limit: Int, token: CancelToken = CancelToken()
    ) -> [ClipRow] {
        guard !query.isEmpty else { return [] }
        let ids: [Int64]
        switch mode {
        case .exact: ids = exact(query, sort: sort, limit: limit, token: token)
        case .fuzzy: ids = fuzzy(query, sort: sort, limit: limit, token: token)
        case .regexp: ids = regexp(query, sort: sort, limit: limit, token: token)
        case .mixed:
            var found = exact(query, sort: sort, limit: limit, token: token)
            if found.isEmpty, !token.isCancelled { found = regexp(query, sort: sort, limit: limit, token: token) }
            if found.isEmpty, !token.isCancelled { found = fuzzy(query, sort: sort, limit: limit, token: token) }
            ids = found
        }
        return token.isCancelled ? [] : rows(ids: ids)
    }

    private func walk(column: String, sort: HistorySort, token: CancelToken, visit: (Statement, Int64) -> Bool) {
        readQueue.sync {
            let key = Self.column(for: sort)
            guard let cursor = try? reader.statement("""
            SELECT i.id, s.\(column) FROM items i JOIN search s ON s.item_id=i.id
            WHERE length(s.\(column)) > 0
            ORDER BY i.\(key) DESC, i.id DESC
            """) else { return }
            while !token.isCancelled, (try? cursor.step()) == true {
                if !visit(cursor, cursor.int(0)) { return }
            }
        }
    }

    private func exact(_ query: String, sort: HistorySort, limit: Int, token: CancelToken) -> [Int64] {
        let needle = Array(TextTools.normalize(query).utf8)
        guard !needle.isEmpty else { return [] }
        var ids: [Int64] = []
        walk(column: "normalized", sort: sort, token: token) { cursor, id in
            let found = cursor.withTextBytes(1) { text in
                guard let base = text.baseAddress else { return false }
                return needle.withUnsafeBytes { memmem(base, text.count, $0.baseAddress, $0.count) != nil }
            }
            if found { ids.append(id) }
            return ids.count < limit
        }
        return ids
    }

    private func fuzzy(_ query: String, sort: HistorySort, limit: Int, token: CancelToken) -> [Int64] {
        let needle = Array(TextTools.normalize(query).utf8)
        var best = TopScores(capacity: limit)
        needle.withUnsafeBufferPointer { pattern in
            walk(column: "normalized", sort: sort, token: token) { cursor, id in
                if let score = cursor.withTextBytes(1, { FuzzyMatcher.score(query: pattern, text: $0) }) {
                    best.offer(score: score, id: id)
                }
                return true
            }
        }
        return best.entries.map(\.id)
    }

    private func regexp(_ pattern: String, sort: HistorySort, limit: Int, token: CancelToken) -> [Int64] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var ids: [Int64] = []
        walk(column: "raw", sort: sort, token: token) { cursor, id in
            guard let text = cursor.string(1) else { return true }
            var matched = false
            let range = NSRange(location: 0, length: (text as NSString).length)
            // `.reportProgress` lets a pathological pattern notice the cancellation.
            regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { result, _, stop in
                if result != nil { matched = true }
                if matched || token.isCancelled { stop.pointee = true }
            }
            if matched { ids.append(id) }
            return ids.count < limit
        }
        return ids
    }
}
