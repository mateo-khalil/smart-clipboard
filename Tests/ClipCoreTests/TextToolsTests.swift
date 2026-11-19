import Foundation
import Testing
@testable import ClipCore

@Suite struct TextToolsTests {
    @Test func normalizationIgnoresCaseAndAccents() {
        #expect(TextTools.normalize("CANCIÓN Ñandú") == "cancion nandu")
    }

    @Test func displayTitleMatchesMaccySymbols() {
        #expect(TextTools.displayTitle("Claude/Anthropic ", specialSymbols: true) == "Claude/Anthropic·")
        #expect(TextTools.displayTitle("a\n    b\tc", specialSymbols: true) == "a⏎    b⇥c")
        #expect(TextTools.displayTitle("  a\nb ", specialSymbols: false) == "a b")
        #expect(TextTools.displayTitle("    ", specialSymbols: true) == "····")
    }

    @Test func titleKeepsBothEndsOfLongText() {
        let text = String(repeating: "a", count: 200) + "MID" + String(repeating: "z", count: 200)
        let title = TextTools.title(head: text)
        #expect(title.hasPrefix("aaa"))
        #expect(title.hasSuffix("zzz"))
        #expect(title.contains("…"))
        #expect(title.count <= TextTools.titleLimit + 1)
        #expect(TextTools.title(head: "short") == "short")
    }

    @Test func decodeHeadNeverSplitsMultibyteCharacters() {
        let data = Data(String(repeating: "ñ", count: 10).utf8)
        let head = TextTools.decodeHead(data, limit: 5)
        #expect(head == "ññ")
        let tail = TextTools.decodeTail(data, limit: 5)
        #expect(tail == "ññ")
    }

    @Test func hexColorsMatchTheScreenshotExamples() {
        #expect(TextTools.hexColor("142999") == 0x142999FF)
        #expect(TextTools.hexColor("#142999") == 0x142999FF)
        #expect(TextTools.hexColor("2836") == 0x22883366)
        #expect(TextTools.hexColor("#fff") == 0xFFFFFFFF)
        #expect(TextTools.hexColor("11223344") == 0x11223344)
    }

    @Test func nonColorsAreRejected() {
        #expect(TextTools.hexColor("hello") == nil)
        #expect(TextTools.hexColor("12345") == nil)
        #expect(TextTools.hexColor("+123") == nil)
        #expect(TextTools.hexColor("") == nil)
    }

    @Test func detectsLoneURLs() {
        #expect(TextTools.looksLikeSingleURL("https://a.com/b.png\n"))
        #expect(!TextTools.looksLikeSingleURL("see https://a.com"))
    }

    @Test func filePathsAreAbbreviatedAndDecoded() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home + "/My File.txt").absoluteString
        #expect(TextTools.displayPath(fileURL: url) == "~/My File.txt")
    }
}

@Suite struct IgnoreRulesTests {
    @Test func concealedCopiesAreAlwaysIgnored() {
        #expect(IgnoreRules().ignores(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!IgnoreRules().ignores(types: ["public.utf8-plain-text"]))
    }

    @Test func appListCanBeInverted() {
        var rules = IgnoreRules(apps: ["com.a"])
        #expect(rules.ignores(app: "com.a"))
        #expect(!rules.ignores(app: "com.b"))
        #expect(!rules.ignores(app: nil))
        rules.onlyListedApps = true
        #expect(!rules.ignores(app: "com.a"))
        #expect(rules.ignores(app: "com.b"))
        #expect(rules.ignores(app: nil))
    }

    @Test func brokenPatternsDoNotBlockCopies() {
        let rules = IgnoreRules(patterns: ["(", "secret-\\d+"])
        #expect(rules.ignores(text: "my secret-42"))
        #expect(!rules.ignores(text: "public"))
    }
}

@Suite struct MatcherTests {
    private func score(_ query: String, _ text: String) -> Int? {
        Array(query.utf8).withUnsafeBufferPointer { q in
            Array(text.utf8).withUnsafeBufferPointer { t in FuzzyMatcher.score(query: q, text: t) }
        }
    }

    @Test func fuzzyRequiresEveryByteInOrder() {
        #expect(score("skt", "sudo launchctl bootout") == nil)
        #expect(score("slb", "sudo launchctl bootout") != nil)
        #expect(score("abc", "") == nil)
    }

    @Test func fuzzyPrefersConsecutiveAndBoundaryMatches() {
        #expect(score("boot", "sudo bootout")! > score("boot", "bxoxoxt")!)
    }

    @Test func topScoresKeepsBestAndRecencyOnTies() {
        var top = TopScores(capacity: 2)
        top.offer(score: 5, id: 1)
        top.offer(score: 9, id: 2)
        top.offer(score: 5, id: 3)
        top.offer(score: 7, id: 4)
        #expect(top.entries.map(\.id) == [2, 4])
        var ties = TopScores(capacity: 3)
        ties.offer(score: 1, id: 1)
        ties.offer(score: 1, id: 2)
        #expect(ties.entries.map(\.id) == [1, 2])
    }

    @Test func cancelTokenFlips() {
        let token = CancelToken()
        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
    }
}
