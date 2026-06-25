# Comprehension Checks (BYOK V0) — Design

**Date:** 2026-06-25
**Status:** Approved design, pre-implementation
**Author:** Joe + Claude (brainstorm)

## Purpose

After a long read, let the user generate an **optional** multiple-choice comprehension
check. The goal is **trust, not grading**: confirm the reader kept the thread while reading
fast. It must never make Skim feel like school, and must never interrupt active RSVP reading.

This is a **BYOK (bring-your-own-key) V0**. The app ships with **no developer-owned OpenAI
key**. The user supplies their own key, stored locally in the iOS Keychain. Per OpenAI's
key-safety guidance, an app-owned key in a client app would have to be proxied through a
backend — out of scope for V0.

The V0 question we're proving: **do optional comprehension checks make users trust Skim more?**

### Decisions locked (this session)

1. **Shipped user feature**, not a personal calibration tool. No private WPM×score dataset in V0.
2. **Pre-generation fires on paste/import** (text-load), quietly and non-blocking.
3. **Answer-trust hardening is in scope**: strict structured outputs + grounded answer
   citations + a "this seems off" escape.
4. **Read time stays an estimate** (`words ÷ wpm`), reworded honestly — no real-elapsed
   stopwatch in V0.

### Review edits applied (2026-06-25)

Design approved with edits: (1) added `promptVersion` to the model + all cache keys;
(2) resolved the structured-outputs-vs-repair contradiction into *one schema-constrained
regeneration retry*; (3) normalize source+quote before the substring check;
(4) strengthened Settings privacy copy to name background upload; (5) consent is requested
only on the first manual tap, never during paste/import; (6) `supportingQuote` is a short
verbatim excerpt (8–40 words), not necessarily a full sentence; (7) softened the ≤33% label
from "Too fast" to "Thread got shaky"; (8) normalized SQLite tables instead of one JSON blob;
(9) "Test Key" hits the configured model; (10) don't over-cancel background jobs — guarantee
results attach only to the correct `readId`.

## Non-goals (V0)

Backend proxy · Skim-hosted credits · subscriptions · multiple providers · Deep Check ·
spaced repetition · accounts · cloud sync · auto-quizzing mid-read · analytics dashboard ·
real elapsed-time tracking · auto-adjusting the user's speed.

---

## Codebase fit (verified)

This drops into existing structure rather than inventing storage:

- **Read entity already exists:** `ReadItem` (`Sources/SkimCore/SkimStore.swift:79`) has
  `id`, `textHash`, `wordCount`, `source`, `lastWpm`, `status`, `createdAt/completedAt`.
- **Persistence is SQLite** at `Application Support/skim.sqlite` via `SkimStore` /
  `AppStore`. Comprehension checks become a **new table**, not a new store.
- **Single text-entry chokepoint:** all paste/clipboard/deep-link/file paths funnel through
  `ReaderViewModel.load(_:source:sourcePath:)` → `recordLoadedRead()`
  (`App/ReaderViewModel.swift:473/497`). This is where pre-generation is triggered.
- **Completion hook:** `ReaderViewModel.finish()` (`:1047`) sets `state = .completed`, which
  renders `ReviewView` — the end screen that gains the "Check understanding" CTA.
- **Settings pattern:** `App/SettingsView.swift` + observable props on `ReaderViewModel`
  backed by `UserDefaults` (`skim.*` keys). New rows follow this pattern.
- **New surfaces (first in the app):** networking (zero `URLSession` today) and Keychain
  (zero `SecItem` today). This is the app's first code that sends user data off-device.

---

## Architecture

### Core vs App split (per repo convention)

Pure, UI-free, Foundation-only logic lives in **`Sources/SkimCore`** and is covered by
`CoreChecks` assertions (verifiable with `swift run CoreChecks`, no Xcode). UIKit/SwiftUI/
networking/Keychain live in **`App/`**.

**SkimCore (pure, tested):**
- `Comprehension/Models.swift` — all `Codable` models (below).
- `Comprehension/QuestionPlan.swift` — word-count → question-count buckets; eligibility
  predicate; question-type allocation.
- `Comprehension/Chunking.swift` — long-read sampling on paragraph/sentence boundaries.
- `Comprehension/Validation.swift` — response structure validation + dedup.
- `Comprehension/Scoring.swift` — score computation + score → speed-guidance mapping.

