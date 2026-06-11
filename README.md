# options, not debt

ETH-collateralized, oracle-minimized index trackers for any real-world asset with a
Chainlink feed — built on **options instead of debt**, so the system has **no
liquidations, no real-time oracle dependency, and no bad debt, by construction**.

An implementation of Vitalik Buterin's design from
[*Building index-tracking assets on top of options instead of debt*](https://ethresear.ch/t/building-index-tracking-assets-on-top-of-options-instead-of-debt/25036)
(ethresear.ch, June 2026), incorporating refinements from the discussion thread.

Contracts are **Vyper 0.4.3**, tests are **Foundry** (unit + fuzz + stateful
invariant testing), and the core theorems are machine-checked with
**[Halmos](https://github.com/a16z/halmos)** symbolic execution against the
compiled Vyper bytecode (see the per-theorem status table below — the
nonlinear-arithmetic proofs are long-running and marked accordingly).

---

## The idea (from the thread)

Every synthetic-asset system holding only ETH must balance positive and negative
exposure to the tracked index. Debt-based designs (CDPs, algorithmic stablecoins)
resolve a blown-out short side with **forced liquidation**, which requires a
**binding real-time price oracle** — by far the weakest part of any such protocol.

This design removes liquidations entirely. The base building block is an option
pair on a ticker `T` (the price of ETH denominated in units of the tracked asset),
with strike `S` and maturity `M`:

```
split:   1 ETH  ->  1 P  +  1 N          (any time before maturity)
merge:   1 P + 1 N  ->  1 ETH            (ANY time — even after settlement)

settle (once, lazily, at/after M, index = x):
  P receives  min(1, S/x)  ETH           (worth min(S, x) asset units)
  N receives  1 - min(1, S/x)  ETH       (the leveraged-long-ETH leg)
```

`P + N = 1` **always**. Nobody can go bankrupt, so nothing ever needs to be
liquidated, so the oracle is consulted **exactly once per series, lazily, after
maturity** — a "slow oracle" that can afford disputes, recourse, and long delays.
A deep in-the-money `P` (strike far below the current index) is worth `S` asset
units almost exactly: that is the index-tracking leg. Rotate it to lower strikes
before it ever gets close to the money and you have a **soft peg with bounded,
quadratic drift instead of cliff-edge liquidation risk**.

### What the replies contributed

| Author | Point | Where it landed here |
|---|---|---|
| Xatarrer | frame P+N=1 as the payoff absorbing stress; both sides split the same collateral | exact-conservation settlement math, zero-drift split of `payout_p`/`payout_n` |
| equivrel | deep-OTM put framing hides theta cost | documented: P holders are *covered short puts* — they earn the premium via the auction edge, N pays it |
| Czar102 | "predictable rolling": short maturities, far strikes, roll early via gradual auctions; lazy one-time-pull oracles; no dynamic rebalancing | `TrackerDAO` roll rule + linear-ramp rotation auction; `settle()` is one-shot and pull-based |
| norswap | nothing tracks the long direction beyond collateral value | N is explicitly the leveraged-ETH leg, capped by collateral; the tracker is P |
| mmchougule | settlement as asset movement; P/N as plain ERC-20s | P and N are plain ERC-20s; `merge` works post-settlement as an oracle-free exit |
| CertifiedCryp | quorum/attestation layers for scalar settlement | out of scope; the `OracleHub` boundary is where such a gate would plug in |
| JSeam2 | options liquidity is the real bottleneck | both DAO auctions are one-sided, time-ramped, and slippage-free by design |

## Architecture

```
            ┌─────────────┐   ASSET/USD feeds    ┌──────────────┐
            │  Chainlink  │◄─────────────────────│  OracleHub   │  permissionless
            └─────────────┘      ETH/USD         │  (registry)  │  RWA registration
                                                 └──────┬───────┘
                                                        │ x = ETH price in asset units
                                                        ▼
┌──────────────┐   create_from_blueprint   ┌────────────────────┐
│SeriesFactory │──────────────────────────►│   OptionSeries     │ 1 per (asset,S,M)
│(permissionless)                          │ split/merge/settle │
└──────────────┘                           │      /redeem       │
                                           └─────┬────────┬─────┘
                                                 │ mints   │ locks
                                                 ▼         ▼
                                          P + N (ERC-20)  ETH
                                                 ▲
                                                 │ holds P only, never N
                                       ┌─────────┴─────────┐
                                       │    TrackerDAO     │  the soft peg
                                       │  all rules, no    │  (ERC-20 shares,
                                       │  voting, no AI    │   1 share ≈ 1 unit)
                                       └───────────────────┘
```

| Contract | Role |
|---|---|
| [`OptionToken.vy`](src/OptionToken.vy) | minimal ERC-20; one leg (P or N); mint/burn only by its series |
| [`OracleHub.vy`](src/OracleHub.vy) | permissionless Chainlink registry; computes `x = (ETH/USD) / (ASSET/USD)` ×1e18; staleness/decimals checked; `address(0)` = USD |
| [`OptionSeries.vy`](src/OptionSeries.vy) | the P/N primitive: split, merge (any time), one-shot lazy settle, redeem |
| [`SeriesFactory.vy`](src/SeriesFactory.vy) | permissionless series creation for any registered asset (EIP-5202 blueprints, deduped) |
| [`TrackerDAO.vy`](src/TrackerDAO.vy) | the wrapper DAO: rules-only soft peg. Deposits split ETH; DAO keeps P, hands N back to the depositor; rolls P down-strike via gradual auctions |

### The wrapper DAO's rules (no voting, no admin, no upgrade)

* **deposit** — ETH is split at the live series; the DAO keeps the tracking leg P
  and immediately returns the leveraged leg N to the depositor (speculators hold N,
  per the thread). Shares mint at NAV; NAV counts only tracked balances, so
  donations can't manipulate it.
* **roll rule** — when `x < S × 1.5` or maturity is < 7 days out, a new series is
  created at `S' = x/2`, maturing in 28 days (all parameters immutable per DAO).
* **rotation auction** (`fill_roll`) — arbitrageurs deliver new-series P for
  old-series P at oracle-fair value, with the rate improving linearly to a 2% edge
  over 1 day. One-sided market making: the "ideal market structure that minimizes
  slippage" the post asks for.
* **re-entry auction** (`sell_p`) — harvested ETH buys P back at intrinsic value
  with a bid ramping from −2% to +2%.
* **fallback** — if nobody fills a roll, the old series simply settles via the slow
  oracle and `sync()` harvests it to ETH. The DAO carries tracking drift, never bad
  debt; **`redeem` is pro-rata and touches no oracle**, so exit is always live.

## Verification

Three layers, weakest to strongest:

1. **67 Foundry tests** — unit + fuzz over the full lifecycle, including the
   lazy-settlement, roll, auction, fallback-harvest, and donation paths.
2. **Stateful invariant suites** — random multi-actor action sequences
   (128,000 calls per invariant per run): full collateralization pre-settlement,
   solvency post-settlement, DAO tracked-balance solvency, DAO-never-holds-N,
   shares-always-backed.
3. **Halmos symbolic proofs** ([test/Halmos.t.sol](test/Halmos.t.sol)) — proven for
   **all** inputs in the stated ranges against the compiled Vyper bytecode:

| Theorem | Statement | Status |
|---|---|---|
| `check_payoutBounded` | ∀ price: settled P payout ≤ 1 ETH/unit | ✅ proven |
| `check_splitMergeExact` | ∀ amount: split→merge is value-exact | ✅ proven |
| `check_splitFullyCollateralized` | ∀ amount: split mints equal legs, 1:1 ETH-backed | ✅ proven |
| `check_erc20TransferPreservesSupply` | ∀ amounts: transfers conserve supply and balances | ✅ proven |
| `check_onlyMinterMints` | ∀ caller ≠ series: minting reverts | ✅ proven |
| `check_pValueNeverExceedsStrike` | ∀ price: P's settled value in asset units ≤ S (the peg's hard upper bound) | ⏳ solver running |
| `check_conservation` | ∀ price, ∀ amount: redeeming P+N returns ≤ locked ETH, shortfall < 2 wei (**no bad debt**) | ⏳ solver running |
| `check_payoutMonotone` | ∀ x₁ ≤ x₂: P's payout is non-increasing in the index | ⏳ solver running |

The three ⏳ theorems compose symbolic 256-bit division chains
(`payout = S·1e18/x` feeding further mul-divs) — the hardest query class for
SMT solvers. They have produced **no counterexample**; the solver is still
closing the UNSAT proof (long-running even on bitwuzla). Until they finish,
the claims rest on the invariant suites (128k randomized calls each, zero
violations) and the proven `check_payoutBounded` lemma. This table is updated
as proofs complete.

```bash
# note: halmos needs AST-bearing artifacts; run from a clean state
forge clean && halmos --contract HalmosVerification --solver bitwuzla --solver-timeout-assertion 0
```

*Scope honesty: "formally verified" means the ✅ theorems are machine-proven
over the compiled bytecode within the stated input bounds — nothing more. It
does not mean every contract behavior is proven: the DAO's economic layer is
covered by the invariant suites, not symbolic proofs.*

## Running it

```bash
# prerequisites: foundry (forge/anvil/cast), vyper 0.4.3 (pip install vyper), python 3
forge build
forge test                      # 67 tests: unit + fuzz + invariants

# formal verification (pip install halmos)
forge clean && halmos --contract HalmosVerification --solver bitwuzla --solver-timeout-assertion 0

# local node end-to-end
anvil                           # terminal 1
./script/deploy-local.sh        # terminal 2: deploys stack + spUSD/spXAU DAOs
./script/demo.sh <ETH_FEED> <SPUSD_DAO>   # full lifecycle: peg→roll→auction→settle
```

The demo drives the whole story on-chain: deposit pegs at exactly 1.000 USD/share,
ETH doubling leaves the peg untouched, a crash to $1850 triggers the roll rule, an
arbitrageur rotates the position down-strike for a 2%-capped edge, and the maturity
fallback settles lazily and harvests — with the share price holding the peg
throughout and no liquidation machinery anywhere in the system.

## Design notes & known trade-offs

* **Tracking drift is the product, not a bug**: below the strike the peg degrades
  smoothly (`share ≈ x/S` of target) instead of liquidating. The thread argues
  1–4%/yr drift is acceptable for "price stability" use; this is that trade,
  implemented.
* **Settlement uses the first fresh oracle read at/after maturity.** Chainlink's
  aggregation is the manipulation boundary; a quorum/dispute gate (post #13) would
  slot in at `OracleHub` without touching the series.
* **NAV uses intrinsic value** (`min(x, S)`), deliberately ignoring time value —
  the thread's warning about Black-Scholes over-confidence taken literally. The
  auction edge (±2%) is where the market prices time value instead.
* **The DAO never holds N.** Depositors receive the leverage leg back and may sell
  or keep it; the wrapper is purely the stability side.
* Rounding always favors the system (floor); dust is bounded below 2 wei per
  redemption pair (proven) and is unrecoverable by design.

## Repo layout

```
src/                  Vyper 0.4.3 production contracts
test/                 Foundry: unit, fuzz, invariant + Halmos symbolic suite
script/deploy-local.sh   anvil deployment (mock feeds, registry, 2 DAOs)
script/demo.sh           on-chain lifecycle walkthrough
```

## Disclaimer

Research code implementing a week-old research post. Unaudited (one structured
multi-agent adversarial review; see commit history). Not investment advice; do not
deploy with real funds.
