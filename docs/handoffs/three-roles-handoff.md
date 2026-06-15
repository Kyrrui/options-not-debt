# Restructure the app around the 3 real roles — handoff

> For the dapp builder. This replaces the flat nav (Trackers / Series /
> Auctions / Trade / Create) and the Deposit/Cash out/Collect saver model
> with **three top-level destinations, one per economic role**:
>
> | Tab | Who it's for | One-line job |
> |---|---|---|
> | **Hold** | wants a stable asset | swap ETH ↔ spToken on the pool |
> | **Leverage** | wants amplified ETH | one-tx ETH → pure N leg |
> | **Provide** (Earn) | wants to earn from running the market | mint spToken + LP it |
>
> The insight: the protocol already *is* a three-sided market, and these are
> exactly its three sides. The **spToken/WETH Uniswap v3 pool is the hub all
> three route through.** Make the UI mirror that and most of the confusion we
> kept patching (orphan N, settlement claims, "which tab do I use") disappears,
> because each surface now has one clear job.

---

## 0. Why this is cleaner (read first)

The pain in the current saver flow comes from one fact: **minting spToken via
`TrackerDAO.deposit()` always also mints you the leveraged N leg**, plus the N
and any full-value redeem only become ETH on a settlement *date* (pull-based —
nothing auto-converts). That machinery is unavoidable for the *manufacturer*,
but a casual stable buyer should never see it.

The fix is to route the two **consumer** roles through the pool and keep the
**producer** role (which touches the options machinery) in its own tab:

- **Hold** = buy/sell spToken on the pool. No N, no claims, no dates. It's a
  swap. This is the big simplification.
- **Leverage** = `LeverageRouter.open_leverage()`. Already built & deployed.
- **Provide** = mint spToken (`deposit()`) and put it in the pool. This is the
  only role that holds N / sees the gearbox — and that's correct, because the
  N it's handed is *the inventory the Leverage tab consumes.* N stops being an
  orphan: the producer makes it, the leverage buyer buys it.

So the three sides feed each other, and everything settles onto one pool. That
is also the system's one fragility — see §5.

---

## 1. Information architecture

**Top nav becomes three items: Hold · Leverage · Provide.** A tracker is
chosen inside each (or via the existing tracker list as the landing). Everything
else demotes:

| Today | Goes to |
|---|---|
| Trackers (list/landing) | keep as the picker that feeds all three tabs |
| Trade | becomes **Leverage** |
| Deposit (mint) | moves into **Provide** (it's the manufacturer's tool) + an "advanced: mint at exact NAV" option under Hold |
| Cash out (sell on pool) | becomes the **sell** side of **Hold** |
| Collect (claim legs) | becomes **Claims**, under *Advanced / Under the hood* — only producers & redeemers generate legs now |
| Series / Auctions / Create | **Advanced / Under the hood** (unchanged behavior, just demoted) |

Newcomers don't know which persona they are, so the labels must be plain and
the landing should route them: *"Keep it stable → Hold. Bet on ETH →
Leverage. Earn from providing the market → Provide."*

---

## 2. Tab 1 — **Hold** (stable buyer)

**Primary action: swap ETH ↔ spToken on the spToken/WETH Uniswap v3 pool.**
Not `deposit()`. A pool swap gives the user *only* spToken — no N leg, no
settlement date, no Collect tab. Buy and sell are the same surface, flipped.

- **Buy:** `ETH → WETH → spToken` via the v3 pool (SwapRouter02
  `exactInputSingle`, same router the LeverageRouter uses; fee tier from
  `@gimbal/protocol`). Quote with the Uniswap quoter; show spToken out and the
  effective price vs the on-chain peg target (`share_price()`, target `1e18`).
- **Sell (replaces "Cash out"):** `spToken → WETH → ETH`, same pool. This is
  now honestly *instant* — no date.
- **Depth/price-impact warning:** REUSE the helpers from the
  liquidity-impact-handoff work. A thin pool means the user buys/sells *off
  peg*; show the price impact and, above a threshold, warn and point to the
  backstop.
