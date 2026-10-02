import Foundation
import Testing
@testable import ClipyApp

/// Text rules and visual steps share one executable workflow. Round trips
/// compare behavior-bearing values, preserving exact strings but not UUIDs.
struct BuiltInAutomationSyntaxTests {
    @Test func actionNamesMapToTheExistingOperationsAndArguments() throws {
        let steps = try BuiltInAutomationSyntax.parse(#"""
        trim()
        trim_lines()
        remove_empty_lines()
        unique_lines()
        sort_lines()
        uppercase()
        lowercase()
        pretty_json()
        compact_json()
        replace("cat", "dog")
        regex_replace(r"([0-9]+)", "$1!")
        regex_extract(r"[0-9]+")
        recognize_text()
        notify()
        """#)

        #expect(steps.map(\.operation) == [
            .trim, .trimLines, .removeEmptyLines, .uniqueLines, .sortLines,
            .uppercase, .lowercase, .prettyJSON, .compactJSON, .replace,
            .regexReplace, .regexExtract, .recognizeText, .notify,
        ])
        try #require(steps.count == 14)
        #expect(steps[9].find == "cat")
        #expect(steps[9].replacement == "dog")
        #expect(steps[10].find == "([0-9]+)")
        #expect(steps[10].replacement == "$1!")
        #expect(steps[11].find == "[0-9]+")
        #expect(steps.allSatisfy { $0.enabled })
        try expectRoundTrip(steps)
    }

    @Test func parsedTextActionsExecuteInTheirWrittenOrder() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        trim_lines()
        remove_empty_lines()
        unique_lines()
        sort_lines()
        replace("a", "first")
        uppercase()
        """)

        #expect(try BuiltInAutomation.run(" b \n a\n b\n\n", steps: steps) == "FIRST\nB")
    }

