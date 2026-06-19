# Skim — Brand, Color & Logo Brief

*Design direction for the visual designer. Prepared 2026-06-19.*

This document hands off two things: a **formalized color system** (already
partly built into the app) and a **logo / app-icon brief** with concept
directions. It deliberately stops at color + logo — typography, motion, and
gesture UX live in `rsvp_casual_reader_spec.md`. Read that spec for product
context; read this for what to make.

---

## 1. Brand Essence

> **A calm, clipboard-first reading instrument — reading by lamplight, one
> thumb, no chrome.**

A user copies text, opens Skim, holds a thumb on the right edge, and words
stream by at a relaxed rhythm. It is a *casual flow-reading* instrument, **not a
speed-reading app**. Every visual decision should feel like dimming the lights
to read, not opening a productivity dashboard.

**Three anchors — every design choice should serve at least one:**

- **Calm** — warm, low-contrast-where-it-counts, nothing competes with the word.
- **Physical** — controls are gestures (hold, slide, flick); the brand should
  feel tactile and lamp-lit, not digital and flat.
- **Effortless** — zero setup, zero configuration anxiety. The mark and palette
  should read as "sit back," not "lean in."

**Anti-brand — explicitly avoid:**

- Speed-reading / productivity tropes: speedometers, stopwatches, lightning
  bolts, motion-blur "fast" streaks.
- Gamification, metrics, scores, aggressive reds or alert colors.
- Eye / eyeglasses / "vision" clichés.
- Cold, clinical, high-tech-blue SaaS aesthetics.

If a choice makes the app feel like a *test* or a *tool for performance*, it is
wrong. It should feel like a *quiet instrument for comfort*.

---

## 2. Color System

The app ships a system-aware palette nicknamed **"reading by lamplight"**: warm
paper in light mode, a warm near-black lit by a luminous gold accent in dark
mode. Neutrals sit on a **single warm ramp** (no dead grays, no green cast) so
the darks glow rather than glare, and the **reading anchor shares the accent
gold** — the whole surface speaks one warm color language. This section
formalizes it into a real spec. **These hex values are the source of truth**
(derived from `App/Theme.swift`) — please match them, or propose deliberate
refinements with rationale.

### 2.1 Core tokens

Each token is semantic (named by role, not by color) so the palette can shift
without renaming. Values are given for both appearances.

| Token | Role | Dark | Light |
|---|---|---|---|
| **Background** | Base canvas (warm near-black / paper) | `#11100D` | `#FBF7F0` |
| **Surface** | Lifted cards, inputs, sheets | `#211F1B` | `#FFFFFF` |
| **Border** | Hairline separators | `white @ 10%` | `black @ 8%` |
| **Foreground** | Primary text / the word (warm) | `#F5F2ED` | `#211C17` |
| **Muted** | Hints, placeholders, secondary (warm gray) | `#9A958C` | `#6B665E` |
| **Accent (gold)** | Actions, buttons, glow, progress | `#FAC26B` | `#A86B14` |
| **OnAccent** | Text/icons on top of accent | `#1A1610` | `#FFFFFF` |
| **Pivot** | The ORP anchor letter — **shares the accent** | `#FAC26B` | `#A86B14` |

Borders are intentionally specified as **alpha over the background** (not solid
hex) so they stay as a hairline at any surface depth.

### 2.2 Canvas gradient

The background is never flat. A faint warm glow sits at the top and settles into
the deep base — "a lamp just out of frame." Full-bleed, behind every screen.

- **Dark:** linear top→bottom, `#29241C` → `#11100D` → `#11100D`.
- **Light:** linear top→bottom, `#FFFAF2` → `#FBF7F0` → `#FBF7F0`.

The glow lands in the top ~⅓; the lower two stops are identical so the word sits
on a calm, even field.

### 2.3 One color language (single accent)

Skim speaks **one warm voice**. A single gold — luminous `#FAC26B` in dark,
deep bronze `#A86B14` in light — does every accent job, and the reading anchor
shares it:

- The gold is the *touch* color in **chrome the user acts on**: the primary
  button, the progress line, the soft glow, speed overlays. Warm = the hand, the
  control, the lamp.
- The same gold is the *eye* color on the single **ORP pivot letter** inside the
  streaming word — the fixed point the eye rests on.

Earlier drafts used a second, cool-blue hue for the pivot; that has been
**deliberately retired**. One color keeps the reading surface calm and coherent
— the pivot now stands out by **weight and a faint glow, not by a clashing hue**.
**Rule for the designer:** resist introducing a second accent color. If the
pivot needs more emphasis, reach for weight, size, or glow before a new hue.

### 2.4 Contrast / accessibility notes

- Foreground-on-Background must clear **WCAG AA for body text** in both modes
  (the current `#F5F2ED`/`#11100D` and `#211C17`/`#FBF7F0` pairs do, comfortably).
- The light bronze accent (`#A86B14`) is deepened specifically so **white-on-accent
  meets AA** — keep white as the OnAccent in light mode, not a tint.
- The streaming word is large (48–64pt), so the gold pivot only needs **large-text
  AA** — current values pass, but verify any refinement at the pivot's actual size.
