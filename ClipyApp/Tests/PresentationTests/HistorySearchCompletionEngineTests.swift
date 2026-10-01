import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

struct HistorySearchCompletionEngineTests {
    @Test func regexpPatternDollarsDoNotOpenCandidatesAndExplicitConditionsUseASeparator() throws {
        let pattern = input("^report$ty|")
        #expect(HistorySearchCompletionEngine.context(for: pattern, mode: .regexp) == nil)
        let anchored = input("^report$|")
        let explicit = try #require(HistorySearchCompletionEngine.context(for: anchored, explicit: true, mode: .regexp))
        let field = try #require(HistorySearchCompletionEngine.candidates(for: explicit).first { $0.id == "type:" })
        #expect(replacing(anchored.text, with: field) == "^report$ $type:$")
        #expect(field.selectionOffset == 7)
        let inside = input("^report$\u{3000}$type:te|$")
        let context = try #require(HistorySearchCompletionEngine.context(for: inside, mode: .regexp))
        let text = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "type:text" })
        let applied = replacing(inside.text, with: text)
        let compilation = try HistorySearchQueryCompiler.compile(applied, mode: .regexp)
        #expect(compilation.literalText == "^report$")
        #expect(compilation.expression == (try HistorySearchExpression.parse("type:text")))
        #expect(HistorySearchCompletionEngine.context(for: pattern, mode: .exact) != nil)
    }
    @Test func ordinaryTextAndEmptyFocusLeaveHistoryArrowNavigationAvailable() throws {
        for draft in ["|", "source:Saf|", "普通🧪文字|", "$ |", #"\$ty|"#, #"\\$ty|"#] {
            #expect(HistorySearchCompletionEngine.context(for: input(draft)) == nil)
        }
        let ordinary = input("普通| 🧪文字")
        let context = try #require(HistorySearchCompletionEngine.context(for: ordinary, explicit: true))
        let choice = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "app:" })
        #expect(replacing(ordinary.text, with: choice) == "普通$app:$ 🧪文字")
        #expect(choice.selectionOffset == 5)
    }

    @Test func openingDollarOffersFieldsBeforeTheUserTypesAFieldName() throws {
        for draft in ["$|", "$|$", "notes $|"] {
            let current = input(draft)
            let context = try #require(HistorySearchCompletionEngine.context(for: current))
            let choice = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "type:" })
            let completed = replacing(current.text, with: choice)
            #expect(completed == (draft.hasPrefix("notes") ? "notes $type:$" : "$type:$"))
        }
        #expect(HistorySearchCompletionEngine.context(for: input("^report$|"), mode: .regexp) == nil)
        #expect(HistorySearchCompletionEngine.context(for: input("^report$ $|"), mode: .regexp) != nil)
    }

    @Test func aMiddleCaretReplacesTheWholeTermAndPreservesBothSurroundingTexts() throws {
        let draft = input("普通🧪文字 $ty|po OR app:\"浏览器\"$ 尾文")
        let context = try #require(HistorySearchCompletionEngine.context(for: draft))
        let choice = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "type:" })
        #expect(context.prefix == "ty")
        #expect((draft.text as NSString).substring(with: context.replacementRange) == "typo")
        #expect(replacing(draft.text, with: choice) == "普通🧪文字 $type: OR app:\"浏览器\"$ 尾文")
        #expect(choice.selectionOffset == 5)
    }

    @Test func quotedSourceValuesIncludeSpacesEscapedQuotesEmojiAndInnerDollars() throws {
        let draft = input(#"前文 $NOT (app:"浏览器 \"测试\" 🧑🏽‍💻$钱| beta" OR type:links)$ 后文"#)
        let context = try #require(HistorySearchCompletionEngine.context(for: draft))
        #expect(context.kind == .source)
        #expect(context.field == "app")
        #expect(context.prefix == "浏览器 \"测试\" 🧑🏽‍💻$钱")
        #expect(context.closingText.isEmpty)
        let choice = HistorySearchCompletionEngine.candidate(
            id: "browser", title: "浏览器", term: "source-id:" + HistorySearchExpression.quoted("com.example.browser"),
            context: context
        )
        #expect(replacing(draft.text, with: choice)
            == #"前文 $NOT (source-id:"com.example.browser" OR type:links)$ 后文"#)
    }

    @Test func quotedLiteralPhrasesDoNotBecomeFieldOrBooleanSuggestions() {
        for draft in [#"$"ty|"$"#, #"$"source:Saf|"$"#, #"$"AND ty|"$"#] {
            #expect(HistorySearchCompletionEngine.context(for: input(draft)) == nil)
        }
    }

    @Test func aCaretInsideAnEscapeDoesNotRetireTheQuotedSourceOrItsClosingDollar() throws {
        let draft = input(#"$app:"A\|"B$money" OR type:links$"#)
        let context = try #require(HistorySearchCompletionEngine.context(for: draft))
        #expect(context.kind == .source)
        #expect(context.closingText.isEmpty)
        #expect((draft.text as NSString).substring(with: context.replacementRange) == #"app:"A\"B$money""#)
    }

    @Test func termBoundariesRespectParenthesesAndBooleanOperators() throws {
        let draft = input("$NOT (type:images OR app:a) AND (i|s:pinn)$")
        let context = try #require(HistorySearchCompletionEngine.context(for: draft))
        let choice = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "is:" })
        #expect(replacing(draft.text, with: choice) == "$NOT (type:images OR app:a) AND (is:)$")

        let operand = input("$type:images OR NOT (type:li|nk)$")
        let operandContext = try #require(HistorySearchCompletionEngine.context(for: operand))
        let links = try #require(HistorySearchCompletionEngine.candidates(for: operandContext).first { $0.id == "type:links" })
        #expect(replacing(operand.text, with: links) == "$type:images OR NOT (type:links)$")
    }

    @Test func acceptingAnUnclosedBlockAddsOneDollarAndAnExistingCloserIsRetained() throws {
        for draft in ["$ty|", "$ty|$"] {
            let current = input(draft)
            let context = try #require(HistorySearchCompletionEngine.context(for: current))
            let choice = try #require(HistorySearchCompletionEngine.candidates(for: context).first { $0.id == "type:" })
            #expect(replacing(current.text, with: choice) == "$type:$")
            let applied = HistorySearchCompletionInput(
                text: replacing(current.text, with: choice),
                selection: NSRange(location: context.replacementRange.location + (choice.selectionOffset ?? 0), length: 0),
                isComposing: false
            )
            let valueContext = try #require(HistorySearchCompletionEngine.context(for: applied))
            #expect(valueContext.kind == .typeValue)
            #expect(valueContext.closingText.isEmpty)
            #expect(HistorySearchCompletionEngine.candidates(for: valueContext).contains { $0.id == "type:images" })
        }
    }

    @Test func completingTheMiddleOfAnUnclosedBlockKeepsItsFollowingConditionsInside() throws {
        let draft = input("$source:Sa|fari AND type:text")
        let context = try #require(HistorySearchCompletionEngine.context(for: draft))
        let choice = HistorySearchCompletionEngine.candidate(
            id: "safari", title: "Safari", term: "source-id:" + HistorySearchExpression.quoted("com.apple.Safari"),
            context: context
        )
        let applied = replacing(draft.text, with: choice)
        #expect(applied == "$source-id:\"com.apple.Safari\" AND type:text")
        let unfinished = try HistorySearchQueryCompiler.compile(applied)
        #expect(unfinished.expression == nil)
        #expect(unfinished.literalText == applied)
        let completed = try HistorySearchQueryCompiler.compile(applied + "$")
        #expect(completed.literalText.isEmpty)
        #expect(completed.expression == (try HistorySearchExpression.parse("source-id:\"com.apple.Safari\" AND type:text")))
    }

    @Test func sourceInsertionEscapesDollarsAndMapsTheCaretWithoutChangingRawIDBytes() throws {
        let draft = input("文|字")
        let context = try #require(HistorySearchCompletionEngine.context(for: draft, explicit: true))
        let identifier = "com.example.e\u{301}🧪$money"
        let rawTerm = "source-id:" + HistorySearchExpression.quoted(identifier)
        let choice = HistorySearchCompletionEngine.candidate(
            id: identifier, title: "来源", term: rawTerm, context: context,
            selectionOffset: rawTerm.utf16.count
        )
        #expect(Data(choice.insertion.utf8) == Data("$source-id:\"com.example.e\u{301}🧪\\$money\"$".utf8))
        let compiled = try HistorySearchQueryCompiler.compile(choice.insertion)
        #expect(compiled.literalText.isEmpty)
        #expect(compiled.expression == (try HistorySearchExpression.parse(rawTerm)))
        #expect(choice.selectionOffset == choice.insertion.utf16.count - 1)
        let wrapped = replacing(draft.text, with: choice)
        let caret = context.replacementRange.location + (choice.selectionOffset ?? 0)
        let source = try #require(HistorySearchCompletionEngine.context(for: .init(
            text: wrapped, selection: NSRange(location: caret, length: 0), isComposing: false
        )))
        #expect(source.prefix.utf8.elementsEqual(identifier.utf8))
    }

    @Test func nativeSelectionsExpandWholeGraphemesAndRejectMultiTermReplacement() throws {
        let text = "$app:\"前🧑🏽‍💻e\u{301}后\"$"
        let emoji = (text as NSString).range(of: "🧑🏽‍💻")
        let selected = HistorySearchCompletionInput(
            text: text, selection: NSRange(location: emoji.location + 1, length: 1), isComposing: false
        )
        let context = try #require(HistorySearchCompletionEngine.context(for: selected))
        #expect((text as NSString).substring(with: context.replacementRange) == "app:\"前🧑🏽‍💻e\u{301}后\"")
        let invalidCaret = HistorySearchCompletionInput(
            text: text, selection: NSRange(location: emoji.location + 1, length: 0), isComposing: false
        )
        #expect(HistorySearchCompletionEngine.context(for: invalidCaret) == nil)

        let compound = "$type:text AND app:a$"
        #expect(HistorySearchCompletionEngine.context(for: .init(
            text: compound, selection: NSRange(location: 1, length: 15), isComposing: false
        ), explicit: true) == nil)
    }

    @Test func composingAndCanonicallyEquivalentEditsCannotReuseAnOldCompletionInput() {
        let composed = HistorySearchCompletionInput(text: "$app:é", selection: NSRange(location: 0, length: 0), isComposing: false)
        let decomposed = HistorySearchCompletionInput(text: "$app:e\u{301}", selection: composed.selection, isComposing: false)
        #expect(composed != decomposed)
        let composing = HistorySearchCompletionInput(text: composed.text, selection: composed.selection, isComposing: true)
        #expect(HistorySearchCompletionEngine.context(for: composing, explicit: true) == nil)
    }

    @Test func shortSubsequencesAndOneTypingErrorFindRelevantFieldsAndSources() throws {
        for (prefix, field) in [("tp", "type:"), ("tpye", "type:"), ("surce", "source:")] {
            let context = try #require(HistorySearchCompletionEngine.context(for: input("$" + prefix + "|")))
            #expect(HistorySearchCompletionEngine.candidates(for: context).contains { $0.id == field })
        }
        let unrelated = try #require(HistorySearchCompletionEngine.context(for: input("$zzzz|")))
        #expect(HistorySearchCompletionEngine.candidates(for: unrelated).isEmpty)
        #expect(HistorySearchCompletionEngine.matchScore("浏览器🧪", prefix: "浏器") != nil)
        #expect(HistorySearchCompletionEngine.matchScore("Safari", prefix: "sfri") != nil)
        #expect(HistorySearchCompletionEngine.matchScore("Safari", prefix: "zzzz") == nil)
    }

    @Test func dateCompletionUsesTheSuppliedUTCDayAndProducesAValidCondition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = try #require(calendar.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 23, minute: 59)))
        for field in ["date", "before", "after"] {
            let draft = input("$" + field + ":2028-|$")
            let context = try #require(HistorySearchCompletionEngine.context(for: draft))
            let choice = try #require(HistorySearchCompletionEngine.candidates(for: context, today: today).first)
            #expect(replacing(draft.text, with: choice) == "$" + field + ":2028-02-29$")
            _ = try HistorySearchExpression.parse(choice.insertion)
        }
    }

    @Test func numericAmountsStayLiteralAndDoNotShowAutomaticGrammarChoices() {
        for draft in ["$1|0$", "$10.5|0$", "$١|٠$", "$𝟙|0$"] {
            #expect(HistorySearchCompletionEngine.context(for: input(draft)) == nil)
        }
        #expect(HistorySearchCompletionEngine.context(for: input("$10 and $20 ty|")) == nil)
        #expect(HistorySearchCompletionEngine.context(for: input("$ty|$𝟚"))?.closingText == "$")
    }

    @Test func oversizedTermsInputsAndUncertainDistantBlocksProduceNoSuggestions() {
        let longSource = "$app:" + String(repeating: "a", count: 200) + "|$"
        #expect(HistorySearchCompletionEngine.context(for: input(longSource)) == nil)
        #expect(HistorySearchCompletionEngine.context(for: input("$" + String(repeating: "a", count: 300) + "|$")) == nil)
        #expect(HistorySearchCompletionEngine.context(for: input(String(repeating: "前", count: 100_000) + "$ty|")) == nil)
        #expect(HistorySearchCompletionEngine.context(for: input(String(repeating: "x", count: 4_200) + "$ty|")) == nil)
        #expect(HistorySearchCompletionEngine.matchScore("Safari", prefix: String(repeating: "s", count: 129)) == nil)
        #expect(HistorySearchCompletionEngine.matchScore(String(repeating: "a", count: 1_025), prefix: "a") == nil)
    }

    private func input(_ marked: String) -> HistorySearchCompletionInput {
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return .init(text: text, selection: NSRange(location: marker.location, length: 0), isComposing: false)
    }

    private func replacing(_ text: String, with candidate: HistorySearchCompletionCandidate) -> String {
        (text as NSString).replacingCharacters(in: candidate.replacementRange, with: candidate.insertion)
    }
}
