import Foundation
import SkimCore

// A tiny dependency-free check harness. Verifies the pure reading core on
// machines that only have the Swift CLT (no XCTest). Run: `swift run CoreChecks`.

var failures: [String] = []

@MainActor
func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures.append(message)
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message)  (got \(actual), want \(expected))")
}

/// Float comparison with a small tolerance, for values built by accumulating sums
/// where exact `==` would trip over binary-float rounding.
@MainActor
func expectClose(_ actual: Double, _ expected: Double, _ message: String, tol: Double = 1e-9) {
    expect(abs(actual - expected) < tol, "\(message)  (got \(actual), want ~\(expected))")
}

@MainActor
func expectClose(_ actual: [Double], _ expected: [Double], _ message: String, tol: Double = 1e-9) {
    let ok = actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < tol }
    expect(ok, "\(message)  (got \(actual), want ~\(expected))")
}

print("Tokenizer")
do {
    let t = Tokenizer.tokenize("the quick brown fox")
    expectEqual(t.map(\.text), ["the", "quick", "brown", "fox"], "splits words")
    expectEqual(t.map(\.tokenIndex), [0, 1, 2, 3], "token indices run 0..n")
}
do {
    let t = Tokenizer.tokenize("  spaced\t\tout   words  ")
    expectEqual(t.map(\.text), ["spaced", "out", "words"], "collapses whitespace, no empties")
}
do {
    expect(Tokenizer.tokenize("").isEmpty, "empty string -> no tokens")
    expect(Tokenizer.tokenize("   \n  \n").isEmpty, "blank-only -> no tokens")
}
do {
    let t = Tokenizer.tokenize("first, second; third: fourth")
    expectEqual(t[0].delayMultiplier, 1.4, "comma pause")
    expectEqual(t[1].delayMultiplier, 1.4, "semicolon pause")
    expectEqual(t[2].delayMultiplier, 1.4, "colon pause")
}
do {
    // Trailing "now" keeps "go" off the end so it isn't given the paragraph breath.
    let t = Tokenizer.tokenize("Stop. Wait! Why? go now")
    expectEqual(t[0].delayMultiplier, 2.0, "period pause")
    expectEqual(t[1].delayMultiplier, 2.0, "exclamation pause")
    expectEqual(t[2].delayMultiplier, 2.0, "question pause")
    expectEqual(t[3].delayMultiplier, 1.0, "plain word")
}
do {
    let t = Tokenizer.tokenize(#"the pipeline.") next"#)
    expectEqual(t[1].delayMultiplier, 2.0, "punctuation behind closing quote/paren counts")
}
do {
    // Trailing "here" keeps "acquisition" off the end of the paragraph.
    let t = Tokenizer.tokenize("cat acquisition here")
    expectEqual(t[0].delayMultiplier, 1.0, "short word, no slow-down")
    expectEqual(t[1].delayMultiplier, 1.15, "long word slow-down")
}
do {
    let t = Tokenizer.tokenize("acquisition. here")
    expectEqual(t[0].delayMultiplier, 2.0, "sentence pause beats long-word pause")
}
do {
    let t = Tokenizer.tokenize("one two. three four. five")
    expectEqual(t.map(\.sentenceIndex), [0, 0, 1, 1, 2], "sentence index increments after terminal punctuation")
}
do {
    let t = Tokenizer.tokenize("alpha beta\n\ngamma delta")
    expectEqual(t.map(\.paragraphIndex), [0, 0, 1, 1], "blank line separates paragraphs")
    expectEqual(t.map(\.sentenceIndex), [0, 0, 1, 1], "paragraph break starts a new sentence")
}
do {
    let t = Tokenizer.tokenize("alpha beta\n\ngamma")
    expectEqual(t[1].delayMultiplier, 2.8, "last word of paragraph gets a breath")
}

print("Tokenizer (lock-in current behavior)")
do {
    // Whitespace tokenization: tabs/newlines within a paragraph all split words.
    let t = Tokenizer.tokenize("alpha\tbeta gamma here")
    expectEqual(t.map(\.text), ["alpha", "beta", "gamma", "here"], "tab and space both split words")
}
do {
    // Blank-line paragraph split (multiple blank lines collapse to one break).
    let t = Tokenizer.tokenize("a b\n\n\nc d")
    expectEqual(t.map(\.paragraphIndex), [0, 0, 1, 1], "any run of blank lines splits paragraphs")
}
do {
    // Punctuation stays attached to its token; never its own token.
    let t = Tokenizer.tokenize("hello, world. done here")
    expectEqual(t.map(\.text), ["hello,", "world.", "done", "here"], "punctuation stays attached to the word")
}
do {
    // Quotes/brackets wrapping sentence punctuation still count as a sentence end.
    let t = Tokenizer.tokenize(#"the pipeline." next here"#)
    expectEqual(t[1].delayMultiplier, 2.0, #"closing quote around period -> 2.0"#)
    let u = Tokenizer.tokenize(#"the pipeline.) next here"#)
    expectEqual(u[1].delayMultiplier, 2.0, "closing paren around period -> 2.0")
}
do {
    // Paragraph-final token always gets the 2.8 breath, even mid-multiplier.
    let t = Tokenizer.tokenize("short word\n\nnext")
    expectEqual(t[1].delayMultiplier, 2.8, "paragraph-final word gets 2.8 breath")
}
do {
    // Max-multiplier-wins: a long word that also ends a sentence gets 2.0, not 1.15.
    let t = Tokenizer.tokenize("acquisition. here")
    expectEqual(t[0].delayMultiplier, 2.0, "max multiplier wins (sentence 2.0 over long-word 1.15)")
}

print("Tokenizer (abbreviations)")
do {
    // "Mr." should not be a sentence end despite the trailing period.
    let t = Tokenizer.tokenize("Mr. Smith arrived here")
    expect(t[0].delayMultiplier < 2.0, "Mr. does not get the sentence pause")
    expectEqual(t.map(\.sentenceIndex), [0, 0, 0, 0], "Mr. does not bump sentenceIndex")
}
do {
    let t = Tokenizer.tokenize("e.g. this case here")
    expect(t[0].delayMultiplier < 2.0, "e.g. does not get the sentence pause")
    expectEqual(t[0].sentenceIndex, 0, "e.g. does not bump sentenceIndex")
}
do {
    // Four abbreviations in a row should count as one (still-open) sentence.
    let t = Tokenizer.tokenize("U.S.A. e.g. i.e. etc. done here")
    expectEqual(t.map(\.sentenceIndex), [0, 0, 0, 0, 0, 0], "abbreviation run is not four sentences")
}
do {
    // Abbreviation wrapped in quotes/brackets is still recognized.
    let t = Tokenizer.tokenize(#"("e.g." this) case here"#)
    expect(t[0].delayMultiplier < 2.0, "quoted/bracketed e.g. still recognized as abbreviation")
}
do {
    // A genuine sentence-ending word still works normally.
    let t = Tokenizer.tokenize("done. next here")
    expectEqual(t[0].delayMultiplier, 2.0, "normal sentence end still pauses 2.0")
    expectEqual(t[0].sentenceIndex, 0, "normal sentence end token sits in sentence 0")
    expectEqual(t[1].sentenceIndex, 1, "normal sentence end bumps sentenceIndex")
}

print("Tokenizer (em/en dash clause)")
do {
    let t = Tokenizer.tokenize("Wait—really here")
    expectEqual(t.count, 2, "em-dash does not split the token")
    expectEqual(t[0].text, "Wait—really", "em-dash token text preserved")
    expectEqual(t[0].delayMultiplier, 1.4, "internal em-dash -> clause pause")
}
do {
    let t = Tokenizer.tokenize("Wait–really here")  // en-dash
    expectEqual(t[0].delayMultiplier, 1.4, "internal en-dash -> clause pause")
}
do {
    let t = Tokenizer.tokenize("Wait—really?! here")
    expectEqual(t.count, 2, "em-dash + terminal punct stays one token")
    expectEqual(t[0].delayMultiplier, 2.0, "sentence pause beats em-dash clause pause")
}

print("Tokenizer (complex numbers)")
do {
    let t = Tokenizer.tokenize("1,000,000 dollars here")
    expect(t[0].delayMultiplier >= 1.15, "1,000,000 gets at least long-word pacing")
}
do {
    let t = Tokenizer.tokenize("worth $250,000 here")
    expect(t[1].delayMultiplier >= 1.15, "$250,000 gets at least long-word pacing")
}
do {
    let t = Tokenizer.tokenize("about 12.5% here")
    expect(t[1].delayMultiplier >= 1.15, "12.5% gets at least long-word pacing")
}
do {
    let t = Tokenizer.tokenize("100000 plain here")
    expect(t[0].delayMultiplier >= 1.15, "6+ digit number gets at least long-word pacing")
}
do {
    // 3.14 must not be treated as a sentence end (period is internal, not terminal).
    let t = Tokenizer.tokenize("3.14 pi here")
    expect(t[0].delayMultiplier < 2.0, "3.14 does not sentence-pause")
    expectEqual(t[0].sentenceIndex, 0, "3.14 does not bump sentenceIndex")
}
do {
    // 3.14. with an extra terminal period MUST sentence-pause.
    let t = Tokenizer.tokenize("3.14. Next here")
    expectEqual(t[0].delayMultiplier, 2.0, "3.14. with terminal period sentence-pauses (2.0)")
    expectEqual(t[1].sentenceIndex, 1, "3.14. bumps sentenceIndex")
}

print("Markdown")
do {
    expectEqual(Markdown.strip("**bold** and *italic*"), "bold and italic", "unwraps bold and italic")
    expectEqual(Markdown.strip("***both***"), "both", "unwraps bold-italic")
    expectEqual(Markdown.strip("a ~~struck~~ word"), "a struck word", "unwraps strikethrough")
    expectEqual(Markdown.strip("call `render()` now"), "call render() now", "unwraps inline code")
    expectEqual(Markdown.strip("# Heading"), "Heading", "strips ATX heading marker")
    expectEqual(Markdown.strip("### Deep"), "Deep", "strips multi-hash heading")
    expectEqual(Markdown.strip("- a\n- b"), "a\nb", "strips unordered list markers")
    expectEqual(Markdown.strip("1. first\n2. second"), "first\nsecond", "strips ordered list markers")
    expectEqual(Markdown.strip("> quoted text"), "quoted text", "strips blockquote marker")
    expectEqual(Markdown.strip("see [the docs](https://x.io)"), "see the docs", "link -> label")
    expectEqual(Markdown.strip("![alt](img.png) caption"), "alt caption", "image -> alt text")
    expectEqual(Markdown.strip("keep snake_case intact"), "keep snake_case intact", "underscores in identifiers survive")
    expectEqual(Markdown.strip("an _emphasized_ word"), "an emphasized word", "underscore emphasis unwrapped")
    expectEqual(Markdown.strip("a\n\n---\n\nb"), "a\n\n\nb", "horizontal rule dropped")
    expectEqual(Markdown.strip(#"literal \*stars\*"#), "literal *stars*", "unescapes backslashed punctuation")
}
do {
    // End to end: markdown text tokenizes to clean words with structure intact.
    let t = Tokenizer.tokenize("# Title\n\nSome **bold** text.")
    expectEqual(t.map(\.text), ["Title", "Some", "bold", "text."], "markdown-aware tokenization")
    expectEqual(t.map(\.paragraphIndex), [0, 1, 1, 1], "heading and body are separate paragraphs")
}

print("ReadingContext")
do {
    let t = Tokenizer.tokenize("one two three four five six seven")
    let w = ReadingContext.window(tokens: t, index: 3, before: 2, after: 2)
    expectEqual(w.before, "two three", "before = up to N words behind")
    expectEqual(w.current, "four", "current = token at index")
    expectEqual(w.after, "five six", "after = up to N words ahead")
}
do {
    let t = Tokenizer.tokenize("alpha beta gamma")
    let w = ReadingContext.window(tokens: t, index: 0, before: 5, after: 5)
    expectEqual(w.before, "", "start of text -> empty before")
    expectEqual(w.current, "alpha", "first word is current")
    expectEqual(w.after, "beta gamma", "after clamps to end")
}
do {
    let t = Tokenizer.tokenize("alpha beta gamma")
    let w = ReadingContext.window(tokens: t, index: 2, before: 5, after: 5)
    expectEqual(w.after, "", "end of text -> empty after")
    expectEqual(w.before, "alpha beta", "before clamps to start")
}
do {
    let w = ReadingContext.window(tokens: [], index: 0, before: 3, after: 3)
    expectEqual(w.current, "", "out-of-range index -> empty window")
}

print("Pacing")
expectEqual(Pacing.secondsPerToken(wpm: 300, multiplier: 1.0), 0.2, "300 WPM -> 0.2s")
expectEqual(Pacing.secondsPerToken(wpm: 600, multiplier: 1.0), 0.1, "600 WPM -> 0.1s")
expectEqual(Pacing.secondsPerToken(wpm: 300, multiplier: 2.0), 0.4, "multiplier scales delay")
expectEqual(Pacing.secondsPerToken(wpm: 0, multiplier: 1.0), 0.0, "zero WPM guarded")
expectEqual(Pacing.secondsPerToken(band: SpeedBand(wpm: 300), multiplier: 1.0), 0.2, "band convenience matches raw WPM")

print("SpeedBand")
expectEqual(SpeedBand.allCases.first?.wpm, 300, "slowest band is 300 wpm")
expectEqual(SpeedBand.allCases.last?.wpm, 1000, "fastest band is 1000 wpm")
expectEqual(SpeedBand.allCases.count, 29, "300→1000 in 25-wpm steps = 29 bands")
expectEqual(SpeedBand.allCases[1].wpm, 325, "bands step by 25 wpm")
expectEqual(SpeedBand(wpm: 300).faster(), SpeedBand(wpm: 325), "faster steps up 25")
expectEqual(SpeedBand(wpm: 1000).faster(), SpeedBand(wpm: 1000), "faster clamps at 1000")
expectEqual(SpeedBand(wpm: 1000).slower(), SpeedBand(wpm: 975), "slower steps down 25")
expectEqual(SpeedBand(wpm: 300).slower(), SpeedBand(wpm: 300), "slower clamps at 300")
expectEqual(SpeedBand(wpm: 300).label, "Calm", "low end reads as Calm")
expectEqual(SpeedBand(wpm: 1000).label, "Blast", "top end reads as Blast")
expectEqual(SpeedBand.cruise.wpm, 400, "default cruise falls back to a calm 400 wpm")
expectEqual(SpeedBand.cruise.label, "Cruise", "default opens in the Cruise band, never Blast")
// `nearest` resolves any stored/computed speed onto a real, in-range detent — the
// clamp every auto-start ramp target flows through.
expectEqual(SpeedBand.nearest(to: 400).wpm, 400, "400 resolves to the 400 detent")
expectEqual(SpeedBand.nearest(to: 500).wpm, 500, "500 resolves to the 500 detent")
expectEqual(SpeedBand.nearest(to: 350).wpm, 350, "350 resolves to the 350 detent")
expectEqual(SpeedBand.nearest(to: 412).wpm, 400, "an off-grid value snaps to the nearest detent")
expectEqual(SpeedBand.nearest(to: 99_999).wpm, SpeedBand.maxWPM, "an absurdly high preference clamps to the max")
expectEqual(SpeedBand.nearest(to: 10).wpm, SpeedBand.minWPM, "a sub-floor preference clamps to the min")
expect(SpeedBand.allCases.contains(SpeedBand.nearest(to: 533)), "nearest always returns a real detent")
expectEqual(SpeedBand(wpm: 300).warmth, 0.0, "slowest band is coolest (warmth 0)")
expectEqual(SpeedBand(wpm: 1000).warmth, 1.0, "fastest band is warmest (warmth 1)")
expectEqual(SpeedBand(wpm: 650).warmth, 0.5, "midpoint band is half-warm")
expectEqual(SpeedBand(wpm: 100).warmth, 0.0, "below range clamps to 0")
expectEqual(SpeedBand(wpm: 2000).warmth, 1.0, "above range clamps to 1")

print("DeepLink")
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=Hello%20world")!)
    expectEqual(d, .text("Hello world"), "text param decodes to readable words")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=a%20%20b")!)
    expectEqual(d, .text("a  b"), "internal spacing preserved")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=")!)
    expectEqual(d, nil, "empty text -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=%20%20%20")!)
    expectEqual(d, nil, "whitespace-only text -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?url=https%3A%2F%2Fexample.com")!)
    expectEqual(d, .url("https://example.com"), "url param decodes")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=hi&url=https%3A%2F%2Fx.com")!)
    expectEqual(d, .text("hi"), "text wins when both params present")
}
do {
    let d = DeepLinkParser.parse(URL(string: "http://read?text=hi")!)
    expectEqual(d, nil, "wrong scheme -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://other?text=hi")!)
    expectEqual(d, nil, "wrong host -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read")!)
    expectEqual(d, nil, "no query items -> nil")
}
do {
    let big = String(repeating: "a", count: 120_000)
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=" + big)!)
    if case let .text(s)? = d {
        expectEqual(s.count, 100_000, "over-cap text truncated to maxTextLength")
    } else {
        expect(false, "over-cap text should still parse to .text")
    }
}

print("ImportedText")
do {
    expectEqual(ImportedText.sanitize("  hello world  "), "hello world",
                "trims surrounding whitespace")
    expectEqual(ImportedText.sanitize("\n\nLine one.\nLine two.\n"),
                "Line one.\nLine two.",
                "keeps interior newlines/punctuation, trims edges")
    expectEqual(ImportedText.sanitize(""), nil, "empty -> nil")
    expectEqual(ImportedText.sanitize("   \n\t  "), nil, "whitespace-only -> nil")
    // Unlike the deep-link parser, file import is uncapped — long docs stay whole.
    let big = String(repeating: "word ", count: 50_000)
    expectEqual(ImportedText.sanitize(big)?.count,
                big.trimmingCharacters(in: .whitespacesAndNewlines).count,
                "long text is not truncated")
}

print("ORP")
// Pivot index: deterministic, leans left and settles around the first third.
expectEqual(ORP.pivotIndex(for: "a"), 0, "single letter pivots on itself")
expectEqual(ORP.pivotIndex(for: "to"), 1, "2-letter word pivots on the 2nd")
expectEqual(ORP.pivotIndex(for: "cat"), 1, "short word pivots just left of center")
expectEqual(ORP.pivotIndex(for: "reading"), 2, "7-letter word pivots on the 3rd (first third)")
expectEqual(ORP.pivotIndex(for: "wonderful"), 2, "9-letter word still pivots on the 3rd")
expectEqual(ORP.pivotIndex(for: "incredible"), 3, "10-letter word pivots on the 4th")
expectEqual(ORP.pivotIndex(for: "extraordinary"), 3, "13-letter word pivots on the 4th")
expectEqual(ORP.pivotIndex(for: "internationalization"), 4, "very long word caps at the 5th")
// Punctuation must not shove the recognition point around.
expectEqual(ORP.pivotIndex(for: "cat,"), 1, "trailing comma doesn't move the pivot")
expectEqual(ORP.pivotIndex(for: "\"hello"), 2, "leading quote is skipped before counting")
expectEqual(ORP.pivotIndex(for: "12.5%"), 1, "numbers pivot deterministically too")
do {
    let p = ORP.split("reading")
    expectEqual(p.before, "re", "split: lead-in before the pivot")
    expectEqual(p.pivot, "a", "split: the locked pivot letter")
    expectEqual(p.after, "ding", "split: the tail after the pivot")
}
do {
    let p = ORP.split("a")
    expectEqual(p.before, "", "single letter: nothing before")
    expectEqual(p.pivot, "a", "single letter: it is the pivot")
    expectEqual(p.after, "", "single letter: nothing after")
}
do {
    let p = ORP.split("")
    expectEqual(p, ORP.Pivot(before: "", pivot: "", after: ""), "empty word splits to empties")
}

print("ReadingContext.fullText")
do {
    let tokens = Tokenizer.tokenize("Hello world. New sentence.")
    expectEqual(ReadingContext.fullText(tokens), "Hello world. New sentence.",
                "single paragraph joins with spaces")
}
do {
    let tokens = Tokenizer.tokenize("First para here.\n\nSecond para there.")
    expectEqual(ReadingContext.fullText(tokens), "First para here.\n\nSecond para there.",
                "paragraph breaks come back as blank lines")
}
expectEqual(ReadingContext.fullText([]), "", "no tokens -> empty string")

print("ReadingContext.proseMap")
do {
    // Repeated words: each "the" must map to its OWN occurrence, not the first
    // match a string search would find. This is the load-bearing guarantee.
    let tokens = Tokenizer.tokenize("the the the")
    let map = ReadingContext.proseMap(tokens)
    expectEqual(map.text, "the the the", "repeated words join with spaces")
    expectEqual(map.ranges.count, tokens.count, "one range per token")
    expectEqual(map.ranges.map(\.location), [0, 4, 8], "repeated words get distinct offsets")
    let ns = map.text as NSString
    for (i, range) in map.ranges.enumerated() {
        expectEqual(ns.substring(with: range), tokens[i].text, "range \(i) reads back its token")
    }
}
do {
    // A paragraph break is "\n\n" (2 UTF-16 units), so the next token's offset
    // advances by 2, not 1.
    let tokens = Tokenizer.tokenize("alpha beta\n\ngamma delta")
    let map = ReadingContext.proseMap(tokens)
    expectEqual(map.text, "alpha beta\n\ngamma delta", "paragraph break preserved")
    expectEqual(map.ranges[2].location, 12, "\\n\\n advances the offset by 2")
    expectEqual((map.text as NSString).substring(with: map.ranges[2]), "gamma",
                "first word after the break maps correctly")
}
do {
    // Begin/end: first range at 0, last range ends exactly at the string length.
    let tokens = Tokenizer.tokenize("one two three")
    let map = ReadingContext.proseMap(tokens)
    expectEqual(map.ranges.first?.location, 0, "first token starts at 0")
    let last = map.ranges.last!
    expectEqual(last.location + last.length, (map.text as NSString).length,
                "last range ends at the string end")
}
do {
    let map = ReadingContext.proseMap(Tokenizer.tokenize("solo"))
    expectEqual(map.text, "solo", "single token text")
    expectEqual(map.ranges, [NSRange(location: 0, length: 4)], "single token range")
}
do {
    let map = ReadingContext.proseMap([])
    expectEqual(map.text, "", "empty -> empty string")
    expect(map.ranges.isEmpty, "empty -> no ranges")
}
do {
    // fullText is now literally proseMap.text — guard the refactor.
    let tokens = Tokenizer.tokenize("First para here.\n\nSecond para there.")
    expectEqual(ReadingContext.fullText(tokens), ReadingContext.proseMap(tokens).text,
                "fullText and proseMap return the identical string")
}

print("TextHash")
expectEqual(TextHash.of("hello"), TextHash.of("hello"), "same text -> same hash (stable across calls)")
expect(TextHash.of("hello") != TextHash.of("Hello"), "different text -> different hash")
expectEqual(TextHash.of(""), TextHash.of(""), "empty hashes deterministically")

print("ReadItem.deriveTitle")
expectEqual(ReadItem.deriveTitle(from: "one two three"), "one two three", "short body is its own title")
expectEqual(ReadItem.deriveTitle(from: "  a  b   c  ", maxWords: 2), "a b…", "caps at maxWords with ellipsis, collapses spaces")
expectEqual(ReadItem.deriveTitle(from: "   \n  "), "Untitled", "blank body -> Untitled")

print("SkimStore — ideas")
do {
    let store = try SkimStore(path: ":memory:")
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    try store.insertIdea(ImprovementIdea(id: "i1", text: "Scrubber thumb too small",
                                         createdAt: t0, updatedAt: t0))
    try store.insertIdea(ImprovementIdea(id: "i2", text: "Word jitters on long words",
                                         sourceReadId: "r1", tokenIndex: 42, wpm: 650,
                                         contextSnippet: "…the long word here…",
                                         createdAt: t1, updatedAt: t1))
    let open = try store.ideas(status: .open)
    expectEqual(open.map(\.id), ["i2", "i1"], "open ideas come back newest-first")
    expectEqual(open.first?.tokenIndex, 42, "captured token index round-trips")
    expectEqual(open.first?.wpm, 650, "captured wpm round-trips")
    expectEqual(open.first?.contextSnippet, "…the long word here…", "context snippet round-trips")
    expectEqual(open.last?.sourceReadId, nil, "absent source read id stays nil")

    try store.updateIdeaText(id: "i1", text: "Scrubber thumb is too small", updatedAt: t1)
    expectEqual(try store.ideas(status: .open).first(where: { $0.id == "i1" })?.text,
                "Scrubber thumb is too small", "editing an idea persists the new text")

    try store.updateIdeaStatus(id: "i1", status: .done, updatedAt: t1)
    expectEqual(try store.ideas(status: .open).map(\.id), ["i2"], "marking done removes it from the open list")
    expectEqual(try store.ideas(status: .done).map(\.id), ["i1"], "done idea is findable under done")
    expectEqual(try store.ideas(status: nil).count, 2, "nil status returns every idea")

    try store.deleteIdea(id: "i2")
    expectEqual(try store.ideas(status: .open).count, 0, "delete removes the idea")
} catch {
    expect(false, "ideas store threw: \(error)")
}

print("SkimStore — read items")
do {
    let store = try SkimStore(path: ":memory:")
    let t0 = Date(timeIntervalSince1970: 10_000)
    let t1 = Date(timeIntervalSince1970: 20_000)
    let t2 = Date(timeIntervalSince1970: 30_000)
    try store.upsertReadItem(ReadItem(id: "r1", title: "First read", body: "alpha beta gamma",
                                      source: .manual, wordCount: 3, createdAt: t0, updatedAt: t0))
    try store.upsertReadItem(ReadItem(id: "r2", title: "Second read", body: "delta epsilon",
                                      source: .file, sourcePath: "/tmp/x.txt", wordCount: 2,
                                      createdAt: t1, updatedAt: t1))

    expectEqual(try store.recentReads(limit: 10).map(\.id), ["r2", "r1"], "recents are newest-updated first")
    expectEqual(try store.mostRecentActive()?.id, "r2", "most-recent-active is the latest active read")
    expectEqual(try store.readItem(id: "r1")?.body, "alpha beta gamma", "body round-trips intact")
    expectEqual(try store.readItem(id: "r2")?.source, ReadSource.file, "source enum round-trips")

    // Advancing r1's position bumps updated_at, so it floats to the top of recents.
    try store.updatePosition(id: "r1", tokenIndex: 2, wpm: 500, readingHand: "left", updatedAt: t2)
    let r1 = try store.readItem(id: "r1")
    expectEqual(r1?.lastTokenIndex, 2, "position update persists token index")
    expectEqual(r1?.lastWpm, 500, "position update persists wpm")
    expectEqual(r1?.readingHand, "left", "position update persists reading hand")
    expectEqual(try store.recentReads(limit: 10).map(\.id), ["r1", "r2"], "a position update refloats the read")

    try store.updateReadTitle(id: "r1", title: "Renamed read", updatedAt: t2)
    expectEqual(try store.readItem(id: "r1")?.title, "Renamed read", "renaming a read persists the new title")

    try store.markCompleted(id: "r2", tokenIndex: 1, completedAt: t2)
    let r2 = try store.readItem(id: "r2")
    expectEqual(r2?.status, ReadStatus.completed, "finishing sets status completed")
    expect(r2?.completedAt != nil, "finishing stamps completed_at")
    expectEqual(try store.mostRecentActive()?.id, "r1", "a completed read drops out of resume candidates")

    try store.deleteReadItem(id: "r1")
    expectEqual(try store.recentReads(limit: 10).map(\.id), ["r2"], "delete removes the read from recents")
} catch {
    expect(false, "read-items store threw: \(error)")
}

print("SpeedRamp — auto-start acceleration")
do {  // plain scope — these checks don't throw
    let ramp = SpeedRamp(fromWPM: 300, toWPM: 400, duration: 2.0)
    expect(ramp.isClimbing, "a 300→400 ramp has speed to climb")
    expectEqual(ramp.easedFraction(at: 0), 0.0, "starts at zero progress")
    expectEqual(ramp.easedFraction(at: 2.0), 1.0, "reaches full progress at duration")
    expectEqual(ramp.easedFraction(at: -1), 0.0, "clamps before the start")
    expectEqual(ramp.easedFraction(at: 99), 1.0, "clamps after the end")
    expectEqual(ramp.easedFraction(at: 1.0), 0.5, "smoothstep midpoint is half progress")

    // Opens at the floor, lands exactly on target.
    expectEqual(ramp.band(at: 0).wpm, 300, "opens at the slow floor")
    expectEqual(ramp.band(at: 2.0).wpm, 400, "lands exactly on the target band")
    // Snapped samples never overshoot the target and never dip below the floor.
    let samples = stride(from: 0.0, through: 2.0, by: 0.1).map { ramp.band(at: $0).wpm }
    expect(samples.allSatisfy { $0 >= 300 && $0 <= 400 }, "every ramp band stays within [floor, target]")
    // Monotonic non-decreasing: eased acceleration never steps backward.
    expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "ramp bands climb monotonically")
    // Every snapped band is a real detent (so the gauge stays valid).
    expect(samples.allSatisfy { wpm in SpeedBand.allCases.contains { $0.wpm == wpm } },
           "every ramp band is a real SpeedBand detent")

    // Degenerate ramps are no-ops that land on target.
    let flat = SpeedRamp(fromWPM: 400, toWPM: 400, duration: 2.0)
    expect(!flat.isClimbing, "a same-speed ramp has nothing to climb")
    let instant = SpeedRamp(fromWPM: 300, toWPM: 400, duration: 0)
    expect(!instant.isClimbing, "a zero-duration ramp has nothing to climb")
    expectEqual(instant.band(at: 0).wpm, 400, "a zero-duration ramp is already at target")
}

print("SpeedRamp — targets the configured cruising speed, not a fixed 400")
do {  // plain scope — these checks don't throw
    // The ramp is not tied to 400: it lands wherever the default cruising speed
    // points. From the floor, every configured target is reached exactly.
    let floor = SpeedBand.minWPM
    for target in [350, 400, 500, 650] {
        let r = SpeedRamp(fromWPM: floor, toWPM: SpeedBand.nearest(to: target).wpm, duration: 2.0)
        expectEqual(r.band(at: 0).wpm, floor, "ramp toward \(target) opens at the floor")
        expectEqual(r.band(at: 2.0).wpm, target, "ramp toward \(target) lands on \(target)")
    }

    // An out-of-range preference resolves (via `nearest`) before the ramp, so the
    // target clamps safely to the speed range.
    let tooHigh = SpeedRamp(fromWPM: floor, toWPM: SpeedBand.nearest(to: 5_000).wpm, duration: 2.0)
    expectEqual(tooHigh.band(at: 2.0).wpm, SpeedBand.maxWPM, "an over-max preference ramps only to the max")
    let tooLow = SpeedRamp(fromWPM: floor, toWPM: SpeedBand.nearest(to: 50).wpm, duration: 2.0)
    expect(!tooLow.isClimbing, "a sub-floor preference resolves to the floor — a no-op ramp")
    expectEqual(tooLow.band(at: 0).wpm, floor, "a floor-level target starts (and stays) at the floor")
}

print("PivotFitSolver — long-word safe-area fit")
do {  // plain scope — these checks don't throw
    // Geometry shared by these cases: a 390pt-wide screen, pivot locked at 110,
    // 16pt margins, font 52 down to a 30pt floor. Glyph ~30pt wide at base.
    let W = 390.0, anchor = 110.0, mL = 16.0, mR = 16.0, base = 52.0, minF = 30.0
    func solve(before: Double, pivot: Double, after: Double) -> PivotFit {
        PivotFitSolver.solve(beforeWidth: before, pivotWidth: pivot, afterWidth: after,
                             anchorX: anchor, totalWidth: W,
                             leftMargin: mL, rightMargin: mR,
                             baseFontSize: base, minFontSize: minF)
    }

    // A short word fits with room to spare: full size, pivot fixed, no shift.
    let short = solve(before: 30, pivot: 30, after: 60)
    expectEqual(short.fontSize, base, "a short word renders at full size")
    expectEqual(short.shift, 0, "a short word never shifts")

    // A long word that overflows at full size shrinks to fit — pivot still fixed.
    let long = solve(before: 96, pivot: 32, after: 320)   // ~"recommendation"
    expect(long.fontSize < base, "a long word reduces font size to avoid clipping")
    expect(long.fontSize >= minF, "the reduction stays at or above the readable floor")
    expectEqual(long.shift, 0, "a long word that fits when shrunk does not shift")
    // Verify it actually fits within the margins at the chosen size.
    let scale = long.fontSize / base
    let leftEdge = anchor - (96 + 16) * scale
    let rightEdge = anchor + (16 + 320) * scale
    expect(leftEdge >= mL - 0.5, "shrunk long word's left edge clears the left margin")
    expect(rightEdge <= W - mR + 0.5, "shrunk long word's right edge clears the right margin")

    // A pathological token that can't fit even at the floor: clamps to the floor and
    // shifts right just enough to reveal its start, never below min size.
    let huge = solve(before: 240, pivot: 32, after: 480)
    expectEqual(huge.fontSize, minF, "an unfittable token clamps to the minimum size, not below")
    expect(huge.shift > 0, "an unfittable token shifts to reveal its start")
    let hugeLeft = anchor - (240 + 16) * (minF / base) + huge.shift
    expect(abs(hugeLeft - mL) < 0.5, "the shift lands the left edge exactly on the margin")
}

print("ExportSpec.formatted — m:ss labels")
expectEqual(ExportSpec.formatted(0), "0:00", "zero -> 0:00")
expectEqual(ExportSpec.formatted(9), "0:09", "single-digit seconds zero-pad")
expectEqual(ExportSpec.formatted(102), "1:42", "102s -> 1:42 (the spec's example)")
expectEqual(ExportSpec.formatted(60), "1:00", "exactly a minute")
expectEqual(ExportSpec.formatted(599.4), "9:59", "rounds to nearest second")
expectEqual(ExportSpec.formatted(-5), "0:00", "negative clamps to 0:00")

print("ExportTimeline — pacing-driven video layout")
do {
    // Four words at 600 wpm = 0.1s each (multiplier 1.0), except the last word,
    // which is the paragraph end and earns the 2.8× breath -> 0.28s. The export
    // honors the real reader's rhythm exactly.
    let tokens = Tokenizer.tokenize("alpha beta gamma delta")
    let tl = ExportTimeline(tokens: tokens, wpm: 600, titleDuration: 0, endDuration: 1.8)
    expectClose(tl.tokenDurations, [0.1, 0.1, 0.1, 0.28], "plain words hold 60/wpm; the paragraph-final word gets the 2.8× breath")
    expectClose(tl.tokenStarts, [0.0, 0.1, 0.2, 0.3], "token starts are the running sum")
    expectClose(tl.readingDuration, 0.58, "reading length is the sum of token durations")
    expectClose(tl.totalDuration, 0.58 + 1.8, "no title -> reading + end card only")
    // Frame math: 2.38s at 30fps = 71.4 -> 71 frames.
    expectEqual(tl.totalFrames, 71, "totalFrames rounds totalDuration * fps")
}
do {
    // Pacing honors the real tokenizer rhythm: a period doubles the breath.
    let tokens = Tokenizer.tokenize("alpha beta. gamma delta")
    let tl = ExportTimeline(tokens: tokens, wpm: 600, titleDuration: 1.8, endDuration: 1.8)
    expectClose(tl.tokenDurations[1], 0.2, "sentence-ending word gets the 2.0× pause")
    expectClose(tl.readingStart, 1.8, "reading section starts after the title card")
    // Absolute-time phase lookup across all three sections.
    expectEqual(tl.phase(atTime: 0.5), .title, "early time lands on the title card")
    expectEqual(tl.phase(atTime: 1.8), .reading(tokenIndex: 0), "reading begins exactly at titleDuration")
    // rt = 0.25s into reading: durations 0.1, 0.2, 0.1, 0.1 -> starts 0, 0.1, 0.3, 0.4.
    // 0.25 falls in token 1's window [0.1, 0.3).
    expectEqual(tl.phase(atTime: 1.8 + 0.25), .reading(tokenIndex: 1), "mid-reading resolves the active token")
    expectEqual(tl.phase(atTime: 999), .end, "past the end -> end card")
}
do {
    // No title card means reading starts at t=0 (title phase never returned).
    let tokens = Tokenizer.tokenize("one two three four five")
    let tl = ExportTimeline(tokens: tokens, wpm: 300, titleDuration: 0, endDuration: 1.8)
    expectEqual(tl.phase(atTime: 0), .reading(tokenIndex: 0), "no title -> first word at t=0")
    expectEqual(tl.phase(atTime: -1), .reading(tokenIndex: 0), "negative time clamps to the first word")
    // Last frame of the reading section still resolves to the final token, not end.
    let lastReading = tl.readingDuration - 0.001
    expectEqual(tl.phase(atTime: lastReading), .reading(tokenIndex: tokens.count - 1),
                "just before the reading end is still the last word")
}

print("ReadingNavigation — rail flick clamping")
do {
    // A normal flick moves the full step in either direction.
    expectEqual(ReadingNavigation.jumpTarget(from: 40, by: 12, count: 100), 52, "forward jump adds the step")
    expectEqual(ReadingNavigation.jumpTarget(from: 40, by: -12, count: 100), 28, "rewind jump subtracts the step")
    // Edges never overshoot: a rewind near the top pins at 0, a forward near the
    // end pins at the last token — the cursor is never negative or past the end.
    expectEqual(ReadingNavigation.jumpTarget(from: 5, by: -12, count: 100), 0, "rewind past the start clamps to 0")
    expectEqual(ReadingNavigation.jumpTarget(from: 95, by: 12, count: 100), 99, "forward past the end clamps to count-1")
    expectEqual(ReadingNavigation.jumpTarget(from: 0, by: -12, count: 100), 0, "rewind at the very start stays at 0")
    expectEqual(ReadingNavigation.jumpTarget(from: 99, by: 12, count: 100), 99, "forward at the very end stays put")
    // A single-token read can't move; an empty read pins at 0 (safe no-op).
    expectEqual(ReadingNavigation.jumpTarget(from: 0, by: 12, count: 1), 0, "single token can't move")
    expectEqual(ReadingNavigation.jumpTarget(from: 0, by: -12, count: 0), 0, "empty read stays at 0")
}

print("ReaderGestures — zone resolution (both reading hands)")
do {  // plain scope — these checks don't throw
    // A 390pt screen with the production 0.42 rail fraction: rail spans 163.8pt on
    // the reading-hand edge, the rest is bare canvas. The zones must MIRROR exactly
    // between hands — same widths, opposite edges — and never overlap.
    let W = 390.0, cf = 0.42
    func zone(_ x: Double, left: Bool) -> GestureZone {
        ReaderGestures.zone(touchX: x, width: W, controlFraction: cf, leftHanded: left)
    }
    // Right-handed: rail hugs the trailing (right) edge.
    expectEqual(zone(10, left: false), .canvas, "right-hand: far-left touch is canvas")
    expectEqual(zone(195, left: false), .canvas, "right-hand: center touch is canvas")
    expectEqual(zone(380, left: false), .rail, "right-hand: far-right touch is the rail")
    expectEqual(zone(W * (1 - cf) + 1, left: false), .rail, "right-hand: just inside the right rail edge is rail")
    expectEqual(zone(W * (1 - cf) - 1, left: false), .canvas, "right-hand: just outside the rail is canvas")
    // Left-handed: rail hugs the leading (left) edge — the perfect mirror.
    expectEqual(zone(10, left: true), .rail, "left-hand: far-left touch is the rail")
    expectEqual(zone(195, left: true), .canvas, "left-hand: center touch is canvas")
    expectEqual(zone(380, left: true), .canvas, "left-hand: far-right touch is canvas")
    expectEqual(zone(W * cf - 1, left: true), .rail, "left-hand: just inside the left rail edge is rail")
    expectEqual(zone(W * cf + 1, left: true), .canvas, "left-hand: just outside the rail is canvas")
    // Symmetry: a point and its mirror land in matching zones across the two hands.
    for x in stride(from: 5.0, through: 385.0, by: 10.0) {
        let right = zone(x, left: false)
        let mirrored = zone(W - x, left: true)
        expectEqual(right, mirrored, "zone at x=\(x) mirrors its left-hand counterpart")
    }
    expectEqual(ReaderGestures.zone(touchX: 100, width: 0, controlFraction: cf, leftHanded: false),
                .canvas, "degenerate zero-width surface is all canvas")
}

print("ReaderGestures — global hold-to-read (anywhere on the surface)")
do {  // plain scope — these checks don't throw
    // Press-and-hold starts a precision read from a resting state, no matter where on
    // the surface it began — the model takes no zone, so left/center/right/word/context
    // are all identical. Mid-cruise it's a no-op (words already stream); mid-hold and
    // the idle/completed surfaces are inert.
    expectEqual(ReaderGestures.holdIntent(startState: .ready), .beginPrecisionRead, "hold from ready -> precision read")
    expectEqual(ReaderGestures.holdIntent(startState: .paused), .beginPrecisionRead, "hold from paused -> precision read")
    expectEqual(ReaderGestures.holdIntent(startState: .cruisePlaying), .none, "hold mid-cruise -> no precision read")
    expectEqual(ReaderGestures.holdIntent(startState: .precisionHeld), .none, "hold while already holding -> no-op")
    expectEqual(ReaderGestures.holdIntent(startState: .idle), .none, "hold on the idle surface -> no-op")
    expectEqual(ReaderGestures.holdIntent(startState: .completed), .none, "hold on the review screen -> no-op")
}

print("ReaderGestures — global tap semantics (symmetric, side-independent)")
do {  // plain scope — these checks don't throw
    // Double tap toggles cruise from any resting/cruising state; single tap is the
    // brake and ONLY does something while cruising. These hold for any surface point,
    // either hand — the model takes no side/zone argument, so symmetry is structural.
    expectEqual(ReaderGestures.tapIntent(.double, state: .ready), .toggleCruise, "double tap at ready -> enter cruise")
    expectEqual(ReaderGestures.tapIntent(.double, state: .paused), .toggleCruise, "double tap at paused -> resume cruise")
    expectEqual(ReaderGestures.tapIntent(.double, state: .cruisePlaying), .toggleCruise, "double tap while cruising -> exit cruise")
    expectEqual(ReaderGestures.tapIntent(.single, state: .cruisePlaying), .pauseCruise, "single tap while cruising -> brake")
    expectEqual(ReaderGestures.tapIntent(.single, state: .ready), .none, "single tap at rest -> no-op (no accidental start)")
    expectEqual(ReaderGestures.tapIntent(.single, state: .paused), .none, "single tap while paused -> no-op")
    expectEqual(ReaderGestures.tapIntent(.double, state: .precisionHeld), .none, "double tap mid-hold -> no-op")
    expectEqual(ReaderGestures.tapIntent(.double, state: .completed), .none, "double tap on the review screen -> no-op")
    expectEqual(ReaderGestures.tapIntent(.single, state: .idle), .none, "single tap on the idle screen -> no-op")
}

print("ReaderGestures — rail-only steering (slide/flick, gated by start zone)")
do {  // plain scope — these checks don't throw
    // Steering is the rail's exclusive job: a slide/flick fires only when the gesture
    // BEGAN in the rail zone and a live session is in progress. A canvas-started
    // gesture never steers, so a hold-to-read out on the bare surface can't drift the
    // speed or fire a skip.
    expectEqual(ReaderGestures.steerIntent(.slide, startZone: .rail, startState: .cruisePlaying), .changeSpeed, "rail slide mid-cruise -> speed change")
    expectEqual(ReaderGestures.steerIntent(.slide, startZone: .rail, startState: .ready), .changeSpeed, "rail slide at rest -> speed change")
    expectEqual(ReaderGestures.steerIntent(.flickBack, startZone: .rail, startState: .cruisePlaying), .rewind, "rail flick ← mid-cruise -> rewind 12")
    expectEqual(ReaderGestures.steerIntent(.flickForward, startZone: .rail, startState: .precisionHeld), .forward, "rail flick → while held -> forward 12")
    // Canvas-started steering is always inert — the bare surface never steers.
    for steer in [RailSteer.slide, .flickBack, .flickForward] {
        for state in [ReaderState.ready, .paused, .cruisePlaying, .precisionHeld] {
            expectEqual(ReaderGestures.steerIntent(steer, startZone: .canvas, startState: state), .none,
                        "canvas-started \(steer) in \(state) never steers")
        }
    }
    // No steer ever brakes or toggles cruise — taps own those alone.
    for steer in [RailSteer.slide, .flickBack, .flickForward] {
        for zone in [GestureZone.rail, .canvas] {
            for state in [ReaderState.ready, .paused, .cruisePlaying, .precisionHeld] {
                let intent = ReaderGestures.steerIntent(steer, startZone: zone, startState: state)
                expect(intent != .toggleCruise && intent != .pauseCruise && intent != .beginPrecisionRead,
                       "steer \(steer) (\(zone)) in \(state) never leaks a tap/hold action")
            }
        }
    }
    // No steering on the idle/completed surfaces, even from the rail.
    expectEqual(ReaderGestures.steerIntent(.slide, startZone: .rail, startState: .idle), .none, "no steering on the idle surface")
    expectEqual(ReaderGestures.steerIntent(.flickForward, startZone: .rail, startState: .completed), .none, "no steering on the review screen")
}

print("ReadTimeEstimate")
do {
    // Compact formatting bands.
    expectEqual(ReadTimeEstimate.compact(42), "0:42", "under a minute → 0:SS")
    expectEqual(ReadTimeEstimate.compact(5), "0:05", "pads single-digit seconds")
    expectEqual(ReadTimeEstimate.compact(102), "1:42", "single minutes → m:ss")
    expectEqual(ReadTimeEstimate.compact(599), "9:59", "just under ten minutes stays m:ss")
    expectEqual(ReadTimeEstimate.compact(600), "10 min", "ten minutes → whole minutes")
    expectEqual(ReadTimeEstimate.compact(1440), "24 min", "long reads → whole minutes")
    expectEqual(ReadTimeEstimate.compact(0), "0:00", "empty read → 0:00")

    // Seconds sum uses the real per-token multipliers, so it exceeds the flat
    // word-count estimate for punctuated, multi-paragraph prose.
    let tokens = Tokenizer.tokenize("the quick brown fox")
    let paced = ReadTimeEstimate.seconds(tokens: tokens, wpm: 400)
    let expectedPaced = tokens.reduce(0.0) { $0 + (60.0 / 400.0) * $1.delayMultiplier }
    expectClose(paced, expectedPaced, "sums real paced durations")
    expect(paced > 4.0 * (60.0 / 400.0),
           "paced estimate exceeds the flat word-count estimate (trailing paragraph pause)")
    expectEqual(ReadTimeEstimate.seconds(tokens: [], wpm: 400), 0, "empty stream → 0s")

    // Speed scales the estimate inversely — a faster cruising speed ⇒ shorter time.
    let slow = ReadTimeEstimate.seconds(tokens: tokens, wpm: 300)
    let fast = ReadTimeEstimate.seconds(tokens: tokens, wpm: 600)
    expect(slow > fast, "lower WPM yields a longer estimate")
    expectClose(slow, fast * 2, "halving WPM doubles the estimate")

    // End-to-end convenience path tokenizes then estimates.
    expectClose(ReadTimeEstimate.seconds(text: "the quick brown fox", wpm: 400), paced,
                "text convenience matches token-stream estimate")
}

print("Comprehension Models")
do {
    expectEqual(ChoiceKey.allCases.count, 4, "four choice keys")
    expectEqual(QuestionType.mainPoint.rawValue, "main_point", "main_point raw value")
    expectEqual(QuestionType.supportingDetail.rawValue, "supporting_detail", "supporting_detail raw value")
    expectEqual(QuestionType.pressureTest.rawValue, "pressure_test", "pressure_test raw value")
    expectEqual(ComprehensionGenerationKind.generateMore.rawValue, "generate_more", "generate_more raw value")
    expectEqual(ComprehensionStatus.notStarted.rawValue, "not_started", "not_started raw value")

    let choices = ComprehensionChoices(a: "alpha", b: "bravo", c: "charlie", d: "delta")
    expectEqual(choices.text(for: .c), "charlie", "choices.text(for:) reads the right slot")
    expectEqual(choices.all, ["alpha", "bravo", "charlie", "delta"], "choices.all is a..d in order")

    // A draft decoded from the exact JSON shape the model returns.
    let json = """
    {"questions":[{"question":"Q?","choices":{"a":"A","b":"B","c":"C","d":"D"},
      "correctChoice":"b","explanation":"because B.","supportingQuote":"the supporting words here",
      "type":"main_point"}]}
    """.data(using: .utf8)!
    let draft = try! JSONDecoder().decode(ComprehensionCheckDraft.self, from: json)
    expectEqual(draft.questions.count, 1, "draft decodes one question")
    expectEqual(draft.questions[0].correctChoice, .b, "draft decodes correctChoice")
    expectEqual(draft.questions[0].type, .mainPoint, "draft decodes type from snake_case")
}

print("QuestionPlan")
do {
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 149), 0, "<150 → no check")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 150), 1, "150 → 1 (manual)")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 349), 1, "349 → 1")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 350), 2, "350 → 2")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 900), 3, "900 → 3")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 1999), 3, "1999 → 3")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 2000), 5, "2000 → 5")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 50000), 5, "huge → 5")

    expectEqual(QuestionPlan.types(forCount: 1), [.mainPoint], "1 → main point")
    expectEqual(QuestionPlan.types(forCount: 2), [.mainPoint, .supportingDetail], "2 → main+support")
    expectEqual(QuestionPlan.types(forCount: 3), [.mainPoint, .supportingDetail, .implication], "3 → +implication")
    expectEqual(QuestionPlan.types(forCount: 5),
                [.mainPoint, .supportingDetail, .supportingDetail, .implication, .implication],
                "5 → main, 2x support, 2x implication")
    expectEqual(QuestionPlan.generateMoreTypes(),
                [.supportingDetail, .implication, .pressureTest], "generate-more mix")

    // Eligibility: all four flags AND ≥350 words AND no existing initial check.
    expect(QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "eligible when all conditions hold")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 349, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "349 words is below auto threshold")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: false, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "AI disabled blocks pre-gen")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: false,
            hasKey: true, hasInitialCheck: false), "missing consent blocks pre-gen (no modal on paste)")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: false, hasInitialCheck: false), "missing key blocks pre-gen")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: true), "existing check blocks duplicate pre-gen")

    expectEqual(QuestionPlan.initialCacheKey(textHash: "abc", model: "m1", promptVersion: 1),
                "abc|m1|1", "initial cache key includes promptVersion")
    let pid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    expectEqual(QuestionPlan.generateMoreCacheKey(parentCheckId: pid, model: "m1", promptVersion: 1, batchIndex: 2),
                "00000000-0000-0000-0000-000000000001|m1|1|2", "generate-more key shape")
}