- **Backstop (under "advanced" on the sell side):** `TrackerDAO.redeem(shares)`
  is the guaranteed, oracle-free, pro-rata exit (returns P tokens + buffered
  ETH that become ETH on a date → routes to **Claims**). Frame it exactly as in
  cashout-handoff: *"Sell now at market"* (instant, pool price) vs *"Redeem at
  full value — paid on [date]"* (guaranteed, dated). Note redeem requires
  holding *shares*, which a pure pool-buyer has; it pays P, not cash, so it
  links into Claims.

**Copy rules:** "stable token," "buy/sell," "≈ \$1." Show the live peg
(`share_price`) and that it's a *soft* peg backed only by ETH. **Do NOT imply
yield** — Hold pays nothing; it just stays level. (This is the "Earn" pushback
from before: holders don't earn, providers do.)

---

## 3. Tab 2 — **Leverage** (leverage buyer)

**Primary action: `LeverageRouter.open_leverage(min_eth_out)`** — one tx, ETH
in → pure N leg + recovered ETH out, no leftover P. Already built, tested on a
fork, and deployed; this tab is mostly the existing LongEthCard re-homed.

- Keep the **already-fixed** payoff diagram: USD-numéraire return,
  `breakevenIndexUsd`, and the leverage multiple shown (payoff-return-handoff).
- `min_eth_out` is the slippage floor on the P-sink swap — **never 0**. Derive
  it from a quote with a user-set tolerance; surface the price impact, because
  this also routes through the same pool (§5).
- Honest copy: "no funding, no liquidation, capped downside (you can't lose
  more than the premium)" — all true and all differentiators. Keep
  testnet/unaudited tag.

---

## 4. Tab 3 — **Provide** (LP / the manufacturer) — the honest, harder one

This is the producer role and the only one that touches the gearbox. The full
flow is: **ETH → `deposit()` mints spToken shares (+ hands you N) → pair shares
with WETH → add to the spToken/WETH v3 pool.** The LP ends up holding: a v3 LP
position (≈half ETH exposure + impermanent loss), **plus the N leg**, and earns
swap fees.

### The one-tx path now exists: `LPZapper.add_liquidity()`

A periphery **LPZapper** is built, fork-tested against the live pool/NPM, and
adversarially reviewed. It is deployed and discovered through the
**PeripheryFactory** — don't hardcode it; read it from the registry:
`PeripheryFactory.get_zapper(tracker, 3000)` (and `get_router` for Leverage,
`get_pool` for Hold). See [peg-launch-handoff.md](peg-launch-handoff.md) for the
full discovery + launch flow. The canonical spUSD zapper is currently
`0x8F4C9824Ac836AB636BBA715Bc5dD99C65AA906c`. So the Provide tab does the whole
thing in **one tx** instead of linking out:

```
LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline) payable
  -> (token_id, liquidity, sp_used, weth_used)
```

