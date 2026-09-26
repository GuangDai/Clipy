/// Expression search grammar and caller-visible diagnostics.
/// Owning spec: docs/03a-instruction-set.md §7.
import Foundation
import Testing
@testable import HistoryCore

@Test func expressionSearchPrecedenceIsNotThenAndThenOr() throws {
    let expression = try HistorySearchExpression.parse("alpha OR beta AND NOT gamma")

    #expect(expression.root == .or(.text("alpha"), .and(.text("beta"), .not(.text("gamma")))))
    #expect(expression == (try HistorySearchExpression.parse("alpha OR (beta AND (NOT gamma))")))
    #expect(expression != (try HistorySearchExpression.parse("(alpha OR beta) AND NOT gamma")))
}

@Test func expressionSearchAdjacentConditionsUseAndWithTheSamePrecedence() throws {
    let implicit = try HistorySearchExpression.parse("alpha beta OR gamma NOT delta")
    let explicit = try HistorySearchExpression.parse("alpha AND beta OR gamma AND NOT delta")

    #expect(implicit == explicit)
    #expect(implicit.root == .or(
        .and(.text("alpha"), .text("beta")),
        .and(.text("gamma"), .not(.text("delta")))
    ))
}

@Test func expressionSearchOperatorsIgnoreCaseButQuotedOperatorsRemainText() throws {
    let lowercase = try HistorySearchExpression.parse("alpha or beta aNd not gamma")
    let uppercase = try HistorySearchExpression.parse("alpha OR beta AND NOT gamma")
    let quoted = try HistorySearchExpression.parse("\"AND\" \"OR\" \"NOT\"")

    #expect(lowercase == uppercase)
    #expect(quoted.root == .and(.and(.text("AND"), .text("OR")), .text("NOT")))
}

@Test(arguments: [
    "a phrase with spaces",
    "AND OR NOT (app:safari)",
    "He said \"hello\"",
    #"C:\Users\clipboard"#,
    "主题 😀 e\u{301}",
    "line one\nline two"
])
func expressionSearchQuotedLiteralRoundTripsWithoutInterpretingSyntax(literal: String) throws {
    let expression = try HistorySearchExpression.parse(HistorySearchExpression.quoted(literal))

    #expect(expression.root == .text(literal))
}

@Test func expressionSearchRecognizesMetadataAlongsideText() throws {
    let expression = try HistorySearchExpression.parse(
        "app:\"Safari Technology Preview\" (type:images OR type:links) NOT is:pinned"
    )

    #expect(expression.root == .and(
        .and(
            .application("Safari Technology Preview"),
            .or(.type(.images), .type(.links))
        ),
        .not(.pinned)
    ))
}

@Test func expressionSearchSourceAliasCombinesApplicationsWithDatesAndExclusions() throws {
    let expression = try HistorySearchExpression.parse(
        "(source:Telegram or source:Brave) date:2026-09-26 NOT type:images"
    )
    let applicationSpelling = try HistorySearchExpression.parse(
        "(app:Telegram OR app:Brave) date:2026-09-26 AND NOT type:images"
    )

    #expect(expression == applicationSpelling)
    #expect(expression.root == .and(
        .and(
            .or(.application("Telegram"), .application("Brave")),
            .copiedDate(
                from: Date(timeIntervalSince1970: 1_790_380_800),
                until: Date(timeIntervalSince1970: 1_790_467_200)
            )
        ),
        .not(.type(.images))
    ))
}

@Test func expressionSearchAcceptsSingularContentTypeAliases() throws {
    #expect(try HistorySearchExpression.parse("type:image").root == .type(.images))
    #expect(try HistorySearchExpression.parse("type:link").root == .type(.links))
}

@Test func expressionSearchEnumeratesOnlyUnresolvedApplicationTermsInQueryOrder() throws {
    let expression = try HistorySearchExpression.parse(
        "source:Telegram OR (app:Brave NOT source:\"Safari Technology Preview\") source-id:com.example.app \"source:literal\""
    )

    #expect(expression.applicationTerms == ["Telegram", "Brave", "Safari Technology Preview"])
    #expect(expression.replacingApplicationTerms { _ in nil } == expression)
}

