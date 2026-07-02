// CrowlyMarkdown — inline-only Markdown for content-block text.
//
// v2 content blocks allow a *restricted* inline Markdown subset inside their
// text fields: **bold**, *italic*, `code`, and [label](url). No block-level
// Markdown (no headings, lists, blockquotes) — block structure is expressed by
// the ContentBlock taxonomy itself, not by Markdown. This keeps rendering
// predictable and the "schema describes shape, prose is prose" line clean.
//
// Foundation's AttributedString already parses full inline Markdown; we lean on
// it with `.inlineOnlyPreservingWhitespace` so newlines survive and no block
// grammar kicks in. The one hard rule (docs/schema.md, CLAUDE.md): **never
// crash on bad input.** If the parser throws (malformed link, stray syntax),
// we fall back to the raw string as plain text rather than propagating.

import Foundation

public enum CrowlyMarkdown {
    /// Parse the restricted inline subset into an AttributedString. On any
    /// parse failure, returns the input verbatim as plain text — a digest's
    /// prose must always render, even if an emitter fat-fingered the syntax.
    public static func attributed(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        // Inline-only: don't interpret leading `#`, `-`, `>` as block syntax,
        // and keep the author's whitespace/newlines intact.
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        // A malformed inline element (e.g. an unbalanced `[`) should degrade to
        // literal text, not abort the whole parse.
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            return parsed
        }
        return AttributedString(markdown)
    }
}
