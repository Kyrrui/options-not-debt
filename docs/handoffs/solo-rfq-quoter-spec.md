# Solo RFQ Quoter — service spec (for the dapp builder)

> Build spec for the operator-run **quoter service** behind the Solo RFQ Desk
> (`SignedQuoteFiller`). The quoter prices the N (leverage) leg off the live oracle +
> the desk's inventory, signs EIP-712 quotes the desk will honour on-chain, and serves
> them to the frontend over HTTP. It is the backend the frontend's quote-request flow
> (`docs/handoffs/solo-rfq-frontend-handoff.md`) POSTs to.
>
> Contract: `src/periphery/SignedQuoteFiller.vy`. Design: `docs/solo-rfq-spec.md`.
> Canonical EIP-712 shapes proven against the contract: `test/SignedQuoteFiller.fork.t.sol`.
> Sepolia testnet, research code, unaudited.

## 1. Trust & safety model (read first — it shapes everything)

- **The quoter ONLY signs quotes. It never moves the desk's funds.** Two keys, kept
  separate: the **owner** key (funds/withdraws/pauses the desk — operator-held, NOT in
  this service) and the **quoter** key (signs quotes — this service's only secret).
- **A leaked quoter key is bounded on-chain**, not catastrophic: every fill is re-checked
  against the directional edge floor, the per-fill/inventory/outflow caps, and the
  freshness gate, all from the desk's own fresh oracle read. The owner can kill a leaked
  key instantly with `set_quoter`/`set_paused`. Still: treat the quoter key as a hot
  secret (host secret store, never in git).
- Therefore the service is stateless infra: it reads chain state, prices, signs, returns.
  No DB needed; no custody; a crash/restart loses only in-flight (short-TTL) quotes.

## 2. EIP-712 (the load-bearing part — must match the contract byte-for-byte)

The desk verifies `ecrecover(digest) == quoter()`. If the domain or type differ from the
contract by one character, every fill reverts `bad sig`. **Verify against the deployed
contract** (§9) before trusting a single quote.

**Domain** (`SignedQuoteFiller` computes this in its constructor):
```
name              = "Gimbal Solo RFQ Desk"
version           = "1"
chainId           = <the chain the desk is deployed on>
verifyingContract = <the SignedQuoteFiller address>
```
The contract recomputes the separator if `chain.id` changes (fork-safe), so always sign
with the live chain id.

**Quote type** (field order and types are exact; this is the EIP-712 typed-data struct):
```
Quote(uint8 side,address taker,address series,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)
```

**Digest** = `keccak256(0x1901 ‖ domainSeparator ‖ keccak256(QUOTE_TYPEHASH ‖ encoded fields))`
— i.e. standard EIP-712. Any compliant library (viem `hashTypedData`/`signTypedData`,
ethers `signTypedData`, eth-account `encode_typed_data`) produces the correct digest from
the domain + type above. The fields are all static, so encoding is the 32-byte-padded
concatenation.

**Signature → (v, r, s):** the desk takes `v: uint8, r: bytes32, s: bytes32`. Split the
65-byte signature as `r = sig[0:32]`, `s = sig[32:64]`, `v = sig[64]` (27/28). (viem:
`parseSignature`; ethers: `Signature.from`.)

## 3. HTTP API (what the frontend integrates against)

All uint values cross the wire as **decimal strings** (JSON numbers can't hold 1e18).

### `GET /healthz`
```json
{ "ok": true, "quoter": "0x…", "filler": "0x…", "tracker": "0x…" }
```

### `POST /quote`
Request:
```json
{ "side": 1, "n_amount": "10000000000000000", "taker": "0xUser…" }
```
- `side`: `0` = BUY_N (desk buys N → taker **sells** N → frontend calls `fill_sell_n`);
  `1` = SELL_N (desk sells N → taker **buys** N → frontend calls `fill_buy_n`).
- `n_amount`: N units, 1e18-scaled, decimal string.
- `taker` (optional, recommended): bind the quote to this address so it can't be filled
  by anyone else from the mempool. Omit ⇒ open quote (`taker = 0x0`).

Response:
```json
{
  "quote": { "side": 1, "taker": "0x…", "series": "0x…", "amount": "…",
             "price": "…", "min_edge": "…", "nonce": "…", "deadline": "…" },
  "v": 27, "r": "0x…", "s": "0x…",
  "buy_cost_wei": "5100000000000000"
}
```
- `quote` is the exact tuple to submit (same field order as the type).
- `buy_cost_wei` (SELL_N/`side`=1 only): `floor(amount * price / 1e18)` — the **exact**
  `msg.value` the buy-N taker must send (the desk asserts `msg.value == cost`). `null` for sell-N.

### Errors — `{ "error": "<code>", "detail": "…" }`
| status | codes | frontend meaning |
|---|---|---|
| 400 | `bad-side`, `bad-amount`, `over-max-fill`, `bad-request` | bad input, fix & retry |
| 409 | `inventory-full` | desk at its net-long-N cap; won't buy more N now (sell side still quotes) |
| 503 | `desk-paused`, `no-series`, `series-settled`, `near-maturity`, `near-strike`, `not-initialised` | desk unavailable — show "no quote / desk down", don't hammer |

A returned quote can still revert on-chain if state moves (a roll, an oracle tick, a nonce
race). Treat any fill revert as "request a fresh quote" (full taxonomy in the frontend handoff).

## 4. Pricing

`price = fair ± (base spread ± inventory skew)`, always at least `min_edge` in the desk's
favour so it clears the on-chain directional floor.

- `fair` = the desk's `intrinsic_n(series)` view (ETH wei per 1e18 units of N, live oracle).
- bps → 1e18 fixed point: `1 bps = 1e14`. So a `bps` spread as a fraction is `bps * 1e14`,
  and `price = fair * (1e18 ± bps*1e14) / 1e18` (all integer/bigint math).
- **Inventory skew** (only on the net-long-N axis): read `net_n(series)` (int256).
  `util = clamp(net_n / INVENTORY_CAP_N, 0, 1)` in 1e18 (0 when flat or net-short).
  `skewBps = SKEW_K * BASE_SPREAD_BPS * util / 1e18`.
- **DESK_BUYS_N** (`side`=0): if `util >= 1` → return `inventory-full` (stop buying).
  Else `discountBps = BASE_SPREAD_BPS + skewBps`; `price = fair * (1e18 - discountBps*1e14) / 1e18`
  (pays less as inventory grows).
- **DESK_SELLS_N** (`side`=1): `markupBps = max(MIN_EDGE_BPS, BASE_SPREAD_BPS - skewBps)`;
  `price = fair * (1e18 + markupBps*1e14) / 1e18` (sheds faster as inventory grows).
- Clamp `discountBps`/`markupBps` to a sane ceiling (e.g. ≤ 5000 bps) so a misconfig can't
  make `price ≤ 0`.

`q.min_edge` written into the quote = `max(MIN_EDGE_BPS * 1e14, the desk's on-chain MIN_EDGE)`.
Before signing, **re-check the floor** and refuse to sign if it fails (defensive; pricing
already respects it):
```
SELL_N: price >= fair * (1e18 + q.min_edge) / 1e18
BUY_N : price <= fair * (1e18 - q.min_edge) / 1e18
```

## 5. Risk gates (per request, in order)

1. `side ∈ {0,1}`, `0 < amount ≤ MAX_FILL_N` — else 400.
2. desk `paused()` → 503 `desk-paused`.
3. resolve series = `pending_series()` else `active_series()`; `== 0x0` → 503 `no-series`.
4. series `settled()` → 503 `series-settled`; `now + PRE_MATURITY_BUFFER_SECONDS >= MATURITY()` → 503 `near-maturity`.
5. `fair = intrinsic_n(series)`; `== 0` → 503 `near-strike` (outside the desk's no-trade band).
6. price per §4; `inventory-full` → 409.
7. floor re-check (§4); failure → 500 `floor-violation` (a bug — alert).

## 6. Chain reads required

| contract | function | use |
|---|---|---|
| filler | `quoter() -> address` | startup self-check (§8) |
| filler | `MIN_EDGE() -> uint256` | floor for `q.min_edge` |
| filler | `paused() -> bool` | gate |
| filler | `intrinsic_n(series) -> uint256` | fair value |
| filler | `net_n(series) -> int256` | inventory skew |
| filler | `quote_digest(Quote) -> bytes32` | §9 verification only |
| tracker | `pending_series()` / `active_series() -> address` | current vintage |
| series | `settled() -> bool`, `MATURITY() -> uint256` | tradeability gates |

(`series.N()`/`P()` are not needed by the quoter — they're frontend reads for approve/display.)

## 7. Config (env)

| var | meaning |
|---|---|
| `RPC_URL` | chain RPC |
| `QUOTER_PRIVATE_KEY` | the signing key — MUST equal the desk's `quoter()` (host secret) |
| `FILLER_ADDRESS` | the desk (per peg) |
| `TRACKER_ADDRESS` | the spToken tracker (per peg) |
| `PORT`, `CORS_ORIGINS` | server |
| `BASE_SPREAD_BPS` | base spread; **must be ≥ `MIN_EDGE_BPS`** |
| `MIN_EDGE_BPS` | floor written into quotes; service uses `max(this, on-chain MIN_EDGE)` |
| `SKEW_K` | inventory-skew strength (0 disables) |
| `MAX_FILL_N` | largest single fill (N units, 1e18) — **small at launch** |
| `INVENTORY_CAP_N` | net-long-N at which the buy side refuses (1e18) |
| `TTL_SECONDS` | quote lifetime → `deadline = now + TTL` (**short**, ~a few blocks) |
| `PRE_MATURITY_BUFFER_SECONDS` | mirror the desk's `PRE_MATURITY_BUFFER` |

Launch guidance: quote **wide** (`BASE_SPREAD_BPS` 150, `MIN_EDGE_BPS` 100), cap **small**
(`MAX_FILL_N` ~0.1 N), widen only on observed two-sided flow.

## 8. Nonce, TTL, operations

- **Nonce:** a fresh random 256-bit value per quote (the desk only requires single-use, not
  ordering). Random avoids collisions and restart bookkeeping.
- **TTL:** `deadline = now + TTL_SECONDS`; keep short so a signed price can't be sandwiched
  while stale in the mempool.
- **Single instance is fine.** No shared state; restarts just expire in-flight quotes.
- **Startup self-check (required):** read `quoter()` and refuse to boot if it isn't this
  key — fail fast instead of signing quotes that revert `bad sig`. Also read & cache `MIN_EDGE`.
- **Hosting:** any Node/long-running host (Railway/Render/Fly). Key as a platform secret.

## 9. Post-deploy verification (do this before going live)

Prove the service's EIP-712 matches the deployed contract: build a sample `Quote`, compute
its digest locally, and assert it equals the contract's `quote_digest(Quote)` view. If they
differ, the domain/type is wrong and every fill would revert — fix before serving traffic.
Also confirm the signing key recovers to the desk's `quoter()`.

## 10. Recommended stack + non-goals

- **Recommended:** TypeScript + **viem** (matches the frontend's wagmi/viem stack;
  `hashTypedData`/`signTypedData`/`parseSignature` cover §2 exactly) + a minimal HTTP server.
  Any stack with a correct EIP-712 implementation works.
- **Non-goals / MUST NOT:** never hold the owner key; never send transactions or move desk
  funds; never sign a quote that fails the floor re-check (§4); never quote without the
  freshness/maturity/pause gates (§5).

## Pointers
- Frontend integration (the consumer of this API): `docs/handoffs/solo-rfq-frontend-handoff.md`
- Desk design + guardrails + economics: `docs/solo-rfq-spec.md`
- Contract + canonical EIP-712 shapes: `src/periphery/SignedQuoteFiller.vy`, `test/SignedQuoteFiller.fork.t.sol`
