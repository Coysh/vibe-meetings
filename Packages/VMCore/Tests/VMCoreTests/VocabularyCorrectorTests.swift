import XCTest
@testable import VMCore

final class VocabularyCorrectorTests: XCTestCase {
    private let corrector = VocabularyCorrector(terms: ["Coysh Digital", "Theresa Stone", "Evangelical Alliance", "Paul", "Kitana"])

    func testFixesAMisspelledName() {
        XCTAssertEqual(corrector.correct("I spoke to Teresa Stone yesterday."), "I spoke to Theresa Stone yesterday.")
        XCTAssertEqual(corrector.correct("Katana is off this week."), "Kitana is off this week.")
    }

    func testFixesAMultiWordTermAndKeepsPunctuation() {
        XCTAssertEqual(corrector.correct("We work with Coish Digital, mostly."), "We work with Coysh Digital, mostly.")
        XCTAssertEqual(corrector.correct("the Evangelical Alliance."), "the Evangelical Alliance.")
        XCTAssertEqual(corrector.correct("(evangelical alliance)"), "(Evangelical Alliance)")
    }

    func testKeepsPossessives() {
        XCTAssertEqual(corrector.correct("Teresa's plan"), "Theresa's plan")
    }

    func testShortTermsOnlyFixCapitalisation() {
        // "pull" is a different word from "Paul".
        XCTAssertEqual(corrector.correct("I'll pull the report. Ask paul."), "I'll pull the report. Ask Paul.")
    }

    func testOrdinaryWordsAreLeftAlone() {
        let text = "We talked about the budget and the holiday, then Dana left."
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testNeverChangesTheWordCountOfUnrelatedText() {
        let text = "Okay so basically we should aim for three weeks or four weeks off each."
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testEmptyGlossaryChangesNothing() {
        XCTAssertEqual(VocabularyCorrector(terms: []).correct("Anything at all."), "Anything at all.")
        XCTAssertTrue(VocabularyCorrector(terms: ["  ", "a"]).isEmpty)
    }
}
