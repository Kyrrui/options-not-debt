# UI Cleanup Handoff — make it inviting, not intimidating

> For the dapp builder. This **supersedes the options-chain framing in
> ui-spec §3.E for the MVP**. The current build exposes the full
> combinatorial space (e.g. Trade = 4 leverage types × 5 expiries) and
> explains the un-ready paths with walls of text. That's backwards. Goal:
> a first-time visitor does the main thing in ~10 seconds without learning
> options, and *wants* to try it.

## The one rule that fixes ~80% of it

**Only show what has a working one-click action. Everything that needs a
paragraph to be usable gets hidden behind an "Advanced" toggle or cut until
it actually works.** A wall of text next to a control is the UI confessing
that path isn't ready — don't explain it better, remove it from the default
view.

## Trade tab (the priority — this is where the pain is)

**Today there is exactly ONE clean leverage market:** Long ETH-vs-USD, via
the LeverageRouter (`0xe942843535Cf19272a576023588FF01a7Fce9556`, spUSD).
The other 19 cells have no pool/router, so the only way to "open" them is the
raw split-and-hold-P path — that's what's generating the walls of text. So:

- **Default Trade = one card, one market.** Long ETH. Drop the grid.
- **Leverage = presets, not a strike picker:** `2× / 5× / 10×` (map to strike
  behind the scenes; only offer presets the router actually supports).
- **One primary button:** `Open Long`.
- **Exactly four numbers, from a live quote — no prose:**
  - You pay: ~`X` ETH
  - Max loss: your premium (that's the most you can lose)
  - Liquidation: **None**
  - Expires: `<date>`
- If the pool price deviates from fair, **one inline warning line**, not a
  paragraph (e.g. "⚠ pool price is off — quote may be poor").
- All teaching ("what's a call / theta / how leverage works here") lives
  behind a small **"How this works"** link. Never inline, never blocking.
- **Gold / BTC / other expiries: do not render** until each has its own
  pool + router. Then they appear as *identical* simple cards. No half-built
  markets in the default view.
- The raw strike+expiry grid and the manual split path move behind an
  **"Advanced / build a custom position"** toggle, clearly labelled "manual,
  for power users."

Target card:

```
┌────────────────────────────────────────┐
│  Long ETH        liquidation-proof · no funding │
│                                          │
│  Leverage:   [ 2× ]   [ 5× ]   [ 10× ]   │
│                                          │
│  You pay ~0.005 ETH                      │
│  Max loss  your premium                  │
│  Liquidation  none                       │
│  Expires  Jul 11                         │
│                                          │
│            [  Open Long  ]               │
│            How this works ›              │
└────────────────────────────────────────┘
```

## Saver / spUSD tab (if shown) — same treatment, even simpler

One action, one sentence, zero finance vocabulary:

```
  spUSD — a dollar backed by ETH.   1 spUSD ≈ $1.00
  [ Deposit ETH ]   [ Withdraw ]
  Your balance: 250 spUSD (~$250)
```

Never show on this path: P, N, leg, strike, series, NAV, intrinsic, drift,
soft-peg, option, settle, roll, auction, oracle. Those belong in an
**"Under the hood"** view that is **off by default** for the curious.

## Jargon rules

- **Saver path:** zero options/protocol jargon (list above).
- **Trade path:** trader words are OK and expected — *leverage, premium,
  expires, max loss, long*. Everything deeper (call/put, theta, P/N, strike
  mechanics, settlement) is behind "How this works."
- Replace mechanism-speak with outcomes: "Long ETH with no liquidation risk"
  not "acquire the N leg of the option series."

## Progressive disclosure (the global pattern)

1. One plain primary action per screen + at most one sentence of what it is.
2. Depth is opt-in: a `?` tooltip or a "How this works" / "Advanced" link.
3. The transparency we want for trust (auctions, oracle status, series,
   rolls) goes on a dedicated **"Under the hood"** page, **off by default** —
   present for those who look, invisible to those who don't.

## Tone

Confident and plain. Short sentences. The visitor should feel *smart and in
control*, never small. If a screen makes a normal person feel they need a
finance degree, it's wrong — cut until it doesn't.

## Definition of done

- A first-time visitor can open a leverage position (or deposit) in one
  obvious action without reading a paragraph.
- No wall of text anywhere on a default screen.
- Only markets with a working one-click path are visible by default.
- Everything advanced/explanatory still exists — one toggle/link away.
