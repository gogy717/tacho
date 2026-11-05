import SwiftUI
import Testing
@testable import Tacho

/// The layout matrix's check of drawn text, on cases whose answer is known: a check that cannot fail proves nothing.
@MainActor @Suite(.serialized)
struct DrawnTextTests {
    private struct Texts {
        var first: String
        var second: String
    }

    private static func both(_ texts: inout Texts, _ visit: (inout String) -> Void) {
        visit(&texts.first)
        visit(&texts.second)
    }

    @Test func aTextThatFitsIsDrawnWhole() async {
        let report = await DrawnText.check(Texts(first: "≈ 100%", second: "Claude Code"), strings: Self.both, width: 300) { texts in
            VStack(alignment: .leading) {
                Text(texts.first)
                Text(texts.second)
            }
        }
        #expect(report.missing.isEmpty)
        #expect(report.strays == 0)
    }

    @Test func aTextCutOffAtItsEndIsFound() async {
        let report = await DrawnText.check(Texts(first: "≈ 100%", second: "meta-llama/llama-4-maverick-17b"), strings: Self.both, width: 300) { texts in
            VStack(alignment: .leading) {
                Text(texts.first)
                Text(texts.second).lineLimit(1).frame(width: 90, alignment: .leading)
            }
        }
        // Its middle is past the cut as well.
        #expect(report.missing == ["'meta-llama/llama-4-maverick-17b' (last)", "'meta-llama/llama-4-maverick-17b' (middle)"])
    }

    @Test func aTextCutInTheMiddleIsFound() async {
        let report = await DrawnText.check(Texts(first: "≈ 100%", second: "meta-llama/llama-4-maverick-17b-128e-instruct"), strings: Self.both, width: 300) { texts in
            VStack(alignment: .leading) {
                Text(texts.first)
                Text(texts.second).lineLimit(1).truncationMode(.middle).frame(width: 120, alignment: .leading)
            }
        }
        #expect(report.missing == ["'meta-llama/llama-4-maverick-17b-128e-instruct' (middle)"])
    }

    @Test func aTextPushedOutOfTheViewIsFound() async {
        let report = await DrawnText.check(Texts(first: "$1,234.56", second: "Cache read"), strings: Self.both, width: 200) { texts in
            HStack(spacing: 40) {
                Text(texts.second).fixedSize()
                Text(texts.first).font(.system(size: 36)).fixedSize()
            }
            .frame(width: 200, alignment: .leading)
        }
        #expect(report.missing.contains { $0.hasPrefix("'$1,234.56'") })
    }

    @Test func aWrappedTextIsDrawnWhole() async {
        let long = "At this pace it empties about Tuesday 12:58 am, 2 h 16 min before it resets"
        let report = await DrawnText.check(Texts(first: long, second: "x"), strings: Self.both, width: 160) { texts in
            VStack(alignment: .leading) {
                Text(texts.first)
                Text(texts.second)
            }
        }
        #expect(report.missing.isEmpty)
        #expect(report.strays == 0)
    }
}