**App (impure):**
- `Comprehension/KeychainAPIKeyStore.swift` — `APIKeyStore` over iOS Keychain.
- `Comprehension/OpenAIComprehensionProvider.swift` — `ComprehensionQuestionProvider` impl.
- `Comprehension/ComprehensionService.swift` — orchestrates generation, owns in-flight
  tasks keyed by `readId`, persists results to `SkimStore`.
- `Comprehension/ComprehensionCheckViewModel.swift` — drives the check UI.
- Views: settings rows, consent sheet, generating/answering/result screens.
- `SkimStore` gains a `comprehension_checks` table + CRUD.

### Provider abstraction

```swift
protocol ComprehensionQuestionProvider {
    func generateQuestions(
        text: String,
        title: String?,
        plan: QuestionPlan,            // counts + type allocation + "avoid these" for more
        apiKey: String
    ) async throws -> ComprehensionCheckDraft
}
```

V0 ships only `OpenAIComprehensionProvider`. The protocol keeps Claude/Gemini/backend/
local-model swappable later. Views never touch OpenAI directly.

---

## Data model (SkimCore, `Codable`)

```swift
struct ComprehensionCheck: Identifiable, Codable {
    let id: UUID
    let readId: String                 // matches ReadItem.id (String/UUID)
    let textHash: String
    let model: String
    let promptVersion: Int             // bump when prompt/schema/validation/mix changes;
                                       // invalidates stale cached questions. Starts at 1.
    let generatedAt: Date
    let kind: ComprehensionGenerationKind
    let parentCheckId: UUID?           // generateMore batches link to their initial check
    let batchIndex: Int                // 0 = initial; 1,2,… = generate-more batches
    var questions: [ComprehensionQuestion]
    var completedAt: Date?
    var score: Int?                    // count correct
}

struct ComprehensionQuestion: Identifiable, Codable {
    let id: UUID
    let question: String
    let choices: ComprehensionChoices  // a/b/c/d
    let correctChoice: ChoiceKey
    let explanation: String
    let supportingQuote: String        // grounding: short verbatim excerpt (8–40 words),
                                       // a normalized substring of the source (decision #3)
    let type: QuestionType
    var sourceStartTokenIndex: Int?    // nil-ok in V0; enables "show where this came from"
    var sourceEndTokenIndex: Int?
}

struct ComprehensionChoices: Codable { let a, b, c, d: String }
enum ChoiceKey: String, Codable { case a, b, c, d }

enum QuestionType: String, Codable {
    case mainPoint = "main_point"
    case supportingDetail = "supporting_detail"
    case implication
    case pressureTest = "pressure_test"
}

enum ComprehensionGenerationKind: String, Codable { case initial, generateMore }

enum ComprehensionStatus: String, Codable {
    case unavailable    // too short or AI disabled
    case notStarted     // eligible, but no key/consent or not yet generated
    case generating
    case ready
    case answered
    case failed
}
```

`supportingQuote` is **new vs the original tickets** — required by decision #3 for grounding.

### Persistence

**Normalized SQLite** (three tables) rather than one JSON blob — chosen so the "this seems
off" flag, per-answer state, and "review missed" stay clean as the feature grows:

- `comprehension_checks` — one row per generated batch: `id`, `readId`, `textHash`, `model`,
  `promptVersion`, `kind`, `parentCheckId`, `batchIndex`, `generatedAt`, `completedAt`,
  `score`.
- `comprehension_questions` — one row per question (FK `checkId`): text, choices a–d,
  `correctChoice`, `explanation`, `supportingQuote`, `type`, `sourceStart/EndTokenIndex`,
  `disputed` (the "seems off" flag).
- `comprehension_answers` — one row per user answer (FK `questionId`): `selectedChoice`,
  `answeredAt`, `isCorrect`.

`ComprehensionStatus` and the available/answered counters are derived from these rows on
load — no separate metadata row.

**Reuse / idempotency keys** — both **include `promptVersion`**, so tuning the prompt,
schema, validation, or question mix invalidates stale cached questions instead of leaving
old ones looking "valid forever":

- **initial check:** `textHash + model + promptVersion`. If a matching initial check exists,
  reuse it; otherwise generate.
- **generate-more batch:** `parentCheckId + model + promptVersion + batchIndex`.

A generation already in-flight for a `readId` is never duplicated.

---

## API key storage (Keychain)

```swift
protocol APIKeyStore {
    func saveOpenAIKey(_ key: String) throws
    func loadOpenAIKey() throws -> String?
    func deleteOpenAIKey() throws
    func hasOpenAIKey() -> Bool
}
```

