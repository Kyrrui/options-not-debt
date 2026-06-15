# Leverage on every market — handoff

> For the dapp builder. Decision: every peg gets a Leverage option, surfaced as
> it's spun up. The leverage contract is already auto-provisioned per peg
> (`PeripheryFactory.deploy_periphery` deploys a `LeverageRouter`), so this is a
> UI job. The ONE thing you must get right: **label and frame the leverage by
> the actual underlying — ETH vs the tracker's asset — not generic "Long ETH."**
> Refines the Leverage section (A3) of `gimbal-frontend-handoff.md`.

## What the leverage actually is (read first — this is the trap)

The index is `x = ETH priced in the tracker's asset = (ETH/USD) ÷ (ASSET/USD)`.
The N (leverage) leg is a leveraged long on **`x` = ETH/asset**. So the multiple
is always ~2× (at strike ratio 0.5) and the collateral is always ETH, but the
**exposure differs per market**:

| Peg | N is a 2× long on | In plain words |
|---|---|---|
| spUSD | ETH/USD | "long ETH" (the classic) |
| spXAU | ETH/gold | ETH **outperforms gold** |
| spBTC | ETH/BTC | ETH **outperforms BTC** (the "ETH season" trade) |

Only spUSD's leverage is literally "long ETH." The others are **relative-value /
ratio trades**. Showing "Long ETH 2×" on the spBTC screen is simply wrong and
will burn trust. Always render **"Long ETH / {ASSET} · 2×"** and explain the bet
("you profit if ETH gains vs {ASSET}").

All of them share the good properties: **liquidation-proof, no funding, capped
downside (you can't lose more than the premium).**

Honest note to surface: non-USD pairs are **niche and thinner** (a ratio bet is
milder and has less demand than long-ETH), so expect shallow liquidity on those
leverage markets — see the depth indicator below.

## Provisioning (already done at the contract layer)

- **`LeverageRouter` is auto-deployed per peg** by `PeripheryFactory.deploy_periphery(tracker, fee)`
  (lifecycle step 4). So every market that completes the lifecycle already has a
  working leverage router. The UI just surfaces it.
- Discover it: `PeripheryFactory.get_router(tracker, 3000)`. If `is_deployed`
  is false, the peg hasn't finished setup — show the "Launch periphery" panel
  (master handoff B10), not a broken Leverage tab.
- **Flash variant** (`FlashLeverageRouter`, "send exactly your premium") is
  currently **spUSD-only** (standalone `0x0a48A236b899ca5a14b6b7C348E37adB4Ae3e0df`).
  Use it where available; for other markets, use the standard router until the
  flash variant is added to the factory as a blueprint. (Optional follow-up:
  add it as a 3rd PeripheryFactory blueprint so it's universal too.)

## The Leverage screen, parameterized by the market

Drive the whole screen off the tracker's asset — nothing hardcoded to USD:

Reads:
- `assetId = tracker.ASSET()` → `OracleHub.feeds(assetId)` → `(aggregator, heartbeat, symbol)`. Symbol = `"USD"` for the sentinel (`assetId == 0x0`), else e.g. `"XAU"`/`"BTC"`.
- `x = OracleHub.latest_price(assetId)` (ETH in asset units, 1e18). For USD this is the ETH price; for gold it's oz/ETH; etc.
- active series: `tracker.active_series()` → `ISeries(series).STRIKE()` (asset units, 1e18), `MATURITY()`.

Computed display (all in **asset units**, label by symbol):
- **Multiple** = `1 / (1 − STRIKE/x)` (~2× at fresh strike).
- **Premium / Max loss** = what the caller pays (the N value), capped — "all of it if ETH is below the strike vs {ASSET} at {date}."
- **Breakeven** = the `x` (ETH/asset) at which the position recovers the premium → render as "ETH needs to gain ~Y% vs {ASSET} (to {x_breakeven} {unit}) by {date}." For spUSD this reads "to ~$1,745"; for spBTC "to ~0.0X BTC/ETH," etc.
- **Payoff curve:** position value vs `x` (ETH/asset), strike + breakeven + now marked, x-axis in asset units. Optionally overlay a USD axis via the ETH/USD feed, but the native axis is the asset.

**Generalize the existing helper:** `breakevenIndexUsd` (and the payoff math from
the payoff-return fix) are USD-specific — parameterize them by asset so the
return and the price-move are in the **same numéraire** (the earlier "2× reads as
sub-1×" bug was exactly a numéraire mismatch; don't reintroduce it per-asset).

## Copy / honesty rules

- Headline: **"Long ETH / {ASSET} · 2×"** + "liquidation-proof, no funding."
- One line on the bet: "Profit if ETH rises against {ASSET}." (For spUSD: "Profit if ETH rises.")
- Max loss = the premium, stated plainly.
- **Depth indicator:** reuse the liquidity-impact/price-impact helper on the
  P-sink swap; non-USD leverage markets will be thin, so show the price impact
  and warn above a threshold rather than hiding it.
- Keep the *Sepolia testnet · research code, unaudited* tag.
- Tie into the certified/user-created layer: a user-created peg's leverage gets
  the same `Unverified` treatment + warning gate as its Hold/Provide surfaces.

## On-chain reference

| UI need | Call |
|---|---|
| router for a peg | `PeripheryFactory.get_router(tracker, 3000)` (check `is_deployed` first) |
| open leverage | `LeverageRouter.open_leverage(min_eth_out)` (min ≠ 0) |
| open leverage (flash, spUSD) | `FlashLeverageRouter.open_leverage(flash_amount, min_eth_out)` payable, msg.value = premium |
| what the peg tracks | `tracker.ASSET()` → `OracleHub.feeds(assetId)` → `(aggregator, heartbeat, symbol)` |
| index x (ETH/asset) | `OracleHub.latest_price(assetId)` |
| strike / expiry | `tracker.active_series()` → `ISeries.STRIKE()` / `MATURITY()` |
| multiple / breakeven / payoff | `1/(1−STRIKE/x)`; asset-parameterized `breakevenIndex`; payoff vs x |

Net: surface Leverage on every market (the router's already there), but render it
as the **ETH/{ASSET} 2× ratio trade it actually is**, with asset-denominated
strike/breakeven/payoff and a depth warning — never a generic "Long ETH."
