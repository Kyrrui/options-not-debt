# Gimbal Simple Vault — Sepolia v1 (spec)

> The **deliberately minimal** Sepolia cut of the crowd-owned house. ONE immutable, ownerless
> Vyper 0.4.3 contract (`GimbalSimpleVault.vy`) that lets crowd LPs fund an ETH pool which
> **writes and sells the N (leverage) leg** of the existing spUSD `TrackerDAO`'s **current ~2×
> series** at an on-chain formulaic price, keeping the P leg (a covered-call house). No owner,
> no admin, no pause, no upgrade, no signer. Funded only by LP deposits; the only outflow is an
> LP redeeming its own shares (oracle-free, in-kind) or a settled-series harvest.
>
> **This is the master [`autonomous-vault-spec.md`](autonomous-vault-spec.md) collapsed to its
> smallest honest core.** Everything that made the master spec's GO/NO-GO say "don't freeze yet"
> is either sidestepped by scope (single ~2× series, no menu, junior-only) or **explicitly deferred
> to the [MAINNET CHECKLIST](#mainnet-checklist--must-update-before-mainnet) below.** It is safe to
> freeze on Sepolia *because the funds are testnet*: a bug's only cost is "redeploy v2," and nobody
> loses real value. **None of these simplifications are acceptable on mainnet** — see the checklist.

```
WHAT IT IS          immutable · ownerless · on-chain-priced · crowd-funded ETH covered-call vault
WHAT IT REUSES      the LIVE TrackerDAO (0x80A2…4FAE) current series + roll/settle machinery; OracleHub
WHAT IT WRITES      N of the tracker's current ~2× vintage only (no strike menu, no leverage tiers)
FUNDING             LP deposit() is the only inflow; redeem()/harvest is the only outflow
PRICING             price = oracle intrinsic × (1 + BASE_EDGE); NO signer, NO ecrecover, NO quote
KEEPER              permissionless poke(): best-effort settle + harvest matured held-P → buffer
DELETED vs the desk owner · withdraw_eth · set_* · quoter/signer · pause — none exist
```

---

## 1. Why this is the simplest correct shape

The master spec's NO-GO blockers were all **mainnet, real-funds** concerns, and the riskiest build
surface (the P2 dated-series *menu*: strike-snapping, a tier grid, a registry, cohort rolls, keeper
races) was net-new immutable code. This cut **deletes that entire surface** by reusing what is
already deployed and tested:

- **No menu, no factory, no roll logic in the vault.** It writes the `TrackerDAO`'s *current*
  series (`pending_series()` else `active_series()`) — the same roll-safe target the deployed desks
  already key off. The tracker's own permissionless `sync()` creates, rolls, and settles series;
  the vault just rides it. → sidesteps F-V1-SCOPE, F-KEEPER-RACE, F-DUST (the only writable series
  is the tracker's current one — nobody can make the vault open an arbitrary series).
- **~2× only.** The soft-peg series sits at leverage ≈ `1/(1−strike_ratio)` ≈ 2×, inside the master
  spec's own "strictly-safe ≲2–3×" band where the hub's loose 7200 s heartbeat is *tolerable*
  (finding #9 fallback option 3). → sidesteps F-SETTLE-STALE / F-CEILING by leverage choice, not a
  core rewrite.
- **No epochs.** Deposits price at live NAV; redemptions are pro-rata in-kind and oracle-free. The
  master spec's epoch machine existed to kill the JIT-NAV deposit arb and to gate redemptions on
  settlement — both are **mainnet** refinements (see checklist). Redeem is never trapped.
- **Junior-only, ETH/N-only, write-only.** No senior staked-spUSD tranche (F-SENIOR-COLD), no
  USDC/short PWV, no buyback/sell-N warehouse (F-SELLN). N buyers exit by holding to settlement and
  calling the series' permissionless oracle-free `redeem_n`, or `merge` if they hold both legs.

**The accounting is not new.** The vault holds only **ETH + P** — exactly like `TrackerDAO`. Its NAV
is `eth_buffer + Σ p_held·val_p`, its redeem is the byte-for-byte `TrackerDAO.redeem` in-kind
pattern, and its risk measure is `Σ p_held` (face). It inherits the shape of a contract that is
already unit/fuzz/invariant-tested and Halmos-proven for conservation.

## 2. Mechanics

**State.** Soulbound shares (`totalSupply`/`balanceOf`, mint/burn only — no transfer/approve
surface in v1); `eth_buffer` (tracked free ETH, donations uncounted); `p_held[series]`;
`open_series: DynArray[address, MAX_OPEN]` + `is_open[series]`; `total_p_held`; `total_deposited`;
outflow window + per-block write meters.

**Pricing / NAV** (`x = HUB.latest_price(USD)`, fresh per call):
```
val_p_eth(s, x) = payout_p(s)                if settled
                = min(UNIT, STRIKE·UNIT//x)   otherwise        # ETH wei per 1e18 P
nav(x)          = eth_buffer + Σ_open p_held[s]·val_p_eth(s,x)//UNIT
share_price     = nav·UNIT // totalSupply     (UNIT if supply==0)
```

**`deposit() payable → shares`** — `nav_before` struck before crediting; first deposit mints
`DEAD_SHARES` to `0xdead` (donation-immune) and `shares = msg.value − DEAD_SHARES`; else
`shares = msg.value · supply // nav_before`. `total_deposited` capped by `TOTAL_DEPOSIT_CAP`.

**`buy_n(series, amount, max_cost) payable → cost`** — the write path (strict CEI, mirrors
`SignedQuoteFiller.fill_buy_n` but priced on-chain):
```
assert amount in (0, MAX_FILL]; series == tracker target; not settled; +PRE_MATURITY_BUFFER < maturity; asset==USD
x = latest_price; _assert_fresh()                                   # tight ETH/USD staleness + F5 round-complete
assert x > STRIKE·STRIKE_PROXIMITY//UNIT                            # near-strike no-trade band (≥ ROLL_TRIGGER)
price = (UNIT − STRIKE·UNIT//x)·(UNIT + BASE_EDGE)//UNIT
cost  = amount·price//UNIT; assert cost <= max_cost and msg.value == cost
assert total_p_held + amount <= MAX_WRITTEN                         # capital-at-risk cap
_charge_outflow(amount); _charge_block(amount)                      # per-window + per-block written-face caps
assert eth_buffer + cost >= amount                                  # can fund the split net of premium
# EFFECTS: register open series, p_held += amount, total_p_held += amount, eth_buffer += cost − amount
# INTERACTIONS: ISeries(series).split{value: amount}() ; transfer the N to the buyer; keep P
```
Each write raises NAV by exactly the captured spread (`amount·intrinsic·BASE_EDGE`); the variable
P&L then floats with the held-P mark as `x` moves. Max loss per unit (`x→∞`, P→0) is the locked
`amount − cost`, finite and pre-funded — never liquidated.

**`redeem(shares)`** — burn → strict pro-rata of `eth_buffer` (ETH) **and** each `p_held[s]`
(P **in-kind**). Reads only `totalSupply`/balances/buffer — **no oracle, no mark, never trapped.**
The exiting LP settles/merges the received P at their own pace (the one-time oracle dependency is
theirs, not the pool's). This is simultaneously the normal exit *and* the master spec's
`force_redeem` — there is only one redeem.

**`poke()`** — permissionless keeper. For each held series: best-effort `settle()` via
`revert_on_failure=False` raw_call (skips if the feed is stale), then if settled, `redeem_p` the
held P → `eth_buffer` and drop it from `open_series`. Bounded by `MAX_OPEN`. Zero privilege over
value. If nobody ever calls it, anyone can settle the series directly and `redeem` still pays
oracle-free from the buffer + in-kind P.

**Immutable caps** (ctor-asserted into safe ranges, never settable): `BASE_EDGE (≤20%)`,
`DESK_MAX_STALENESS∈[30,3600]`, `PRE_MATURITY_BUFFER>0`, `STRIKE_PROXIMITY≥ROLL_TRIGGER`,
`MAX_FILL`, `MAX_WRITTEN`, `OUTFLOW_WINDOW`+`OUTFLOW_CAP`, `MAX_WRITE_PER_BLOCK`,
`TOTAL_DEPOSIT_CAP`.

## 3. Honest risks (Sepolia)

- **No-signer adverse selection / MEV.** A deterministic on-chain price off a fresh oracle is
  sandwich/oracle-tip exploitable in a way a smart signer dodged; the floor + tight staleness +
  per-block/per-window write caps bound per-block extraction, the `BASE_EDGE` is wider than a signer
  would quote. Tolerable at ~2× with tiny caps; this is the accepted price of ownerlessness.
- **JIT-NAV deposit arb.** Live-NAV deposit pricing lets a depositor time the oracle mark on held P.
  Bounded by `TOTAL_DEPOSIT_CAP` + tiny caps on testnet; **fixed by epochs on mainnet** (checklist).
- **One-sided short-vol.** v1 only sells calls, so a sustained melt-up walks junior NAV down over
  time — capped per fill/block/total, capped at deposit, never liquidated, but real.
- **Dead-oracle trap (inherited, CRITICAL on mainnet).** Locked collateral is recoverable oracle-free
  only while the feed lives at settlement; a permanently dead Sepolia feed traps the locked slice —
  on testnet that means "redeploy." `redeem`'s in-kind P moves this risk to the exiting LP, not the
  frozen pool. **Mainnet fix in the checklist.**

---

## MAINNET CHECKLIST — MUST UPDATE BEFORE MAINNET

**Do not deploy this contract, as-is, to mainnet.** Every item below is a deliberate Sepolia
simplification that is *safe only because testnet funds are worthless*. Mainnet requires all of:

1. **A timelocked guardian.** Add the master-spec §5.5 brake — a guardian whose ONLY powers are
   `pause_new_writes` (redeem, incl. in-kind, stays permanently un-pausable) and a long-timelock
   cap-ratchet that can only *narrow* caps; never a `withdraw`/value-extraction path; behind a
   timelock ≥ one epoch + multisig (or token vote); ABI + hardcoded bounds published. Renounceable
   to full immutability later. (This is the "training wheels, then renounce" path — NOT a full
   upgrade proxy, which would re-introduce maximal centralization.)
2. **Hardened settlement primitive.** Resolve F-SETTLE-STALE / F-DEAD-ORACLE in an `OptionSeries`
   blueprint: `max_settle_staleness` + `assert answered_in >= round_id` asserted *inside* `settle()`,
   and a permissionless `settle_fallback()` (after a `GRACE` past maturity with no live feed, settle
   `payout_p = UNIT` so collateral becomes oracle-free redeemable). Required before writing any
   leverage tier above ~2–3× against anything looser than a tight ETH/USD heartbeat.
3. **Epoch / boundary pricing.** Replace live-NAV deposit/redeem with deposit/redeem queues priced
   at a per-epoch `boundary_nav` to kill the JIT-NAV arb (master spec §2.3–2.4).
4. **Decomposed Halmos vault-accounting suite + an independent paid audit** of the share/NAV/queue
   core — for an un-patchable pooled fund, proof + audit are the only safety net (master spec §6 #13).
5. **A named, accountable legal entity** for the pooled funds *before any non-testnet deposit*, plus
   any KYC/geo/transfer gating baked into the deployed bytecode from the start (it can never be
   retrofitted onto an immutable contract). Master spec §5.5 / F-OPTICS-GATE.
6. **The leverage menu (P2), shorts (P1/PWV), and the senior staked-spUSD tranche (P3)** are all
   additive *fresh deploys* gated on P1 live + measured two-sided flow — not part of this contract.
7. **The on-chain pricer's leverage-amplified spread + inventory skew** (master spec §3
   `leverage_amp`, `inv_skew`) must be added before any tier above ~2× is writable — a flat
   `BASE_EDGE` is only safe at the single low-leverage series this v1 writes.
8. **Replace soulbound shares** with a real transferable ERC-20 (or a deliberate decision to keep
   them soulbound), with the associated approve/transfer surface audited.

> v1 is fully immutable BY CHOICE for the Sepolia research phase — the cleanest proof of "no
> centralization risk," and the value at stake is testnet. The items above are the difference
> between that and an immutable contract custodying real funds. Carry this checklist in the README,
> the Earn-tab disclosure, and the deploy-script header.

*Sepolia testnet, research code, unaudited. Not a yield product; the house can lose principal
(capped at deposit, never liquidated). Your counterparty is an immutable ownerless on-chain vault.*