    @Test func notBindsBeforeAndAndAndBindsBeforeOr() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        if contains("a") or contains("b") and not contains("c"):
            uppercase()
        else:
            lowercase()
        """)
        let conditional = try #require(steps.first)
        #expect(conditional.effectivePredicate == .any([
            .match(.containsText, "a"),
            .all([.match(.containsText, "b"), .not(.match(.containsText, "c"))]),
        ]))
        for (input, expected) in [
            ("a c Mixed", "A C MIXED"),
            ("b Mixed", "B MIXED"),
            ("b c MIXED", "b c mixed"),
            ("other MIXED", "other mixed"),
        ] {
            #expect(try BuiltInAutomation.run(input, steps: steps) == expected)
        }
        let grouped = try BuiltInAutomationSyntax.parse("""
        if (contains("a") or contains("b")) and not contains("c"):
            uppercase()
        else:
            lowercase()
        """)
        #expect(try BuiltInAutomation.run("a c Mixed", steps: grouped) == "a c mixed")
        try expectRoundTrip(steps)
        try expectRoundTrip(grouped)
    }

    @Test func elseBindsToItsIndentationAndFollowingActionsRemainOutsideTheBranch() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        if is_text():
            if contains("TODO"):
                replace("TODO", "done")
            else:
                lowercase()
        else:
            recognize_text()
        trim()
        """)
        try #require(steps.count == 2)
        let outer = steps[0]
        #expect(outer.effectivePredicate == .match(.isText, ""))
        try #require(outer.thenSteps.count == 1)
        #expect(outer.thenSteps[0].otherwiseSteps.map(\.operation) == [.lowercase])
        #expect(outer.otherwiseSteps.map(\.operation) == [.recognizeText])
        #expect(steps[1].operation == .trim)
        #expect(try BuiltInAutomation.run(" TODO Mixed ", steps: steps) == "done Mixed")
        #expect(try BuiltInAutomation.run(" OTHER Mixed ", steps: steps) == "other mixed")
        try expectRoundTrip(steps)
    }

    @Test func elifExecutesOnlyTheFirstMatchingBranchThenContinuesTheWorkflow() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        if contains("a"):
            replace("RESULT", "FIRST")
        elif contains("b"):
            replace("RESULT", "SECOND")
        elif contains("c"):
            replace("RESULT", "THIRD")
        else:
            replace("RESULT", "LAST")
        trim()
        """)
        try #require(steps.count == 2)
        let second = try #require(steps[0].otherwiseSteps.first)
        let third = try #require(second.otherwiseSteps.first)
        #expect(second.operation == .conditional)
        #expect(second.effectivePredicate == .match(.containsText, "b"))
        #expect(third.effectivePredicate == .match(.containsText, "c"))
        #expect(third.otherwiseSteps.first?.replacement == "LAST")
        for (input, expected) in [
            (" a b RESULT ", "a b FIRST"),
            (" b c RESULT ", "b c SECOND"),
            (" c RESULT ", "c THIRD"),
            (" none RESULT ", "none LAST"),
        ] {
            #expect(try BuiltInAutomation.run(input, steps: steps) == expected)
        }
        try expectRoundTrip(steps)
    }

    @Test func nestedElifKeepsInnerAndOuterElseBranchesSeparate() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        if is_text():
            if contains("a"):
                uppercase()
            elif contains("b"):
                lowercase()
            else:
                replace("X", "inner")
        else:
            recognize_text()
        trim()
        """)
        let outer = try #require(steps.first)
        let inner = try #require(outer.thenSteps.first)
        let alternative = try #require(inner.otherwiseSteps.first)
        #expect(alternative.otherwiseSteps.first?.replacement == "inner")
        #expect(outer.otherwiseSteps.map(\.operation) == [.recognizeText])
        #expect(try BuiltInAutomation.run(" a X ", steps: steps) == "A X")
        #expect(try BuiltInAutomation.run(" b X ", steps: steps) == "b x")
        #expect(try BuiltInAutomation.run(" X ", steps: steps) == "inner")
        try expectRoundTrip(steps)
    }

    @Test func disablingAnIfPreservesTheEnablementOfItsElifSubtree() throws {
        var steps = try BuiltInAutomationSyntax.parse("""
        disabled:
            if contains("a"):
                uppercase()
            elif contains("b"):
                lowercase()
            else:
                trim()
        replace("X", "Y")
        """)
        try #require(steps.count == 2)
        let alternative = try #require(steps[0].otherwiseSteps.first)
        #expect(!steps[0].enabled)
        #expect(alternative.enabled)
        #expect(alternative.thenSteps.first?.enabled == true)
        #expect(alternative.otherwiseSteps.first?.enabled == true)
        #expect(try BuiltInAutomation.run("b X ", steps: steps) == "b Y ")
        try expectRoundTrip(steps)
        steps[0].enabled = true
        #expect(try BuiltInAutomation.run("b X ", steps: steps) == "b x ")
    }

    @Test func elifRequiresAnImmediatelyPrecedingIfOrElif() throws {
        let cases: [(String, Int)] = [
            ("elif is_text():\n    trim()", 1),
            ("if is_text():\n    trim()\nelse:\n    trim()\nelif is_image():\n    pass", 5),
            ("if is_text():\n    trim()\nlowercase()\nelif is_image():\n    pass", 4),
        ]
        for (source, line) in cases {
            let error = try #require(syntaxError(source))
            #expect(error.reason == .unexpectedElse)
            #expect(error.line == line)
            #expect(error.column == 1)
        }
    }

    @Test func quotedStringsDecodeEscapesWhileRawRegexPreservesBackslashes() throws {
        let escaped = try BuiltInAutomationSyntax.parse(#"replace('can\'t', "say \"hello\"\nnext\\line")"#)
        let replacement = try #require(escaped.first)
        #expect(replacement.find == "can't")
        #expect(replacement.replacement == "say \"hello\"\nnext\\line")
        #expect(try BuiltInAutomation.run("can't", steps: escaped) == "say \"hello\"\nnext\\line")
        let regex = try BuiltInAutomationSyntax.parse(#"""
        if matches(r"\bTODO:\s+\d+\b") and not is_image():
            regex_extract(R'\d+')
        """#)
        let conditional = try #require(regex.first)
        #expect(conditional.effectivePredicate == .all([
            .match(.matchesRegex, #"\bTODO:\s+\d+\b"#),
            .not(.match(.isImage, "")),
        ]))
        #expect(conditional.thenSteps.first?.find == #"\d+"#)
        #expect(try BuiltInAutomation.run("TODO: 42", steps: regex) == "42")
        let rawQuote = try BuiltInAutomationSyntax.parse(#"replace(r"\"", "x")"#)
        #expect(rawQuote.first?.find == "\\\"")
        try expectRoundTrip(escaped)
        try expectRoundTrip(regex)
        try expectRoundTrip(rawQuote)
    }

    @Test(arguments: [
        "\u{0301}leading",
        "\u{200D}leading",
        "\u{FE0F}leading",
        "trailing\u{0301}",
        "trailing\u{200D}",
        "trailing\u{FE0F}",
        "\u{0301}# if is_text(): (and or not) else:",
        "\u{0301}",
    ])
    func quotedUnicodeBoundariesPreserveExactArgumentBytes(literal: String) throws {
        let expected = Data(literal.utf8)
        // A combining scalar can share a Character with the opening quote.
        // Test literal source text, including raw and both quote forms, before
        // asking the formatter to produce its own quoted spelling.
        for quote in ["\"", "'"] {
            for prefix in ["", "r", "R"] {
                let argument = prefix + quote + literal + quote
                let steps = try BuiltInAutomationSyntax.parse("replace(" + argument + ", " + argument + ")")
                try #require(steps.count == 1)
                #expect(steps[0].operation == .replace)
                #expect(Data(steps[0].find.utf8) == expected)
                #expect(Data(steps[0].replacement.utf8) == expected)

                let restored = try BuiltInAutomationSyntax.parse(BuiltInAutomationSyntax.render(steps))
                try #require(restored.count == 1)
                #expect(Data(restored[0].find.utf8) == expected)
                #expect(Data(restored[0].replacement.utf8) == expected)
            }
        }
    }

    @Test func diagnosticColumnsStillCountCharactersWhenQuotedArgumentsContainCombiningScalars() throws {
        let error = try #require(syntaxError("trim()\nreplace(\"\u{0301}text\u{0301}\", 42)"))

        #expect(error.reason == .expectedString)
        #expect(error.line == 2)
        #expect(error.column == 17)
    }

    @Test func commentsAndBlankLinesDoNotAlterQuotedHashCharactersOrBlockOwnership() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        # A whole-line comment.

        if is_text():  # Choose text values.
            # Comments do not supply the required executable body.
            replace("# TODO", "done # kept") # Outside the string.

        trim()
        """)

        #expect(try BuiltInAutomation.run(" # TODO ", steps: steps) == "done # kept")
        try expectRoundTrip(steps)
    }

    @Test func disabledBlocksDisableOnlyTheirDirectStepsAndRetainNestedEnablement() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        disabled:
            trim()
            if contains("A"):
                uppercase()
                disabled:
                    replace("A", "B")
            else:
                trim_lines()
        lowercase()
        """)
        try #require(steps.count == 3)
        #expect(!steps[0].enabled)
        #expect(!steps[1].enabled)
        #expect(steps[2].enabled)
        #expect(steps[1].thenSteps.map(\.enabled) == [true, false])
        #expect(steps[1].otherwiseSteps.map(\.enabled) == [true])
        #expect(try BuiltInAutomation.run(" A ", steps: steps) == " a ")
        try expectRoundTrip(steps)
    }

    @Test func passRepresentsAnEmptyBranchWithoutInventingAnOperation() throws {
        let steps = try BuiltInAutomationSyntax.parse("""
        if contains("TODO"):
            pass
        else:
            trim()
        uppercase()
        """)
        try #require(steps.count == 2)
        #expect(steps[0].thenSteps.isEmpty)
        #expect(steps[0].otherwiseSteps.map(\.operation) == [.trim])
        #expect(try BuiltInAutomation.run(" ordinary ", steps: steps) == "ORDINARY")
        #expect(try BuiltInAutomation.run(" TODO ", steps: steps) == " TODO ")
        try expectRoundTrip(steps)
    }

    @Test func legacyFlatGuardsStillStopTheWorkflowAndDiscardDeferredNotifications() async throws {
        let guards = try BuiltInAutomationSyntax.parse(#"""
        require_text()
        require_image()
        require_contains("TODO")
        require_matches(r"[0-9]+")
        """#)
        #expect(guards.map(\.operation) == [.requireText, .requireImage, .containsText, .matchesRegex])
        try expectRoundTrip(guards)
        let steps = try BuiltInAutomationSyntax.parse("""
        notify()
        require_contains("TODO")
        uppercase()
        """)
        let rejected = try await BuiltInAutomation.run(.text("ordinary Mixed"), steps: steps)
        #expect(!rejected.matchedConditions)
        #expect(!rejected.requestsNotification)
        #expect(rejected.value == .text("ordinary Mixed"))
        let accepted = try await BuiltInAutomation.run(.text("TODO Mixed"), steps: steps)
        #expect(accepted.matchedConditions)
        #expect(accepted.requestsNotification)
        #expect(accepted.value == .text("TODO MIXED"))
    }

    @Test func visualStepsIncludingLegacyConditionsRoundTripByMeaningRatherThanIdentity() throws {
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, find: "e\u{301}", condition: .containsText, thenSteps: [
                .init(operation: .replace, find: "e\u{301}", replacement: "é"),
                .init(operation: .notify, enabled: false),
            ], otherwiseSteps: [.init(operation: .trim)]),
            .init(operation: .conditional, predicate: .not(.match(.isImage, "")), thenSteps: [
                .init(operation: .uppercase),
            ]),
        ]
        let restored = try BuiltInAutomationSyntax.parse(BuiltInAutomationSyntax.render(steps))
        #expect(meaning(restored) == meaning(steps))
        #expect(restored.first?.id != steps.first?.id)
        #expect(try BuiltInAutomation.run("e\u{301}", steps: restored) == "É")
    }

    @Test func formattingPreservesTruthAndExecutionAcrossAssociativeGroupNormalization() throws {
        let predicates: [BuiltInAutomationPredicate] = [
            .all([.match(.isText, ""), .match(.containsText, "a"), .not(.match(.containsText, "z"))]),
            .any([.match(.isImage, ""), .match(.containsText, "x"), .match(.containsText, "y")]),
            .all([.match(.containsText, "a")]),
            .any([.not(.match(.isImage, ""))]),
            .all([
                .any([.match(.containsText, "a"), .match(.containsText, "b"), .match(.containsText, "c")]),
                .not(.all([.match(.isText, ""), .match(.containsText, "z")])),
                .match(.isText, ""),
            ]),
        ]
        let texts = ["a MiXeD", "b MiXeD", "c z MiXeD", "x MiXeD", "y MiXeD", "none MiXeD", "a z MiXeD"]
        for predicate in predicates {
            let steps = [BuiltInAutomationStep(
                operation: .conditional, predicate: predicate,
                thenSteps: [.init(operation: .uppercase)], otherwiseSteps: [.init(operation: .lowercase)]
            )]
            let restored = try BuiltInAutomationSyntax.parse(BuiltInAutomationSyntax.render(steps))
            let restoredCondition = try #require(restored.first).effectivePredicate
            // The predicate inspects the value's kind without decoding an
            // image. Runner equivalence below uses real text transforms.
            for input in texts.map(BuiltInAutomationInput.text) + [.image(Data())] {
                #expect(try restoredCondition.matches(input) == predicate.matches(input))
            }
            for text in texts {
                #expect(try BuiltInAutomation.run(text, steps: restored) == BuiltInAutomation.run(text, steps: steps))
            }
        }
    }

    @Test func formatterRejectsInactiveBranchesInsteadOfSilentlyDroppingThem() throws {
        let steps = [BuiltInAutomationStep(
            operation: .trim, thenSteps: [.init(operation: .uppercase)]
        )]
        let error = try #require(renderError(steps))

        #expect(error.reason == .unrepresentableStep)
        #expect(error.line == 1)
        #expect(error.column == 1)
    }

    @Test func moreThanOneHundredActionsHaveNoArtificialCountLimit() throws {
        let source = Array(repeating: "trim()", count: 150).joined(separator: "\n")
        let steps = try BuiltInAutomationSyntax.parse(source)

        #expect(steps.count == 150)
        #expect(Set(steps.map(\.id)).count == 150)
        #expect(try BuiltInAutomation.run(" value ", steps: steps) == "value")
        try expectRoundTrip(steps)
    }

    @Test func deeplyIndentedRulesParseRenderAndExecuteWithoutANestingCap() throws {
        var lines: [String] = []
        for depth in 0..<300 {
            lines.append(String(repeating: " ", count: depth * 4) + "if is_text():")
        }
        lines.append(String(repeating: " ", count: 300 * 4) + "trim()")
        let source = lines.joined(separator: "\n")
        try #require(source.utf8.count < 1_048_576)
        let steps = try BuiltInAutomationSyntax.parse(source)

        #expect(meaning(steps).count == 301)
        #expect(try BuiltInAutomation.run(" deep ", steps: steps) == "deep")
        try expectRoundTrip(steps)
    }

    @Test func deeplyNestedNotPredicatesHaveNoArtificialNestingCap() throws {
        let source = "if " + String(repeating: "not ", count: 300) + "is_text():\n    trim()"
        let steps = try BuiltInAutomationSyntax.parse(source)

        #expect(try BuiltInAutomation.run(" predicate ", steps: steps) == "predicate")
        try expectRoundTrip(steps)
    }

    @Test func parameterLimitsCountUTF8BytesAndAcceptTheExactBoundary() throws {
        let literal = String(repeating: "é", count: 8_192)
        let source = "replace(\"" + literal + "\", \"x\")"
        let steps = try BuiltInAutomationSyntax.parse(source)
        #expect(steps.first?.find.utf8.count == 16_384)
        try expectRoundTrip(steps)

        let error = try #require(syntaxError("replace(\"" + literal + "a\", \"x\")"))
        #expect(error.reason == .parameterTooLarge)
        let renderingError = try #require(renderError([
            .init(operation: .replace, find: literal + "a", replacement: "x"),
        ]))
        #expect(renderingError.reason == .parameterTooLarge)
    }

    @Test func completeSourceLimitAcceptsOneMiBAndRejectsTheNextByte() throws {
        let source = "#" + String(repeating: "x", count: 1_048_575)
        #expect(try BuiltInAutomationSyntax.parse(source).isEmpty)

        let error = try #require(syntaxError(source + "x"))
        #expect(error.reason == .sourceTooLarge)
        let largeArguments = String(repeating: "é", count: 8_192)
        let renderingError = try #require(renderError((0..<70).map { _ in
            .init(operation: .replace, find: largeArguments, replacement: "x")
        }))
        #expect(renderingError.reason == .sourceTooLarge)
    }

    @Test func syntaxDiagnosticsIdentifyTheExactLineAndCharacterColumn() throws {
        let cases: [(String, BuiltInAutomationSyntaxError.Reason, Int, Int)] = [
            ("trim()\n  uppercase()", .unexpectedIndentation, 2, 3),
            ("if is_text():\nuppercase()", .expectedIndentedBlock, 2, 1),
            ("if is_text():\n    trim()\n  uppercase()", .unexpectedIndentation, 3, 3),
            ("if is_text()\n    trim()", .expectedColon, 1, 13),
            ("if is_text():", .expectedIndentedBlock, 2, 1),
            ("else:\n    trim()", .unexpectedElse, 1, 1),
            ("if unknown():\n    trim()", .unknownCondition, 1, 4),
            ("unknown()", .unknownAction, 1, 1),
            ("if is_text():\n\ttrim()", .tabsInIndentation, 2, 1),
            ("trim(\"x\")", .wrongArgumentCount, 1, 1),
            ("replace(\"主题\", 42)", .expectedString, 1, 15),
            ("replace(\"a\", \"unterminated)", .unterminatedString, 1, 14),
            (#"replace("a", "\q")"#, .invalidEscape, 1, 15),
            ("if (is_text():\n    trim()", .unclosedParenthesis, 1, 4),
        ]
        for (source, reason, line, column) in cases {
            let error = try #require(syntaxError(source))
            #expect(error.reason == reason)
            #expect(error.line == line)
            #expect(error.column == column)
            #expect(!error.message.isEmpty)
        }
    }

    @Test func cancelledParsingAndRenderingDoNotReturnACompletedDefinition() async {
        let parse = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BuiltInAutomationSyntax.parse("trim()")
        }
        await #expect(throws: CancellationError.self) { try await parse.value }
        let render = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BuiltInAutomationSyntax.render([.init(operation: .trim)])
        }
        await #expect(throws: CancellationError.self) { try await render.value }
    }

    private struct StepMeaning: Equatable {
        let operation: BuiltInAutomationStep.Operation
        let enabled: Bool
        let find: Data
        let replacement: Data
        let predicate: BuiltInAutomationPredicate?
        let thenCount: Int
        let otherwiseCount: Int
    }

    private func meaning(_ steps: [BuiltInAutomationStep]) -> [StepMeaning] {
        var result: [StepMeaning] = []
        var pending = Array(steps.reversed())
        while let step = pending.popLast() {
            let usesFind = [.replace, .regexReplace, .regexExtract, .containsText, .matchesRegex]
                .contains(step.operation)
            let usesReplacement = step.operation == .replace || step.operation == .regexReplace
            result.append(StepMeaning(
                operation: step.operation, enabled: step.enabled,
                find: usesFind ? Data(step.find.utf8) : Data(),
                replacement: usesReplacement ? Data(step.replacement.utf8) : Data(),
                predicate: step.operation == .conditional ? step.effectivePredicate : nil,
                thenCount: step.thenSteps.count, otherwiseCount: step.otherwiseSteps.count
            ))
            pending.append(contentsOf: step.otherwiseSteps.reversed())
            pending.append(contentsOf: step.thenSteps.reversed())
        }
        return result
    }

    private func expectRoundTrip(_ steps: [BuiltInAutomationStep]) throws {
        let source = try BuiltInAutomationSyntax.render(steps)
        let restored = try BuiltInAutomationSyntax.parse(source)
        #expect(meaning(restored) == meaning(steps))
    }

    private func syntaxError(_ source: String) -> BuiltInAutomationSyntaxError? {
        do {
            _ = try BuiltInAutomationSyntax.parse(source)
            Issue.record("Expected invalid workflow syntax: \(source.prefix(80))")
        } catch let error as BuiltInAutomationSyntaxError {
            return error
        } catch {
            Issue.record("Unexpected workflow parser error: \(error)")
        }
        return nil
    }

    private func renderError(_ steps: [BuiltInAutomationStep]) -> BuiltInAutomationSyntaxError? {
        do {
            _ = try BuiltInAutomationSyntax.render(steps)
            Issue.record("Expected the formatter to reject an unrepresentable definition")
        } catch let error as BuiltInAutomationSyntaxError {
            return error
        } catch {
            Issue.record("Unexpected workflow formatter error: \(error)")
        }
        return nil
    }
}
