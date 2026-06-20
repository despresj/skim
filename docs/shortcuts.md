# Read in Skim — iOS Shortcuts

Skim accepts text and URLs through its `skim://read` deep link, so any Shortcut
that opens one of these URLs feeds the reader:

- `skim://read?text=<url-encoded text>` → reader opens directly in **On mode**
  (hands-free cruise) at **400 wpm** and starts reading immediately — no paste
  prompt, no thumb start. A single tap pauses.
- `skim://read?url=<url-encoded url>` → calm **"Link received"** card with
  **Open Link** (article extraction is coming; v1 doesn't RSVP raw URLs).

Rules baked into the app (`DeepLinkParser`):
- `text` wins if a link carries both `text` and `url`.
- Empty / whitespace-only input is ignored — Skim opens to its normal entry
  screen, never an error, never a crash.
- Text over 100,000 characters is truncated.

---

## ⭐ Read in Skim (Share Sheet) — the primary flow

Select text in any app (ChatGPT, Safari, Notes, Mail…), tap **Share**, tap
**Read in Skim**, and Skim opens straight into On mode at 400 wpm, already
reading that text hands-free.

**Build it in the Shortcuts app → New Shortcut:**

1. Open the shortcut's settings (ⓘ / "Details"):
   - Turn **on** "Show in Share Sheet".
   - Under **Share Sheet Types**, accept **Text** (and **URLs** if you want the
     URL branch below). Turn the rest off.
2. Name it **Read in Skim**.

**Actions (text-only, simplest — covers the selected-text flow):**

1. **Receive** _Text and URLs_ input from Share Sheet (auto-added when "Show in
   Share Sheet" is on).
2. **URL Encode** — input: **Shortcut Input**.
3. **Text** — value: `skim://read?text=` immediately followed by the
   **URL Encoded** result (insert it as a variable; no space between).
4. **Open URLs** — input: the **Text** from step 3.

That's it. Selecting text anywhere and tapping **Read in Skim** opens Skim in
On mode at 400 wpm, already reading. Empty selections fail quietly.

### Optional: prefer the URL path when a URL is shared

If you also want a *shared URL* (not selected prose) to land on the "Link
received" card instead of being read word-by-word, branch on whether the input
contains a URL:

1. **Receive** _Text and URLs_ input from Share Sheet.
2. **Get URLs from Input** — input: **Shortcut Input**.
3. **If** — _Count_ of the URLs from step 2 _is greater than_ `0`:
   - **URL Encode** — input: the **URLs** (use the first / the list item).
   - **Text** — `skim://read?url=` + **URL Encoded**.
   - **Open URLs** — the Text.
4. **Otherwise**:
   - **URL Encode** — input: **Shortcut Input**.
   - **Text** — `skim://read?text=` + **URL Encoded**.
   - **Open URLs** — the Text.
5. **End If**.

Skip this branch if you'd rather selected URL *text* just be read as text — the
text-only version above does exactly that.

---

## Companion Shortcuts (run from the home screen / widgets)

These don't need the Share Sheet — they're quick launchers.

### Read Clipboard in Skim
1. **Get Clipboard**
2. **URL Encode** — input: Clipboard
3. **Text** — `skim://read?text=` + **URL Encoded**
4. **Open URLs** — the Text

### Read URL in Skim
Accepts a URL as Shortcut input (or from the Share Sheet, if enabled).
1. **URL Encode** — input: Shortcut Input
2. **Text** — `skim://read?url=` + **URL Encoded**
3. **Open URLs** — the Text

### Read Text in Skim
Accepts text as Shortcut input.
1. **URL Encode** — input: Shortcut Input
2. **Text** — `skim://read?text=` + **URL Encoded**
3. **Open URLs** — the Text

---

## Manual acceptance checklist

Trigger each via the Share Sheet, a Shortcut, or by pasting the URL into Safari's
address bar:

- [ ] Select text in ChatGPT/Safari/Notes → Share → **Read in Skim** appears.
- [ ] Tapping it opens Skim **already reading in On mode at 400 wpm** — no tap to
      start. A single tap pauses.
- [ ] `skim://read?text=Hello%20world` on **cold launch** (force-quit first) →
      opens reading "Hello world" hands-free at 400 wpm.
- [ ] Same link while **already running** → swaps in the new text and starts
      reading it in On mode.
- [ ] Same link from **background** (not quit) → foregrounds and starts reading
      the text; the clipboard re-read does **not** replace it.
- [ ] `skim://read?url=https%3A%2F%2Fexample.com` → "Link received" card; **Open
      Link** opens Safari; **Copy Link** copies; **Not now** returns to paste
      screen; the reader is untouched.
- [ ] `skim://read?text=` (empty) → no crash; lands on the paste screen.
- [ ] `skim://read?garbage` → no crash; lands on the paste screen.