print("QuoteNormalize")
do {
    // Curly quotes and apostrophes → straight.
    expectEqual(QuoteNormalize.normalize("the \u{201C}data\u{201D} pipeline\u{2019}s edge"),
                "the \"data\" pipeline's edge", "curly quotes/apostrophes normalized")
    // En/em dash and minus → hyphen.
    expectEqual(QuoteNormalize.normalize("a\u{2014}b \u{2013} c \u{2212}d"), "a-b - c -d", "dash variants → hyphen")
    // NBSP and newlines and tabs collapse to single spaces.
    expectEqual(QuoteNormalize.normalize("the\u{00A0}data\tpipeline\n\nchanged"),
                "the data pipeline changed", "nbsp/tab/newline collapse")
    // Leading/trailing whitespace and punctuation trimmed.
    expectEqual(QuoteNormalize.normalize("  ...the pipeline changed.  "),
                "the pipeline changed", "edge punctuation/space trimmed")
    // Idempotence: normalizing twice equals normalizing once.
    let once = QuoteNormalize.normalize("  \u{201C}A\u{2014}B\u{201D}  pipeline\u{00A0}edge. ")
    expectEqual(QuoteNormalize.normalize(once), once, "normalize is idempotent")
}

print("ComprehensionValidation")
do {
    let source = """
    Skim helps users finish long text faster without feeling lost. If getting text into the
    app is not instant, it becomes a cool demo instead of a daily reflex that people reach for.
    """
    func q(_ quote: String,
           choices: ComprehensionChoices = .init(a: "one", b: "two", c: "three", d: "four"),
           question: String = "What is the main point?",
           explanation: String = "Because the passage says so.") -> ComprehensionQuestionDraft {
        .init(question: question, choices: choices, correctChoice: .a,
              explanation: explanation, supportingQuote: quote, type: .mainPoint)
    }

    // A clean, grounded, right-length quote (10 words) passes. It's a contiguous
    // prefix of the source, ending just before the first period.
    let good = ComprehensionCheckDraft(questions: [q("Skim helps users finish long text faster without feeling lost")])
    expect(ComprehensionValidation.validate(good, requestedCount: 1, sourceText: source).isEmpty,
           "valid grounded draft passes")

    // A real excerpt with a non-breaking space spliced in still grounds — the NBSP
    // normalizes to a regular space before the substring check.
    let typo = ComprehensionCheckDraft(questions: [q("becomes a cool demo instead of a daily\u{00A0}reflex that people reach for")])
    expect(ComprehensionValidation.validate(typo, requestedCount: 1, sourceText: source).isEmpty,
           "typography-tolerant grounding accepts a real excerpt")

    // Wrong count.
    expectEqual(ComprehensionValidation.validate(good, requestedCount: 2, sourceText: source).first,
                .wrongCount(got: 1, want: 2), "rejects wrong count")

    // Fabricated quote (not in source).
    let fake = ComprehensionCheckDraft(questions: [q("the quick brown fox jumped over the lazy sleeping dog twice")])
    expectEqual(ComprehensionValidation.validate(fake, requestedCount: 1, sourceText: source).first,
                .quoteNotGrounded(index: 0), "rejects ungrounded quote")

    // Too-short quote (3 words).
    let short = ComprehensionCheckDraft(questions: [q("Skim helps users")])
    expectEqual(ComprehensionValidation.validate(short, requestedCount: 1, sourceText: source).first,
                .quoteWrongLength(index: 0, words: 3), "rejects sub-8-word quote")

    // Duplicate answer choices within a question.
    let dupChoice = ComprehensionCheckDraft(questions: [q(
        "Skim helps users finish long text faster without feeling lost",
        choices: .init(a: "same", b: "same", c: "x", d: "y"))])
    expectEqual(ComprehensionValidation.validate(dupChoice, requestedCount: 1, sourceText: source).first,
                .duplicateChoices(index: 0), "rejects duplicate choices")

    // Duplicate questions across the set.
    let g = q("Skim helps users finish long text faster without feeling lost")
    let dupQ = ComprehensionCheckDraft(questions: [g, g])
    expectEqual(ComprehensionValidation.validate(dupQ, requestedCount: 2, sourceText: source).first,
                .duplicateQuestion(first: 0, second: 1), "rejects duplicate questions")
}

print("")
if failures.isEmpty {
    print("All checks passed ✅")
} else {
    print("\(failures.count) check(s) FAILED ❌")
    for f in failures { print("  - \(f)") }
    exit(1)
}
