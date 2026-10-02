import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

struct HistorySearchQueryCompilerTests {
    @Test func outsideDollarEscapesKeepRegexpMeaningBesideWrappedConditions() throws {
        let pattern = #"\$\d+$"#
        let plain = try HistorySearchQueryCompiler.compile(pattern, mode: .regexp)
        let mixed = try HistorySearchQueryCompiler.compile(pattern + " $type:text$", mode: .regexp)
        #expect(plain.literalText == pattern)
        #expect(plain.expression == nil)
        #expect(mixed.literalText == pattern)
        #expect(mixed.expression == (try HistorySearchExpression.parse("type:text")))
        let matcher = try NSRegularExpression(pattern: mixed.literalText)
        #expect(matcher.firstMatch(in: "$20", range: NSRange(location: 0, length: 3)) != nil)
        #expect(matcher.firstMatch(in: "20", range: NSRange(location: 0, length: 2)) == nil)
        #expect(matcher.firstMatch(in: "$20 suffix", range: NSRange(location: 0, length: 10)) == nil)
        let anchored = try HistorySearchQueryCompiler.compile("^report$ $type:text$", mode: .regexp)
        #expect(anchored.literalText == "^report$")
        #expect(anchored.expression == mixed.expression)
        let inline = try HistorySearchQueryCompiler.compile("report$ty$", mode: .regexp)
        #expect(inline.literalText == "report$ty$")
        #expect(inline.expression == nil)
        let unicodeSeparator = try HistorySearchQueryCompiler.compile("^report$\u{3000}$type:text$", mode: .regexp)
        #expect(unicodeSeparator.literalText == "^report$")
        #expect(unicodeSeparator.expression == mixed.expression)
        for mode in [SearchMode.exact, .fuzzy] {
            let literal = try HistorySearchQueryCompiler.compile(#"\$20"#, mode: mode)
            #expect(literal.literalText == "$20")
            #expect(literal.expression == nil)
        }
        let unfinished = #"$pending \$20"#
        let editing = try HistorySearchQueryCompiler.compile(unfinished, mode: .regexp)
        #expect(editing.literalText == unfinished)
        #expect(editing.expression == nil)
    }
    @Test(arguments: [
        "source:Safari", "app:Notes", "source-id:com.apple.Safari", "type:text",
        "is:pinned", "before:2026-09-30", "NOT source:Safari OR type:images"
    ])
    func bareSyntaxRemainsText(_ input: String) throws {
        let result = try HistorySearchQueryCompiler.compile(input)

        #expect(result.literalText.utf8.elementsEqual(input.utf8))
        #expect(result.expressionText == nil)
        #expect(result.expression == nil)
    }

    @Test func mixedTextKeepsItsModeIndependentFromConditionGrouping() throws {
        let result = try HistorySearchQueryCompiler.compile("笔记 $source:Safari OR source:Notes$ 收据")
        let expected = try HistorySearchExpression.parse("source:Safari OR source:Notes")

        #expect(result.literalText == "笔记 收据")
        #expect(result.expression == expected)
        #expect(result.expression?.applicationTerms == ["Safari", "Notes"])
        let text = try #require(result.expressionText)
        #expect(try HistorySearchExpression.parse(text) == expected)
    }

    @Test func multipleBlocksAreAndedWithoutFlatteningTheirOrGroups() throws {
        let result = try HistorySearchQueryCompiler.compile(
            "$source:Safari OR source:Notes$  $NOT type:images$"
        )
        let expected = try HistorySearchExpression.parse(
            "(source:Safari OR source:Notes) AND (NOT type:images)"
        )

        #expect(result.literalText.isEmpty)
        #expect(result.expression == expected)
        let text = try #require(result.expressionText)
        #expect(try HistorySearchExpression.parse(text) == expected)
    }

    @Test(arguments: ["", " \t\r\n\u{3000}"])
    func emptyBlocksHaveUsableExpressionTextAloneAndBesideOtherConditions(_ whitespace: String) throws {
        let block = "$" + whitespace + "$"
        let sole = try HistorySearchQueryCompiler.compile(block)
        let mixed = try HistorySearchQueryCompiler.compile(block + " $source:Safari OR source:Notes$")

        #expect(sole.literalText.isEmpty)
        #expect(sole.expressionText == "type:all")
        #expect(sole.expression == (try HistorySearchExpression.parse("type:all")))
        #expect(mixed.expressionText == "(type:all) AND (source:Safari OR source:Notes)")
        #expect(mixed.expression == (try HistorySearchExpression.parse(
            "type:all AND (source:Safari OR source:Notes)"
        )))
        #expect(mixed.expression?.applicationTerms == ["Safari", "Notes"])
    }

    @Test func soleBlockPreservesConditionAndApplicationNameUtf8Spelling() throws {
        let firstApplication = "Cafe\u{301} $Five"
        let secondApplication = "Café"
        let condition = "\t(source:\"" + firstApplication + "\" OR source:\"" + secondApplication + "\")\n "
        let result = try HistorySearchQueryCompiler.compile("笔记 $" + condition + "$ 收据")
        let expressionText = try #require(result.expressionText)
        let applications = try #require(result.expression?.applicationTerms)

        #expect(result.literalText == "笔记 收据")
        #expect(expressionText.utf8.elementsEqual(condition.utf8))
        try #require(applications.count == 2)
        #expect(applications[0].utf8.elementsEqual(firstApplication.utf8))
        #expect(applications[1].utf8.elementsEqual(secondApplication.utf8))
    }

    @Test func removingBlocksSeparatesWordsWithoutChangingInteriorWhitespace() throws {
        let result = try HistorySearchQueryCompiler.compile(
            "  first  word$source:Safari$second\tword $is:pinned$ "
        )

        #expect(result.literalText == "first  word second\tword")
        #expect(result.expression == (try HistorySearchExpression.parse("source:Safari AND is:pinned")))
    }

    @Test func escapedDelimitersStayLiteralAndOtherBackslashesSurvive() throws {
        let result = try HistorySearchQueryCompiler.compile(#"\$source:Safari\$ \n \"quoted\" \\ keep \$5"#)
        let expected = #"$source:Safari$ \n \"quoted\" \\ keep $5"#

        #expect(result.literalText.utf8.elementsEqual(expected.utf8))
        #expect(result.expression == nil)
    }

    @Test func twoOutsideBackslashesStillProtectTheImmediatelyFollowingDollar() throws {
        let result = try HistorySearchQueryCompiler.compile(#"\\$source:Safari\$"#)
        let expected = #"\$source:Safari$"#

        #expect(result.literalText.utf8.elementsEqual(expected.utf8))
        #expect(result.expression == nil)
    }

    @Test func quotedDollarAndDslEscapesDoNotCloseACondition() throws {
        let result = try HistorySearchQueryCompiler.compile(#"$source:"A\"$B\\C"$"#)

        #expect(result.literalText.isEmpty)
        #expect(result.expression?.applicationTerms == [#"A"$B\C"#])
    }

    @Test func escapedDollarInAConditionIsDecodedBeforeRawDslParsing() throws {
        let result = try HistorySearchQueryCompiler.compile(#"$source:Price\$Five$"#)

        #expect(result.expression?.applicationTerms == ["Price$Five"])
        #expect(result.literalText.isEmpty)
    }

    @Test(arguments: ["笔记 $source:Safari", "$source:\"embedded $ and tail$", "trailing$"])
    func unclosedBlockRemainsEditableTextIncludingItsLastByte(_ input: String) throws {
        let result = try HistorySearchQueryCompiler.compile(input)

        #expect(result.literalText.utf8.elementsEqual(input.utf8))
        #expect(result.expression == nil)
    }

    @Test func completedBlockStillAppliesWhileTheFinalBlockIsBeingTyped() throws {
        let result = try HistorySearchQueryCompiler.compile("$source:Safari$ 笔记 $type:images👩🏽‍💻")

        #expect(result.literalText == "笔记 $type:images👩🏽‍💻")
        #expect(result.expression == (try HistorySearchExpression.parse("source:Safari")))
    }

    @Test func closedInvalidConditionsReportTheirParserFailure() {
        #expect(throws: HistorySearchExpressionError(reason: .invalidType, offset: 4)) {
            try HistorySearchQueryCompiler.compile("笔记 $type:unknown$")
        }
        #expect(throws: HistorySearchExpressionError(reason: .missingValue, offset: 1)) {
            try HistorySearchQueryCompiler.compile("$source:$")
        }
    }

    @Test func conditionDiagnosticsPointIntoTheRawQueryAfterEscapesAndUnicode() throws {
        let input = #"👩🏽‍💻 é 笔记 $source:"cash\$ and \\ \"quote\"" AND type:unknown$"#
        let range = try #require(input.range(of: "type:unknown"))
        let expectedOffset = input.distance(from: input.startIndex, to: range.lowerBound)

        #expect(throws: HistorySearchExpressionError(reason: .invalidType, offset: expectedOffset)) {
            try HistorySearchQueryCompiler.compile(input)
        }
    }

    @Test func aMissingFinalOperandPointsToTheOriginalClosingDelimiter() {
        let input = "笔记 $source:Safari OR$"

        #expect(throws: HistorySearchExpressionError(reason: .expectedTerm, offset: input.count - 1)) {
            try HistorySearchQueryCompiler.compile(input)
        }
    }

    @Test func numericPricesRemainTextBesideRealConditions() throws {
        let price = try HistorySearchQueryCompiler.compile("报价 $10$、$10.50$，保存 $ １２３ $")
        let mixed = try HistorySearchQueryCompiler.compile("报价 $10$ $source:Safari$")

        #expect(price.literalText == "报价 $10$、$10.50$，保存 $ １２３ $")
        #expect(price.expression == nil)
        #expect(mixed.literalText == "报价 $10$")
        #expect(mixed.expression?.applicationTerms == ["Safari"])
    }

    @Test(arguments: ["$10 and $20", "$10 and $２０", "$source:Safari$123"])
    func aDollarBeforeADecimalDigitDoesNotCloseACondition(_ input: String) throws {
        let result = try HistorySearchQueryCompiler.compile(input)

        #expect(result.literalText.utf8.elementsEqual(input.utf8))
        #expect(result.expression == nil)
    }

    @Test func unwrappedUnicodePreservesItsExactUtf8Spelling() throws {
        let input = "👩🏽‍💻 笔记 e\u{301} \u{E9}"
        let result = try HistorySearchQueryCompiler.compile(input)
        let mixed = try HistorySearchQueryCompiler.compile(input + " $source:Safari$")

        #expect(result.literalText.utf8.elementsEqual(input.utf8))
        #expect(mixed.literalText.utf8.elementsEqual(input.utf8))
    }

    @Test func oversizedUnwrappedTextSurvivesForTheCallersExistingModeAdmission() throws {
        let limit = HistoryLimits.standard.maximumSearchTermUTF8Bytes
        let accepted = String(repeating: "a", count: limit)
        let result = try HistorySearchQueryCompiler.compile(accepted)
        let largeText = String(repeating: "a", count: 1_000_000)
        let large = try HistorySearchQueryCompiler.compile(largeText)
        let multibyteText = String(repeating: "界", count: limit / 3) + "é"
        let multibyte = try HistorySearchQueryCompiler.compile(multibyteText)

        #expect(result.literalText.utf8.elementsEqual(accepted.utf8))
        #expect(large.literalText.utf8.elementsEqual(largeText.utf8))
        #expect(large.expression == nil)
        #expect(multibyte.literalText.utf8.elementsEqual(multibyteText.utf8))
        #expect(multibyte.expression == nil)
    }

    @Test func oversizedTextContainingADollarNeverDropsItsFinalCondition() {
        let limit = HistoryLimits.standard.maximumSearchTermUTF8Bytes
        let prefix = String(repeating: "a", count: limit + 1)

        #expect(throws: HistorySearchExpressionError(reason: .queryTooLong, offset: 0)) {
            try HistorySearchQueryCompiler.compile(prefix + " $source:Safari$")
        }
        #expect(throws: HistorySearchExpressionError(reason: .queryTooLong, offset: 0)) {
            try HistorySearchQueryCompiler.compile(prefix + #"\$"#)
        }
    }

    @Test func combinedConditionSourceIsBudgetedBeforeItsAstIsConstructed() {
        let limit = HistoryLimits.standard.maximumSearchTermUTF8Bytes
        let input = "$" + String(repeating: "a", count: limit - 6) + "$$b$"

        #expect(throws: HistorySearchExpressionError(reason: .queryTooLong, offset: 0)) {
            try HistorySearchQueryCompiler.compile(input)
        }
    }

    @Test func soleBlockRetainsTheRawParsersFullNestingAllowance() throws {
        let expression = String(repeating: "(", count: 16) + "type:text"
            + String(repeating: ")", count: 16)
        let result = try HistorySearchQueryCompiler.compile("$" + expression + "$")

        #expect(result.expression == (try HistorySearchExpression.parse(expression)))
    }

    @Test func artificialCombinedGroupingDiagnosticsPointToARealBlockOpening() {
        let expression = String(repeating: "(", count: 16) + "type:text"
            + String(repeating: ")", count: 16)
        let input = "笔记 $" + expression + "$ $is:pinned$"

        #expect(throws: HistorySearchExpressionError(reason: .tooDeep, offset: 3)) {
            try HistorySearchQueryCompiler.compile(input)
        }
    }
}