- The accent is a **chrome/affordance** color, not body text. When text sits *on*
  the accent fill, use the OnAccent token, not Foreground.
- Never encode meaning in color alone (no color-only state); pair with motion,
  position, or haptics.

### 2.5 Alternate accent explorations

The gold is the recommended, shipped direction. For the designer to react
against — **swap the Accent token (and, with it, the matching Pivot)**, keep
every neutral the same — here are two alternates in the same calm, lamp-lit
family. These are *options to compare*, not a request to change.

| Alt accent | Mood | Dark | Light | OnAccent |
|---|---|---|---|---|
| **A — Gold (current)** | Warm lamplight, cozy | `#FAC26B` | `#A86B14` | dark / white |
| **B — Sage** | Quiet, restful, "paper & plant" | `#A8C7A1` | `#5E8157` | dark / white |
| **C — Clay** | Muted terracotta, earthy warmth | `#D9A48A` | `#B06A4C` | dark / white |

Because the design now runs on a **single accent**, the pivot follows whichever
accent is chosen — so each alternate stays internally consistent (one warm voice),
exactly like the shipped gold. The light-mode value of any alternate must stay
deep enough for **white-on-accent AA**, as the bronze does.

---

## 3. Logo & App-Icon Brief

### 3.1 What we need

- A primary **app icon** (the dominant surface — this is an iOS app).
- A **standalone mark** that survives outside the rounded-rect (splash, web,
  favicon, marketing).
- Optional **wordmark** pairing "Skim" for marketing contexts.

### 3.2 Hard requirements

- **iOS app-icon grid / 1024×1024 master**, no transparency, no rounded corners
  baked in (the OS masks).
- **Legible at 40px** (Settings/Spotlight) and recognizable at 1024px.
- **No text inside the icon mark** — the glyph must carry it alone.
- Works on **both** brand backgrounds: warm paper `#FBF7F0` and warm near-black
  `#11100D`. Provide the icon on a brand-appropriate field (gold-glow near-black
  is the expected hero).
- Single focal idea — readable in **under one second**. RSVP is about one point
  of focus; the icon should be too.
- Use the brand palette: the warm gold accent against near-black or paper. **One
  color** doing the work beats a gradient zoo — and matches the app's single-accent
  identity (no second hue).

### 3.3 Deliverables

- `1024×1024` master (layered source + flattened PNG).
- Monochrome / single-color version (for small sizes, share sheets, tinting).
- Standalone mark on transparent background (SVG preferred).
- Mark shown on both warm-paper and near-black fields.
- Wordmark lockup (horizontal) if a wordmark is explored.

### 3.4 Do / Don't

**Do:** lean into *calm* and *focus*; use the warm-glow / lamplight feeling; let
one shape hold still (mirrors the ORP anchor); embrace negative space.

**Don't:** speedometers, stopwatches, lightning bolts, motion-blur streaks,
arrows-going-fast, eyes, eyeglasses, open books (overused), gradients that scream
"AI app," or anything that implies *performance pressure*. Fast is not the story
— **calm flow** is.

### 3.5 Concept directions (explore these — not final art)

Four starting metaphors, each tied to something real in the product. The
designer should push, combine, or reject them.

1. **The Pivot.**
   Built from the ORP anchor — the one letter the eye rests on while words
   stream past. A single **gold dot or letterform held still**, with a warmer or
   dimmer stroke flowing through or past it (one hue, distinguished by weight and
   glow — mirroring how the app now renders the pivot). Says "one calm point of
   focus." Most conceptually honest to how RSVP works.

2. **Lamplight.**
   The "reading by lamplight" metaphor made abstract: a **soft amber crescent,
   arc, or aperture** — light spilling from just off-frame onto a dark field.
   Warm, cozy, zero tech-tropes. Pairs beautifully with the near-black hero
   background and the existing glow gradient.

3. **The Thumb Rail.**
   Geometry from the physical control — the invisible right-edge hold zone. A
   **vertical bar paired with a flowing horizontal mark**: the thumb that holds,
   the words that flow. Emphasizes the one-thumb, physical-instrument identity.

4. **Flow Mark (typographic).**
   A letterform **"F"** (Skim) or **"S"** (skim, the repo name) where the
   counter or a cut becomes a **streaming-word slot** — a small window the word
   passes through. Calm, ownable, distinct in a grid of app icons. Safest path to
   a clean wordmark lockup.

**Recommended starting point:** explore **#1 The Pivot** and **#2 Lamplight**
first — they are the two most native to the product's soul (focus + calm) and
both use the existing palette without invention. #3 and #4 are strong fallbacks
if those don't yield a distinctive mark.

---

## 4. Quick Reference (hand to the designer)

- **Essence:** calm, physical, effortless — reading by lamplight, not speed-reading.
- **Hero look:** warm near-black `#11100D` with a luminous gold glow; warm paper
  `#FBF7F0` is the light-mode twin.
- **One color language:** a single gold (`#FAC26B` dark / `#A86B14` light) does
  every accent job *and* the focus letter — no second hue.
- **Icon:** one idea, no text, no speed tropes, legible at 40px, on both fields.
- **Start concepts with:** The Pivot, Lamplight.