@Test func expressionSearchReplacesNamesWithExactAlternativesInsideNegatedGroups() throws {
    let expression = try HistorySearchExpression.parse("source:Telegram NOT source:Brave")
    let resolved = expression.replacingApplicationTerms { name in
        switch name {
        case "Telegram": ["org.telegram.desktop", "ru.keepcoder.Telegram"]
        case "Brave": ["com.brave.Browser", "com.brave.Browser.beta"]
        default: nil
        }
    }

    #expect(resolved.root == .and(
        .or(.sourceID("org.telegram.desktop"), .sourceID("ru.keepcoder.Telegram")),
        .not(.or(.sourceID("com.brave.Browser"), .sourceID("com.brave.Browser.beta")))
    ))
    #expect(resolved.applicationTerms.isEmpty)
    #expect(try HistorySearchExpression.parse(resolved.serialized) == resolved)
}

@Test func expressionSearchEmptyResolutionStaysFalseWhenSerializedAndRespectsNot() throws {
    let expression = try HistorySearchExpression.parse("source:Missing NOT app:Other")
    let resolved = expression.replacingApplicationTerms { _ in [] }
    let reparsed = try HistorySearchExpression.parse(resolved.serialized)

    #expect(resolved.root == .and(.noMatch, .not(.noMatch)))
    #expect(reparsed.root == .and(.not(.type(.all)), .not(.not(.type(.all)))))
    #expect(resolved.applicationTerms.isEmpty)
}

@Test func expressionSearchExactSourceIdentifierPreservesQuotedSyntaxLiterally() throws {
    let identifier = #"com.example.AND (source:Other) "quoted" \path"#
    let expression = try HistorySearchExpression.parse(
        "source-id:" + HistorySearchExpression.quoted(identifier)
    )
    var lookupCount = 0
    let resolved = expression.replacingApplicationTerms { _ in
        lookupCount += 1
        return []
    }

    #expect(expression.root == .sourceID(identifier))
    #expect(expression.applicationTerms.isEmpty)
    #expect(lookupCount == 0)
    #expect(resolved == expression)
    #expect(try HistorySearchExpression.parse(expression.serialized) == expression)
}

@Test(arguments: [
    "(source:Telegram OR source:Brave) NOT (type:images OR is:pinned)",
    "date:2026-09-26..2026-10-01 before:2026-10-02 after:2026-09-25",
    Array(repeating: "word", count: 20).joined(separator: " "),
    String(repeating: "NOT ", count: 16) + "word"
])
func expressionSearchSerializationPreservesGroupingWithoutAddingExcessiveNesting(text: String) throws {
    let expression = try HistorySearchExpression.parse(text)
    let reparsed = try HistorySearchExpression.parse(expression.serialized)

    #expect(reparsed == expression)
}

@Test(arguments: ["https://example.com/notes", "project:clipy", "12:30"])
func expressionSearchPreservesUnrecognizedColonTermsAsText(literal: String) throws {
    let expression = try HistorySearchExpression.parse(literal)

    #expect(expression.root == .text(literal))
}

@Test func expressionSearchDatesUseUTCMidnightAndIncludeTheFinalRangeDay() throws {
    let day = try HistorySearchExpression.parse("date:2026-09-26")
    let range = try HistorySearchExpression.parse("date:2026-09-26..2026-10-01")
    let after = try HistorySearchExpression.parse("after:2026-09-26")
    let before = try HistorySearchExpression.parse("before:2026-10-01")
    let start = Date(timeIntervalSince1970: 1_790_380_800)

    #expect(day.root == .copiedDate(
        from: start,
        until: Date(timeIntervalSince1970: 1_790_467_200)
    ))
    #expect(range.root == .copiedDate(
        from: start,
        until: Date(timeIntervalSince1970: 1_790_899_200)
    ))
    #expect(after.root == .copiedDate(from: start, until: nil))
    #expect(before.root == .copiedDate(
        from: nil,
        until: Date(timeIntervalSince1970: 1_790_812_800)
    ))
}

