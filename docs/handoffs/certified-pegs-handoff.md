# Certified vs user-created pegs — handoff

> For the dapp builder. Pegs are created permissionlessly (anyone can run the
> Create-a-peg flow), but the app curates trust: **certified pegs** (operator-
> blessed + keeper-maintained) show by default; **user-created pegs** are
> permissionless, unmaintained, and live behind an optional "show more" with
> clear warnings. This is the token-list / verified-vs-unverified pattern. It
> layers on top of the discovery model in `gimbal-frontend-handoff.md` — read
> that first; this only adds the trust/filter layer.

## The data model

There is **no on-chain "certified" bit** (the protocol is admin-free). Certified
= membership in an **operator-curated list**, off-chain. Keep it as a versioned
file in `@gimbal/protocol` (a token-list-style `certifiedPegs.json`), and — key
point — **the keeper reads the exact same list**, so "shown as certified" ⇔
"maintained by our keeper." One source of truth.

Each certified entry carries the curated display metadata (so names never come
from untrusted on-chain strings):

```
{ tracker, assetId, feed, heartbeat, assetSymbol, trackerName, fee, certifiedSince }
```

**Three lists the UI builds:**
- **Certified** = the curated config (validate each still exists on-chain:
  `TrackerFactory.is_tracker(tracker)`, `PeripheryFactory.is_deployed(tracker, fee)`).
- **All pegs** = enumerate `TrackerFactory.tracker_count()` + `tracker_list(i)`.
- **User-created (non-certified)** = All pegs − Certified.

(Optional auto-certification variant: certified = trackers whose `TrackerCreated`
event `creator == <operator address>`. Cleaner sync, but the static list is
better because it also carries curated names/heartbeat and a human "blessed"
decision — recommend the static list.)

**Per-peg facts (for badges + the unverified panel), all on-chain:**
- What it actually tracks: `tracker.ASSET()` → `assetId`, then
  `OracleHub.feeds(assetId)` → `{ aggregator, heartbeat, symbol }`. This is the
  *truth*, regardless of the tracker's display name.
- Periphery/pool: `PeripheryFactory.get_router/get_zapper/get_pool/is_deployed(tracker, fee)`.
- Health: `tracker.share_price()` / `nav()`; the active series' `MATURITY` /
  `settled` (if it's past maturity and unsettled → nobody's maintaining it).
- Creator: the `TrackerCreated` event's indexed `creator`.

## What the two tiers mean (be explicit in the UI)

**Certified** = the operator vouches and actively runs it: curated name + symbol,
a sane (weekend-safe) heartbeat, **keeper-maintained** (rolls/settles happen on
time), periphery deployed, pool seeded. Safe default experience.

**User-created (non-certified)** = permissionless, **not maintained by our
keeper**, with these risks the UI must state:
- **No keeper → may never settle/roll → the peg can stall or break.** (Biggest risk.)
- **Custom heartbeat** → could accept stale oracle prices → mispricing.
- **Untrusted name/symbol** (first-writer-wins on-chain) → could impersonate a
  certified peg. Never trust the on-chain name for these.
- **Thin/again no liquidity** → bad fills.

## UI behavior (per surface)

Apply ONE rule everywhere: **certified by default, user-created behind "show
more," visually distinct, never intermixed.**

- **Home dashboard:** certified pegs as the main grid. Below it, a collapsed
  **"Show N user-created pegs"** expander. When expanded, render them in a muted,
  clearly-separated section with an `Unverified` badge on each.
- **Hold tab (asset picker):** certified assets listed first; a "Show more
  (user-created)" reveal for the rest. Selecting a certified one = normal flow.
  Selecting a user-created one = warning gate (below) before the buy/sell UI.
- **Provide tab (asset picker):** same split. Extra emphasis on the warning for
  user-created — providing liquidity into an unmaintained, possibly-stale peg is
  *more* dangerous than just trading it (your capital sits in it). Require the
  warning ack here too.
- **Leverage tab:** the user only named three surfaces, but apply the same rule
  here for consistency — certified default, user-created behind show-more.

## Badges & states (per peg card)

- `Certified ✓` — operator-maintained.
- `Unverified ⚠` — user-created. Plus contextual sub-flags computed on-chain:
  - `No keeper` (always, for non-certified)
  - `Overdue` if active series is past `MATURITY` and `settled == false`
  - `Custom staleness: <heartbeat>` if heartbeat is unusual (e.g. > a sane cap)
  - `Thin liquidity` if the pool's depth is below a threshold
  - `⚠ Mimics a certified name` if its display name/symbol collides with a
    certified peg — see anti-impersonation.

## Non-certified safeguards (required)

1. **Collapsed by default**, distinct muted styling, `Unverified` badge — never
   styled or ranked like certified.
2. **Warning gate on first interaction** (modal): *"This peg was created by
   `0x…`, is not maintained by Gimbal, uses a custom oracle staleness of `<X>`,
   and may not settle or hold its peg. Verify the underlying feed and proceed at
   your own risk."* with a checkbox to proceed.
3. **Show the raw truth**, not the self-reported name: the underlying Chainlink
   feed address (link out to the explorer / Chainlink), the heartbeat, the
   creator address, and last settle/roll time. The display name is shown as
   *"(unverified name)"*.
4. **Anti-impersonation:** if a non-certified peg's name/symbol matches a
   certified one, suppress the user-supplied name entirely and render it as
   *"Unverified peg tracking `<feed>` — created by `0x…`"* with a prominent
   impersonation warning. Certified pegs must be impossible to spoof in the list.

## Adding / certifying a peg

- **Anyone can create** (keep the Create-a-peg wizard). Its output is a
  **user-created (non-certified)** peg — it lands in the show-more list, not the
  certified grid. (Optionally show a "Request certification" link on user-created
  pegs.)
- **Certifying** is an operator action, off-chain: add the entry to
  `certifiedPegs.json` (which also enrolls it in the keeper), after confirming
  periphery is deployed and the pool is seeded. No on-chain permission needed —
  certification is curation, not a contract role.

## On-chain reference

| UI need | Call |
|---|---|
| enumerate all pegs | `TrackerFactory.tracker_count()`, `tracker_list(i)`, `is_tracker(addr)` |
| what a peg tracks (truth) | `tracker.ASSET()` → `OracleHub.feeds(assetId) -> (aggregator, heartbeat, symbol)` |
| creator (for unverified) | `TrackerCreated` event, indexed `creator` |
| periphery + pool | `PeripheryFactory.get_router/get_zapper/get_pool/is_deployed(tracker, fee)` |
| peg health | `tracker.share_price()`, `nav()`; active series `MATURITY`/`settled` |
| certified set | `@gimbal/protocol` `certifiedPegs.json` (same list the keeper consumes) |

Certified metadata (name/symbol/heartbeat) comes from the config; for
user-created pegs everything comes from chain and is treated as untrusted.