Rules: key **only** in Keychain — never UserDefaults, logs, analytics, crash reports, or
debug overlays. Mask after save (`sk-••••••abcd`). Redact request-error output that could
echo headers. **"Test Key" issues a tiny structured-output request against the *configured
model*** (not `GET /v1/models`), so it validates the key + model access + the actual
request/response path in one shot.

---

## Settings

New section in `SettingsView`:

```
AI Features
  → OpenAI API Key
```

Detail screen:
> **AI Comprehension Checks**
> Use your own OpenAI API key to generate optional comprehension questions after a read.
> Your key is stored locally in iOS Keychain. Skim does not provide API credits.
> When AI comprehension checks are enabled, eligible pasted/imported reads may be sent to
> OpenAI in the background so questions are ready when you finish.

Fields/actions: API Key input · **Test Key** · **Save Key** · **Delete Key**. A master
toggle `aiComprehensionEnabled` (UserDefaults `skim.ai.enabled`) gates all generation.

---

## Consent

Consent is shown **only on the first manual "Check understanding" tap — never during
paste/import.** A privacy modal must not interrupt the core paste-and-read flow. Pre-gen
therefore requires consent to be *already* accepted (see the eligibility predicate): before
the user has ever accepted, no read is pre-generated, and the text is uploaded for the first
time only when they explicitly open a check and accept. After acceptance, future eligible
reads pre-gen on load. Persist `aiComprehensionConsentAccepted` (UserDefaults).

> Comprehension checks send this read's text to OpenAI using your API key.
> Because pre-generation runs when you load text, the text may be sent as soon as you paste
> or import it — not only when you open a check.
> Your key is stored locally in iOS Keychain. Skim does not provide API credits.
> You can delete your key anytime in Settings.
> [Continue] [Cancel]

The "sent when you paste" line is **explicit** because decision #2 uploads text at load time.

---

## Eligibility, thresholds, question counts

`wordCount = tokens.count` (already on `ReaderViewModel`/`ReadItem`).

| Words        | Auto pre-gen? | Initial questions |
|--------------|---------------|-------------------|
| < 150        | no (unavailable) | — |
| 150–349      | no (manual only) | 1 (manual) |
| 350–900      | yes           | 2 |
| 900–2,000    | yes           | 3 |
| 2,000–4,000  | yes           | 5 |
| 4,000+       | yes           | 5 |

This **replaces** the original "200 words" trigger. Question-type allocation:

- 1 → `main_point`
- 2 → `main_point`, `supporting_detail`
- 3 → `main_point`, `supporting_detail`, `implication`
- 5 → `main_point`, `supporting_detail`, `supporting_detail`, `implication`, `implication`

**Eligibility predicate** (pure, in SkimCore):
```
wordCount >= 350
  && settings.aiComprehensionEnabled
  && settings.aiConsentAccepted
  && apiKeyStore.hasOpenAIKey()
  && !comprehensionStore.hasInitialCheck(textHash:)
```

---

## Pre-generation flow (decision #2: on paste/import)

In `recordLoadedRead()`, after the `ReadItem` is upserted and `currentReadId` set:

```swift
if QuestionPlan.shouldPreGenerate(wordCount:, settings:, hasKey:) {
    comprehensionService.preGenerateInitialCheck(readId:, text:, title:, textHash:)
}
```

Constraints:
- **Never blocks** load/tokenize/reader launch. No loading UI on paste.
- Runs as a cancellable async task **owned by `ComprehensionService`, keyed by `readId`**.
- **Lifecycle (no over-cancel):** the hard requirement is **no cross-read contamination** —
  a completed result attaches **only** to its originating `readId`. Cancel a job only when
  its read is cleared/deleted/replaced before the result persists. Merely navigating away
  (e.g. to Recents and back) does **not** cancel; if the read still exists when the request
  returns, persist the result by `readId`. Never write a result onto the wrong read.
- In-flight + existing-check guards prevent duplicate jobs.
- No optional "check ready" indicator in V0 (deferred).

---

## End-of-read flow

`ReviewView` gains a primary **Check understanding** action alongside existing
**Read Again** / **Back to Recents**. Behavior by status at finish:

- **ready** → opens the check instantly.
- **generating** → opens the answering screen showing `Building your check…` (calm, with
  `Cancel`), then questions when ready.
- **notStarted, no key** → `Add an OpenAI API key to use comprehension checks.`
  `[Open Settings] [Cancel]`
