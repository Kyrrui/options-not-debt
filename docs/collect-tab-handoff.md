# Saver detail: add a "Collect" tab + fix the timing/naming — handoff

> For the dapp builder. The protocol is pull-based: legs (the N from a
> deposit, the P from a full-value redeem) become ETH on a date and must be
> *manually claimed* — nothing auto-converts. Today's Deposit / Cash out tabs
> hide that, and "Cash out" wrongly implies instant cash for the redeem path.
> Restructure the saver detail (SaverCard) into three tabs split by WHEN you
> get your money.

## Tabs (split by timing)

1. **Deposit** — ETH → spUSD (unchanged). Add one line: *"You'll also get a
   leverage token — it turns into ETH on a date; collect it in the Collect
   tab."* (so the N you're handed isn't a mystery token).
2. **Cash out** — the **instant** path only: sell spUSD → ETH now at market
   price (the existing "Sell now" door). Now the name is honest. If the pool
   is too thin for a fair price, point to the full-value option in Collect.
3. **Collect** (NEW) — everything that becomes ETH on a date:
   - the **full-value cash-out action** (the existing `redeem(shares)`),
     relabeled *"Cash out at full value — paid on [date]"*; and
   - the **claim list**: every leg you hold for this tracker, with its date
     and a one-press collect.

Recommended: move `redeem` out of Cash out into Collect (groups all
date-based money in one place; makes "Cash out" cleanly instant). Acceptable
lower-churn alternative: leave `redeem` in Cash out as a clearly-timed "full
value · paid on [date]" door and make Collect the claim list only. Either
way the must-haves are the Collect tab, the dates, one-press collect, and the
cross-links.

## The Collect tab (the meat)

**Enumerate the user's legs.** Reuse the existing `MyLegs.tsx` enumeration
(it already finds the user's P/N across the tracker's series — active,
pending, and historical via RollStarted/factory). For each series read
`P()`/`N()`, the user's `balanceOf` of each, `MATURITY()`, `settled()`,
`payout_p()`.

**Each held leg → one plain-language card** (never show raw `P-…`/`N-…`):
- Label by source + date: *"Leverage token — from your deposit on Jun 13"*
  (N) / *"Full-value redemption — from your cash-out on Jun 28"* (P).
- ETH value (reuse `@gimbal/protocol` helpers — don't inline): settled →
  exact (`amount × payout_p/1e18` for P, `amount × (1e18−payout_p)/1e18` for
  N); not-settled → estimate at the live price, shown with "≈" and "final
  value set on [date]".
- **Three states:**
  - **Not ready** (before settlement): *"Becomes ETH on Jul 11 — come back
    then."* Greyed; offer **add-to-calendar** (.ics) so they actually return.
  - **Ready** (matured): **"Ready — Collect ≈ 0.05 ETH"** → one button. Under
    the hood it does settle-if-needed **then** redeem, as a single
    `useTxFlow` multi-step (`[settleStep?, redeemStep]`); the user never sees
    two steps. `redeem_p` for P, `redeem_n` for N.
  - **Convert now** (only if they hold the matching opposite leg, equal
    amounts): offer `merge(amount)` → instant ETH, works pre-settlement.
- **Empty state:** *"Nothing to collect yet. When you deposit or cash out for
  full value, your claim shows up here with the date it becomes ETH."*

## Make people come back (the pull-model risk)

- **Badge on the Collect tab** with the ready count ("1 ready").
- **A line on the tracker card and the home list:** *"You have ≈0.05 ETH
  ready to collect."*
- Cross-links: Deposit → "collect your leverage token in Collect on [date]";
  the full-value cash-out → "collect this in Collect on [date]."

## Copy / jargon rules

Plain words only: "leverage token," "full-value redemption," "becomes ETH
on," "collect." Never P/N/strike/series/settle/redeem on the visible path —
the `?`/How-it-works link carries the mechanism. Exact figures on hover (§4);
never round a tx amount.

## Honest framing (put in How-it-works / Under the hood)

This "come back and collect" is inherent to the pull-based design — the
protocol *guarantees* you can always get your ETH, but it won't push it to
you. The two ways to remove the friction are deep pool liquidity (so instant
Cash out is reliably full value) or a future opt-in auto-collect periphery
(the keeper can't touch user wallets without it). Collect + reminders is the
right MVP answer.