It deposits `eth_to_deposit` into spUSD (mints shares + N), wraps the rest to
WETH, mints a **full-range** spUSD/WETH v3 position **straight to the caller's
wallet** (a real Uniswap NFT they manage on Uniswap's own UI), forwards the N
leg, and refunds every leftover. Stateless, no admin, holds nothing after.

**The frontend's job (this is where the work is):**
- **Compute `eth_to_deposit`** from the pool's current price so the two sides
  roughly balance — the contract does NO price math on purpose. A bad split
  isn't lost, just refunded, but a good split = less refund / more LP'd.
- **Set non-zero `amount_sp_min` / `amount_weth_min`** from a quote + tolerance.
  Never 0 in production (0 is for tests only).
- **Show the result honestly:** `sp_used` / `weth_used` vs what was refunded.
  On the current off-NAV pool only ~49% of the WETH side gets used and the rest
  comes back — surface that, don't hide it.

Fallback (still valid if you don't want the zapper yet): `deposit()` then
deep-link to Uniswap's Add Liquidity UI. But the zapper is the better UX and
it's live, so prefer it.

### What the tab must do regardless of path

- **Honest risk framing — do NOT sell this as easy yield.** Spell out the three
  exposures: (1) impermanent loss on a *volatile* spToken/WETH pair, (2) the N
  leverage leg you're handed, (3) fees as the upside. "Provide / Earn fees" is
  fine as a label *because LPs genuinely earn fees* — but the body copy must
  name the IL and the N. This is the one place "Earn" is honest; keep it honest.
- **Handle the N explicitly.** The `deposit()` hands the provider an N leg.
  Make it a first-class choice, not a mystery token: *"keep it (a leverage
  position) or sell it to leverage buyers."* This is the supply that feeds Tab
  2 — say so. Selling routes to the same pool / Claims machinery.
- **Show the position + claims** the provider now holds (LP NFT value + any P/N
  legs → reuse the Claims/MyLegs enumeration from collect-tab-handoff).

---

## 5. The thread that ties it together (put in How-it-works / Under the hood)

- **One pool, three roles.** Hold buys/sells spToken on it; Leverage uses it as
  the P-sink; Provide fills it. So *all three* degrade if the pool is thin or
  off-NAV — that's the elegance and the single point of fragility. Be honest:
  buy/sell quality on Hold and Leverage depends on Provide-side depth + an
  arb/keeper holding the pool near NAV.
- **Supply before demand.** Consumers (Hold/Leverage) only get good prices once
  producers (Provide) seed the pool. The UI making Provide a first-class tab is
  the point — it recruits the supply side. Until depth exists, show the
  price-impact warnings rather than hiding them.
- **N is not an orphan.** Producer mints it; leverage buyer consumes it. Make
  that loop legible across the Provide and Leverage tabs.
- The peg's "≈\$1" on Hold is only as good as the pool holds it; `redeem()` is
  the deep NAV-ish backstop under it. Normal times: pool. Stress: redeem.

---

## 6. Copy / honesty rules (carry over)

- Plain words on the visible path: "stable token," "leverage," "provide
  liquidity," "buy/sell." Never P/N/strike/series/settle on the surface — the
  `?` / How-it-works link carries the mechanism.
- **No implied yield on Hold.** Yield language only on Provide, and only next
  to the IL + N risk.
- Exact figures on hover; never round a tx amount; keep the *Sepolia testnet ·
  research code, unaudited* tag everywhere.

---

## 7. What NOT to do / open items

1. **Provide is a one-tx flow now** via `LPZapper.add_liquidity()` (deployed,
   §4). Compute the split + slippage mins off-chain; never pass 0 mins. The
   mint-then-link-to-Uniswap path is the fallback, not the default.
2. Don't delete `redeem`/Claims — they're the backstop and the only guaranteed
   exit; just demote them.
3. Don't remove the depth/price-impact warnings to make the demo look clean —
   thin pool is the real state; honesty is the brand.
4. Series / Auctions / Create stay reachable under Advanced (keepers/MMs need
   them) — just out of the newcomer's path.

---

## 8. On-chain call reference

| UI action | Call | Notes |
|---|---|---|
| Hold · buy | SwapRouter02 `exactInputSingle` ETH→spToken | quote first; show price vs `share_price()` |
| Hold · sell (instant) | SwapRouter02 `exactInputSingle` spToken→ETH | honest "instant, market price" |
| Hold · redeem (backstop) | `TrackerDAO.redeem(shares)` | oracle-free, pays P + ETH → Claims (dated) |
| Leverage · open | `LeverageRouter.open_leverage(min_eth_out)` | router from `PeripheryFactory.get_router(tracker,3000)`; min_eth_out ≠ 0; pure N + ETH back |
| Provide · LP (one tx) | `LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline)` payable | zapper from `PeripheryFactory.get_zapper(tracker,3000)` (spUSD: `0x8F4C9824Ac836AB636BBA715Bc5dD99C65AA906c`); mints full-range NFT to caller, forwards N, refunds leftovers; compute split off-chain, mins ≠ 0 |
| discover periphery | `PeripheryFactory.get_router/get_zapper/get_pool/is_deployed(tracker, 3000)` | replaces hardcoded addresses; see peg-launch-handoff.md |
| Provide · LP (fallback) | `TrackerDAO.deposit()` then link to Uniswap Add Liquidity | only if not using the zapper |
| Claims · collect | settle-if-needed → `redeem_p`/`redeem_n` (one `useTxFlow`) | from collect-tab-handoff |
| Peg / NAV reads | `share_price()`, `nav()` | target `1e18` |

Addresses, fee tier, and the spToken/WETH pool all come from `@gimbal/protocol`
(don't hardcode). Reuse existing helpers: `breakevenIndexUsd`, the
liquidity-impact price-impact helpers, and the MyLegs/Claims enumeration.