- **notStarted, no consent** → consent sheet, then generate manually.
- **failed** → `Couldn't build a check automatically.` `[Try again] [Cancel]`

Read-time line on this screen stays the **estimate**, reworded to not imply a stopwatch
(e.g. `420 words · ~2 min read`) — decision #4.

---

## Question UI

One question at a time.

```
1 of 3
What is the main product risk if ingestion is too slow?
 a. …   b. …   c. …   d. …
```

After selecting: mark choice → reveal correct answer → show **explanation**, which includes
the **grounded supporting quote** ("The passage says: '…'") → `Next`. Keep gamification
minimal.

**"This seems off" escape (decision #3):** each question carries a subtle affordance to flag
it. Flagging marks the item as disputed (excluded from the trust-framing of the score) so a
bad key reads as the tool's miss, not the user's failure. V0 stores the flag locally; no
upload.

---

## Result screen

```
3 / 3
Clean comprehension.
Your current speed looks good for this kind of text.
[Done] [Review missed] [Generate more]
```

Score language (pure mapping in SkimCore `Scoring`):
- 100% → "Clean comprehension." / "Your current speed looks good for this kind of text."
- ~67% → "Mostly kept the thread." / "Consider slowing slightly for dense reads."
- ≤33% → "Thread got shaky." / "This one may have been too fast. Try dropping 50–100 WPM on
  similar text." (Avoid an accusatory "Too fast" as the primary label — question quality is
  imperfect.)

