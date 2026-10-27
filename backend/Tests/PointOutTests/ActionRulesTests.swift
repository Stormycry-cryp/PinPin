import XCTest
@testable import PointOut

final class ActionRulesTests: XCTestCase {
    func testTranslationDirectionIsDecidedLocally() {
        let english = ActionRules.translationPlan(unit: "Less is more, and simplicity is the ultimate sophistication.",
                                                  pointed: nil, home: "zh-Hans")
        XCTAssertEqual(english.target, "zh-Hans")
        XCTAssertEqual(english.subtitle, "英 → 中")
        XCTAssertFalse(english.pointedTerm)

        let chinese = ActionRules.translationPlan(unit: "接口需要保证幂等性，否则重复请求会出问题。", pointed: nil, home: "zh-Hans")
        XCTAssertEqual(chinese.target, "en")
        XCTAssertEqual(chinese.subtitle, "中 → 英")

        let term = ActionRules.translationPlan(unit: "接口需要保证 idempotent，否则重复请求会出问题。",
                                               pointed: "idempotent", home: "zh-Hans")
        XCTAssertTrue(term.pointedTerm)
        XCTAssertEqual(term.text, "idempotent")
        XCTAssertEqual(term.target, "zh-Hans")

        let englishHome = ActionRules.translationPlan(unit: "Hello world, this is a test sentence.", pointed: nil, home: "en")
        XCTAssertEqual(englishHome.target, "zh-Hans")
    }

    func testHomeLanguageFromPreferences() {
        XCTAssertEqual(ActionRules.homeLanguage(preferred: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(ActionRules.homeLanguage(preferred: ["zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(ActionRules.homeLanguage(preferred: ["zh-TW"]), "zh-Hant")
        XCTAssertEqual(ActionRules.homeLanguage(preferred: ["en-US", "zh-Hans"]), "en")
        XCTAssertEqual(ActionRules.homeLanguage(preferred: []), "zh-Hans")
    }

    func testTagParsingAcceptsOnlyAShortJSONArray() {
        XCTAssertEqual(ActionRules.parseTags(#"["工作","待办"]"#), ["工作", "待办"])
        XCTAssertEqual(ActionRules.parseTags("标签：[\"#学习\", \"学习\", \"\"]"), ["学习"])
        XCTAssertEqual(ActionRules.parseTags("not json"), [])
        XCTAssertEqual(ActionRules.parseTags(#"["a","b","c","d"]"#), ["a", "b", "c"])
        XCTAssertEqual(ActionRules.parseTags(#"["这是一个远远超过十二个字的过长标签啊啊"]"#), [])
        XCTAssertEqual(ActionRules.normalizedTags(["  工作 ", "工作", "Work", "work"]), ["工作", "Work"])
    }

    func testPlainTextAndOutputBudget() {
        XCTAssertEqual(ActionRules.plainText("**缓存**：把结果存起来"), "缓存：把结果存起来")
        XCTAssertEqual(ActionRules.outputTokens(for: "short"), 240)
        XCTAssertEqual(ActionRules.outputTokens(for: String(repeating: "x", count: 3000)), 1600)
    }
}
