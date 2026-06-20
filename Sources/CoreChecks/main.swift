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
expectEqual(SpeedBand.cruise.wpm, 400, "default cruise opens at a calm 400 wpm")
expectEqual(SpeedBand.cruise.label, "Cruise", "default opens in the Cruise band, never Blast")
expectEqual(SpeedBand.imported.wpm, 400, "explicit imports open at a brisk 400 wpm, not a slow 200")
expectEqual(SpeedBand.imported.wpm, SpeedBand.cruise.wpm, "import default agrees with a cold-start cruise")
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

print("")
if failures.isEmpty {
    print("All checks passed ✅")
} else {
    print("\(failures.count) check(s) FAILED ❌")
    for f in failures { print("  - \(f)") }
    exit(1)
}
