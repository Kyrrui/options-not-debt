# "Cash out" (withdraw) redesign — implementation handoff

> For the dapp builder. Fixes the misleading withdraw UX: today `redeem`
> returns ~no ETH and mostly redeemable option tokens that settle later, but
> the card promises "take it out whenever / you get back $X" as if it's
> instant cash. Replace one dishonest button with two honest doors.

## Framing (the rule)

There is **no instant-cash-at-full-value exit** — spUSD is fully invested in
the stable leg, so the DAO holds ~no idle ETH. So offer two clearly-labeled
doors, each showing its real number, and never silently route a saver into a
lossy one:

- **Redeem** = the *guaranteed* exit. Full value, oracle-free, can't be
  blocked, but converts to ETH at settlement (not instant). This is the
  protocol's headline safety property — **always visible, never hidden.**
- **Sell now** = the *convenience*. Instant ETH at market price via the
  spUSD/WETH pool. Great when the pool's healthy, gated when it isn't.

Today (thin pool) **lead with Redeem**; once deep NAV liquidity + the keeper
MM are live, flip the emphasis to Sell-now. Do not let Sell-now be the only
door (it breaks when the pool is thin, and it discards the redeem guarantee).

## File

`apps/web/src/components/tracker/SaverCard.tsx` — the default saver path.
Rename the "Withdraw" mode to **"Cash out."** The under-the-hood
`RedeemCard`/`DepositCard` can stay as they are.

## Copy to delete

- "take it out whenever"
- "you get back about $X" (rendered as if it's cash in hand)

New headline line: **"Sell anytime on the market, or redeem for full value
at settlement."**

## Door A — "Sell now" (instant ETH, Uniswap passthrough)

MVP mechanism = **deep-link to Uniswap** (don't build/maintain swap+approve
in-app yet):

- URL pattern (VERIFY the exact param names against current Uniswap — they
  drift; this is the one external thing to confirm):
  `https://app.uniswap.org/swap?chain=sepolia&inputCurrency=<TRACKER_ADDR>&outputCurrency=NATIVE&value=<amount>&field=input`
  - `inputCurrency` = the tracker address (the DAO **is** the share ERC-20),
    e.g. spUSD `0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE`.
  - `outputCurrency` = `NATIVE` (ETH).
  - Only spUSD has a pool today; render Sell-now only for trackers that have
    a live pool (you already detect this — see below).
- **In-app comparison + gate (read-only, before the deep-link):** reuse the
  existing `usePoolMarket(dao)` hook (it already reads the pool spot/basis for
  MarketPanel). Compute:
  - `instantValue ≈ amount × poolSpot` (per-share ETH at market)
  - `fullValue = amount × perShare` (NAV — the same `perShare` SaverCard
    already computes)
  - Show both: **"Sell now ≈ $96 · Full value (redeem) ≈ $100."**
  - **Enable + recommend Sell-now only when** `instantValue ≥ 0.98 ×
    fullValue` AND `amount ≤ POOL_DEPTH_CAP` (a config fraction of the pool's
    spUSD reserve — start ~10% so price impact stays small). Otherwise
    **disable it** with: *"Market's too thin for a fair price right now —
    redeem for full value instead."*
  - This is a small-amount approximation (spot, no impact). Note it; the
    accurate quote happens on Uniswap at execution.
- Slippage is Uniswap's problem in the deep-link path. (If you later embed
  the swap: SwapRouter02 `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`,
  `exactInputSingle` with a real `amountOutMinimum`, then unwrap WETH
  `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` → ETH; QuoterV2
  `0xEd1f6473345F45b75F8179591dd5bA1888cf2FBB` for accurate in-app quotes —
  **verify QuoterV2.factory() == 0x0227628f3F023bb0B980b67D528571c95c6DaC1c
  before trusting that address.**)

## Door B — "Redeem" (guaranteed full value, settles later)

Mechanism = the **existing** `redeem(shares)` on the DAO (already in
SaverCard's withdraw mode). Always enabled — it's oracle-free. The only
change is **honest copy + a hand-off to position tracking**, because `redeem`
returns a small ETH amount now (the buffer share, usually ~0) plus
**redeemable tokens that convert to ETH at the series' settlement** (and
currently need a follow-up claim — they are not auto-converted).

- Preview copy (reuse `redeemBasket`'s `ethOut`):
  *"Redeem your full ≈ $X. ≈ Z ETH lands now; the rest comes as redeemable
  tokens that turn into ETH at settlement (by ~Jul 11). This always works —
  even with no buyer around."*
- **After a successful redeem, route the user to their positions** (the
  existing `PositionPanel` / `MyLegs`) so they can track those tokens and
  claim the ETH once the series settles. Do **not** leave a non-expert
  holding unexplained `P-…` tokens with no next step.
- Jargon: "redeemable tokens / settlement" is the minimum honest leak — it's
  literally what happens — so it's allowed here; pair it with a `?` tip. Keep
  everything else outcome-worded.

## Default layout (today)

Inside "Cash out": amount input, then both doors with their live numbers,
**Redeem emphasized as primary**, Sell-now secondary and gated. When the pool
becomes deep/near-NAV, swap the emphasis (config flag is fine).

## Flagged (not a UI fix)

The *quality* of Sell-now depends on pool depth held near NAV — that's an ops
problem (seed liquidity + run the keeper MM), not something the UI can solve.
Say so plainly in "Under the hood" so a sophisticated user/investor sees it's
understood, not hidden.

## Also: ship the watchAsset fix

The already-built "Track in wallet" / `wallet_watchAsset` change is greenlit
— deploy it; it's unrelated to this and a clear win.