@Test func expressionSearchAcceptsLeapDayWithoutNormalizingInvalidCalendarDates() throws {
    let leapDay = try HistorySearchExpression.parse("date:2024-02-29")

    #expect(leapDay.root == .copiedDate(
        from: Date(timeIntervalSince1970: 1_709_164_800),
        until: Date(timeIntervalSince1970: 1_709_251_200)
    ))
    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse("date:2026-02-29")
    }
}

@Test(arguments: ["", "   ", "\n\t \r\n"])
func expressionSearchBlankInputMatchesAll(text: String) throws {
    #expect(try HistorySearchExpression.parse(text).root == .all)
}

@Test(arguments: [
    "AND alpha", "alpha OR", "NOT", "()", "alpha )", "(alpha OR beta",
    "\"unterminated", "app:", "source:", "source-id:", "date:", "date:2026-13-01", "date:2026-04-31",
    "date:2026-9-26", "date:2026-10-01..2026-09-26", "before:yesterday",
    "after:2026-09-26..2026-10-01", "type:unknown", "is:unknown"
])
func expressionSearchRejectsIncompleteSyntaxAndInvalidKnownConditions(text: String) throws {
    let error = try #require(expressionSearchRejection(text))

    #expect(!error.message.isEmpty)
    #expect((0...text.count).contains(error.offset))
}

@Test func expressionSearchErrorsDistinguishMissingValuesFromCalendarAndSyntaxMistakes() throws {
    let missingValue = try #require(expressionSearchRejection("app:"))
    let invalidDate = try #require(expressionSearchRejection("date:2026-02-29"))
    let backwardsRange = try #require(expressionSearchRejection("date:2026-10-01..2026-09-26"))
    let openQuote = try #require(expressionSearchRejection("\"unterminated"))

    #expect(missingValue.reason == .missingValue)
    #expect(invalidDate.reason == .invalidDate)
    #expect(backwardsRange.reason == .invalidDateRange)
    #expect(openQuote.reason == .unclosedQuote)
    #expect(openQuote.offset == 0)
}

@Test func expressionSearchErrorOffsetCountsCharactersRatherThanUTF8Bytes() throws {
    let error = try #require(expressionSearchRejection("主题 AND )"))

    #expect(error.offset == 7)
}

@Test func expressionSearchUTF8LimitAcceptsTheBoundaryAndRejectsTheNextByte() throws {
    let exactBoundary = String(repeating: "é", count: 2_048)
    let expression = try HistorySearchExpression.parse(exactBoundary)

    #expect(expression.root == .text(exactBoundary))
    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse(exactBoundary + "a")
    }
}

@Test func expressionSearchTokenLimitIncludesOperators() throws {
    let implicitBoundary = Array(repeating: "word", count: 128).joined(separator: " ")
    let explicitBelowBoundary = Array(repeating: "word", count: 64).joined(separator: " AND ")
    _ = try HistorySearchExpression.parse(implicitBoundary)
    _ = try HistorySearchExpression.parse(explicitBelowBoundary)
    _ = try HistorySearchExpression.parse("NOT " + explicitBelowBoundary)

    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse(implicitBoundary + " word")
    }
    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse(explicitBelowBoundary + " AND word")
    }
}

@Test func expressionSearchBoundsParenthesisAndNotNesting() throws {
    let nestedBoundary = String(repeating: "(", count: 16) + "word" + String(repeating: ")", count: 16)
    let negationBoundary = String(repeating: "NOT ", count: 16) + "word"
    #expect(try HistorySearchExpression.parse(nestedBoundary).root == .text("word"))
    _ = try HistorySearchExpression.parse(negationBoundary)

    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse("(" + nestedBoundary + ")")
    }
    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse("NOT " + negationBoundary)
    }
    #expect(throws: HistorySearchExpressionError.self) {
        try HistorySearchExpression.parse("(" + negationBoundary + ")")
    }
}

private func expressionSearchRejection(_ text: String) -> HistorySearchExpressionError? {
    do {
        _ = try HistorySearchExpression.parse(text)
        Issue.record("Expected an expression syntax error for: \(text)")
    } catch {
        return error
    }
    return nil
}
