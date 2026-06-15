# Launching with the least liquidity — survey + recommendation

> Goal: smallest seed capital to make a peg *usable* (buy & sell spUSD near $1,
> buy leverage), fewest tradeoffs. Surveyed 6 mechanism families / 21 candidates,
> each scored against the code. 0 were "free lunch"; 13 conditional. This is the
> honest map and the recommended minimal stack.

## The one finding everything converged on

**The buy side is ~free; the clean *exit* is the entire problem.**

- **Getting *clean* stable exposure is NOT free — `deposit()` also hands you N.**
  `deposit()` mints spUSD at NAV with infinite depth, but it *also* gives you the
  N leg, and at a fresh series' strike (0.5× → `STRIKE = x/2`) `N ≈ 0.5 ETH` per
  unit — so a pure-stable *minter* traps **~half their deposited value** in an
  illiquid N with no market at launch. Clean entry without that N tax requires
  *buying spUSD from the pool* (not minting), which needs a seeded pool whose
  ask-side provider ate the N. So entry carries the same orphan-N cost as the
  exit — it's just borne by the LP/seeder instead of the user.
- **The clean ~$1 *exit* is the binding constraint.** `redeem()` is instant and
  oracle-free but pays **pro-rata P tokens + `eth_buffer`**, and at launch
  `eth_buffer ≈ 0` (it's *only* fed by `_harvest()` of **settled** series —
  `TrackerDAO.vy:457`). **There is no code path to seed `eth_buffer`** today
  (`__default__` explicitly drops donations, `:575`). So the DAO's native ETH-out
  paths are dead at genesis: `redeem` returns ~pure P, and `sell_p` reverts
  ("no auction", `buy_started==0` until the buffer is non-zero). A redeemer is
  left holding illiquid P with no market.
- **Two "internalize to zero" ideas are mirages in this code:** (a) deposit keeps
  the buyer's P *inside the DAO* — you never get P out to `merge`; (b) `redeem`
  pays P of the *current* series while a holder's retained N is the *deposit-time
  vintage*, so after any roll `merge` reverts (different token contracts). Netting
  stable-sellers against leverage-buyers doesn't close.
- **spUSD/WETH is NOT a stable/stable pair.** spUSD ≈ $1 but is *priced in WETH*,
  so its pool price ≈ 1/ETH and moves with ETH. A "tight band around $1" drifts
  out of range as ETH moves → concentrated ranges need a **re-ranging keeper**;
  they're not set-and-forget like USDC/DAI.

**The common denominator is N.** Both clean entry (shed the N you're minted) and
clean exit (the mirror) are gated on a market for **N — the leverage leg, the
niche-demand side.** The bootstrap problem really reduces to: *bootstrap an N
market, or decide who absorbs N.* Until leverage demand shows up to buy it, a
seeder / the protocol must hold it, sized to the stable-vs-leverage *imbalance*.

So: **there is no zero-liquidity two-sided launch.** Some ETH must be liquid for
the sell side, and someone must absorb the orphan N on the buy side. The whole
game is minimizing both — and the floor is "enough to cover net *imbalance*,
sized to flow, not to total float."

## The menu (what survived, cheapest first)

| Mechanism | Seed | What it costs | Honest tradeoff |
|---|---|---|---|
| **Buy-side only** (`deposit` at NAV, or single-sided spUSD ask-range) | **~0** | nothing (spUSD minted free) | buy-only; no exit |
| **Seed `eth_buffer` directly** (needs a tiny core add) | **very-low, ETH-only** | a small ETH donation to the DAO's buffer | non-recoverable (no admin to pull it); `sell_p` exit is oracle-priced (existing ramped auction, not hot-path); activates the DAO's *own* poolless MM |
| **Single-sided WETH bid range just below NAV** | **low, WETH-only** | WETH sized to expected net outflow | needs a re-ranging keeper (price drifts with ETH); mild adverse-fill bleed; recoverable LP |
| **Ultra-tight ±1% two-sided position** | **very-low–low** | small ETH, both sides via LPZapper-style | concentration helps but band drifts with ETH → keeper; carries IL + long-N |
| **Tiny WETH-only P-sink sized to leverage flow** | **low** | WETH ~ O(leverage demand), which is niche | only serves leverage; stable exit still unsolved |
| **Deposit-haircut → `eth_buffer`** (core add) | **~0 upfront** | a few bps of each deposit | self-funds the exit from flow; under-delivers at t=0 (buffer starts empty) |
| **MM / whale partnership via LPZapper** | medium (theirs) | a deal, not your capital | mercenary depth; doesn't reduce *total* liquidity |
| **Spread-funded POL on `sell_p`** | near-0 | skim the auction | compounding only; zero standing depth alone |

Rejected as non-viable in this code: buffer "bootstrap" with no seed path, the
buffer-PMM (double-drains the buffer per exit), the CoW-style matcher (flows are
size/vintage-mismatched), virtual-reserve JIT (no primitive pays clean ETH from
the buffer), points/airdrops (back nothing on-chain).

## Recommended minimal stack (fewest tradeoffs)

Two moves get you a genuinely usable, near-minimal-liquidity launch:

1. **Add one tiny core primitive: `seed_buffer()` payable → credits `eth_buffer`**
   (or a few-bps deposit haircut routed there). ~5 lines, no admin, no oracle on a
   new hot path. This is the **highest-leverage change in the whole survey**: it
   turns on the DAO's *native, poolless, ETH-only* market making —
   - `redeem` starts returning real ETH alongside P,
   - `sell_p` goes live so P→ETH (the exit) and leverage-via-P-sink both work,
   - it's **self-reinforcing**: `sell_p` rotates the seed into P (peg backing),
     and harvests refill it.
   Cost: ETH-only, sized to expected net outflow (not float). Caveat: a donated
   seed is sticky (no admin to withdraw) and `sell_p` is oracle-priced (the
   existing ramped auction — slow, not per-trade, so not the stale-oracle hot-path
   risk a curve would add).

2. **Seed a thin WETH-only bid just under NAV** (single-sided v3) to cover the gap
   until the buffer fills, and to give instant clean-ETH exit at market. WETH-only
   means zero spUSD capital; sized to flow. Recoverable. Needs a small re-ranging
   keeper because the price tracks ETH.

Leave the **buy side free** (`deposit`/spUSD ask-range), and **defer the leverage
pool** — route leverage's P into `sell_p` once the buffer is live (poolless), or
add a tiny WETH-only P-sink later since leverage demand is niche.

Net seed: **a small, mostly-recoverable WETH bid + an optional ETH buffer
donation**, both sized to expected *outflow*, not to the float. That's roughly an
order of magnitude under a full-range two-sided pool seed, with no new custodial
contracts and no oracle on a per-trade path.

## Bottom line

- You can't launch two-sided on *zero* liquidity — the clean exit fundamentally
  needs ETH on the other side (a WETH bid) or a funded buffer.
- The cheapest, lowest-tradeoff path isn't an exotic AMM — it's **funding the
  DAO's own buffer** (one tiny core add) so its native redeem/`sell_p` MM turns on,
  plus a **thin single-sided WETH bid** for instant market exit. Both ETH-only,
  both sized to flow.
- If you want the seed to be *recoverable*, lean on the WETH bid (an LP position).
  If you want it *self-reinforcing and simplest*, lean on the buffer seed (sticky
  but it compounds into backing). Best is a little of both.
