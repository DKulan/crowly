// CrowlyMarkdown inline-subset tests (Swift Testing).
//
// The one hard rule: never crash on bad input. These prove the restricted
// inline subset parses, and that malformed syntax degrades to readable text
// rather than throwing.

import Testing
import Foundation
@testable import Crowly

/// Plain-character content of an AttributedString (styling stripped) — lets us
/// assert the *text* survived regardless of how it was styled.
private func plainString(_ attr: AttributedString) -> String {
    String(attr.characters)
}

@Test func boldRendersAndStripsMarkers() {
    let a = CrowlyMarkdown.attributed("Hello **world**")
    // The literal `**` markers are consumed by the parser; the words remain.
    #expect(plainString(a) == "Hello world")
}

@Test func italicRenders() {
    let a = CrowlyMarkdown.attributed("A *soft* note")
    #expect(plainString(a) == "A soft note")
}

@Test func inlineCodeRenders() {
    let a = CrowlyMarkdown.attributed("Run `crowly_emit.py` now")
    #expect(plainString(a) == "Run crowly_emit.py now")
}

@Test func linkRendersLabelText() {
    let a = CrowlyMarkdown.attributed("See [the docs](https://example.com) here")
    #expect(plainString(a) == "See the docs here")
}

@Test func plainTextPassesThroughUnchanged() {
    let a = CrowlyMarkdown.attributed("just plain text, no markup")
    #expect(plainString(a) == "just plain text, no markup")
}

@Test func malformedMarkdownNeverThrowsAndKeepsText() {
    // Unbalanced / stray syntax must degrade to readable text, not crash.
    for input in [
        "unbalanced **bold",
        "stray ] bracket [ chars",
        "[label](unclosed",
        "```",
        "text with * lone asterisk",
        "",
    ] {
        let a = CrowlyMarkdown.attributed(input)
        // We don't assert exact output (parser may or may not consume stray
        // markers) — only that it produced *something* without throwing, and
        // that non-empty inputs stay non-empty.
        if !input.isEmpty {
            #expect(!plainString(a).isEmpty, "input \(input.debugDescription) lost all text")
        }
    }
}

@Test func newlinesPreservedByInlineOnlyParsing() {
    // `.inlineOnlyPreservingWhitespace` keeps author newlines rather than
    // collapsing them the way block parsing would.
    let a = CrowlyMarkdown.attributed("line one\nline two")
    #expect(plainString(a).contains("\n"))
}