**Never auto-changes speed** in V0 — recommendation only. (Disputed/flagged questions are
excluded from the denominator so a bad item doesn't push a false "too fast.")

---

## Generate more (user-initiated only)

Adds 3 questions: `supporting_detail`, `implication`, `pressure_test`. The prompt includes
the existing questions with "do not duplicate these" and prefers deeper angles
(implications/tradeoffs/risks/consequences). Each batch is its own `comprehension_checks`
row with `kind = generateMore`, `parentCheckId` = the initial check, and an incrementing
`batchIndex` (keyed `parentCheckId + model + promptVersion + batchIndex`). Caps: **soft 8**,
**hard 12** per read. Auto pre-generation is always just the initial check.

---

## OpenAI provider

- **Endpoint:** Chat Completions (or Responses) with **Structured Outputs** —
  `response_format` = strict `json_schema` matching the question array. No free-form JSON
  parsing or "repair" of malformed text, ever.
- **Default model:** a small, cheap model (gpt-4o-mini-class), stored on the check and
  configurable later. Not hard-coded into views.
- **Prompt intent:** generate MCQs that test the main thread, not trivia; exactly 4 choices
  a/b/c/d; exactly one correct; include a **`supporting_quote`** — a short verbatim excerpt
  (≈8–40 words) from the source that supports the correct answer; return only the structured
  object.
- **Validation (SkimCore, pure):** `questions.count == requested`; non-empty question;
  exactly choices a/b/c/d; `correctChoice ∈ {a,b,c,d}`; non-empty, reasonably short
  explanation; valid type; **`supporting_quote` is 8–40 words and a *normalized* substring of
  the source** (see normalization below); no duplicate questions; no duplicate choices within
  a question.
- **On validation/decode/API failure: exactly one schema-constrained regeneration retry** —
  same `json_schema`, with a stricter system/developer instruction. This is a clean re-ask,
  **not** a JSON-repair pass. If the retry still fails →
  `Couldn't build a clean check for this read.`

**Quote normalization (applied to both source and quote before the substring check):**
collapse runs of whitespace (including newlines) to single spaces; normalize curly quotes
(`' ' " "`) to straight; normalize dash variants (en/em) to `-`; strip non-breaking spaces;
trim leading/trailing punctuation and whitespace. Strict enough to require real grounding,
tolerant enough to survive typography. The normalization is itself a pure, tested SkimCore
function and is idempotent.

### Chunking (long reads)

`≤ 4,000 words`: send full text. `> 4,000`: sample representative chunks (beginning / early-
middle / middle / late-middle / ending) on paragraph boundaries, falling back to sentence
boundaries, never mid-sentence; target ~500–700-word chunks; ≤1 question per chunk by
default; cap 5. Token-index source mapping may stay `nil` in V0.

---

## Failure handling

| Case | Copy |
|------|------|
| No key | `Add an OpenAI API key to use comprehension checks.` `[Open Settings] [Cancel]` |
| Invalid key | `That API key did not work. Check it or replace it in Settings.` |
| Network | `Couldn't reach OpenAI. Check your connection and try again.` |
| Rate limit / quota | `OpenAI rejected the request, likely due to rate limits or quota on your API key.` |
| Bad JSON / schema | Repair retry once; else `Couldn't build a clean check for this read.` |
| Too short (<150 words) | `This read is too short for a useful check.` |

---

## Concurrency (Swift 6 strict)

`ReaderViewModel` is `@MainActor @Observable`. `ComprehensionService` owns generation off the
main actor (provider does async URLSession work), hopping results back to `@MainActor` to
update store + observable status. Tasks are keyed by `readId`; results attach only to their
originating `readId` (cancel only on clear/delete/replace before persistence — not on mere
navigation). No shared mutable state crosses actors without isolation.

---

## Privacy / App Store

This is the app's first off-device data flow. Required: an App Store **privacy manifest**
disclosure that read text + derived data are **sent off device** (to OpenAI, under the
user's own key); consent copy that's explicit text is uploaded **on paste** (decision #2);
no key/text in logs or crash reports. Info.plist needs no ATS exception (OpenAI is HTTPS).

---

## Test plan (CoreChecks, no Xcode)

Add assertions for the pure pieces:
- `QuestionPlan`: word-count → count buckets at every boundary (149/150/349/350/900/2000/
  4000); type allocation per count; `shouldPreGenerate` truth table over the flags.
- `Chunking`: <4000 returns full text; >4000 returns 5 boundary-aligned chunks, never
  mid-sentence; chunk size bounds.
- `Normalization`: curly→straight quotes, dash variants→`-`, NBSP removal, whitespace
  collapse, punctuation trim — and idempotence (normalize∘normalize == normalize).
- `Validation`: rejects wrong count, empty fields, missing/dup choices, bad `correctChoice`,
  invalid type, dup questions, quotes outside 8–40 words, and **non-substring
  `supporting_quote` after normalization** — while *accepting* a good quote that differs from
  the source only by curly quotes / em dashes / NBSP / collapsed whitespace.
- `Scoring`: count→percent→guidance mapping at 100/67/33 (incl. the softened ≤33% copy);
  disputed questions excluded from the denominator.

App-layer pieces (Keychain, OpenAI client, view model, SwiftUI) are exercised manually /
later XCTest once full Xcode is assumed.

---

## Acceptance criteria

- Add/test/save/delete an OpenAI key in Settings; **"Test Key" validates the key against the
  configured model** via a tiny structured request; key lives in Keychain, never UserDefaults.
- App ships with **no** developer-owned key.
- Eligible reads (≥350 words, AI enabled, key + consent-already-accepted) start initial
  generation **asynchronously on paste/import**; reader launch is **never** delayed; no
  paste-time loading UI.
- **Consent is requested only on the first manual "Check understanding" tap, never during
  paste/import.** Before consent is accepted, no read is pre-generated; after acceptance,
  eligible reads pre-gen on load.
- Adaptive question count per the table; MCQs a/b/c/d, one at a time, immediate feedback.
- Each answer's explanation includes a **grounded supporting quote** (8–40 words) that is a
  normalized substring of the text; a fabricated quote fails validation, but typography-only
  differences (curly quotes, dashes, NBSP, whitespace) do not.
- A question can be flagged "this seems off"; flagged items are excluded from the score.
- End screen: ready → instant; generating → calm loading; failed → manual retry.
- Result screen shows score + **recommendation only** (never auto-changes speed).
- "Generate more" is user-initiated, non-duplicating, capped (soft 8 / hard 12).
- Checks persist locally (normalized tables) and reuse for the same
  `textHash + model + promptVersion`; bumping `promptVersion` invalidates stale cached
  questions; no duplicate in-flight jobs; results attach only to their originating `readId`.
- Network/key/rate-limit/schema failures handled gracefully.
- No comprehension check ever interrupts active RSVP reading.
- The feature does not make Skim feel like school.

---

## Open risks

1. **Hallucinated answer keys** remain the top risk even with grounding + escape; the
   substring-quote validation and flag affordance are mitigations, not a cure. Watch real
   usage for false "wrong" verdicts.
2. **Pre-gen on paste spends the user's money and uploads text for abandoned reads** (chosen
   tradeoff, decision #2). Revisit if cost/privacy complaints surface — `on first read-start`
   is the fallback.
3. **Recency confound:** a quiz right after reading partly measures short-term memory, not
   durable comprehension. Fine for a trust signal; do not over-read the score.
