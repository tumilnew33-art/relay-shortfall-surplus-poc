# PoC: SHORTFALL legs credit uncapped, unauthenticated surplus to any pool account

Relay bug bounty report R-02. Run with Foundry (tested with forge 1.9.0):

```
forge test -vv
```

No setup, no network, no fork needed. All dependencies are vendored under `lib/`
(the settlement contracts are the unmodified sources from
`relayprotocol/relay-settlement` at commit `b2f3e0e`).

## What it proves (2/2 tests pass)

- **TEST 1** `test_divertSponsorSubsidyAndUserSurplus`: a FIXED leg draws a
  sponsor's 50 USDC (properly authorized); a SHORTFALL leg on the ORDER INPUT
  token with target = the 900 USDC minimum then credits the 150 USDC surplus
  (50 sponsor subsidy + 100 user surplus) to the solver's pool account,
  carrying EMPTY authorization bytes. The executor still receives exactly its
  900 minimum, so settlement "succeeds".
- **TEST 2** `test_divertStrandedBalanceFromPriorOrder`: a SHORTFALL leg on a
  token the resolver holds as stranded residue from an earlier order (25 DAI)
  credits the whole stranded balance to the solver's account — no draw, no
  authorization, no relation to this order at all.

## Setup notes

- `PoolDrawResolver`, `PoolResolverBase`, `RelayFundingPool`, and
  `ResolverSandbox` are the real, unmodified contracts.
- The executor and Hub are minimal mocks (only the request-hash view and the
  privileged `execute` invocation matter to the resolver); the "order input"
  funding simulates the executor's transfer to the resolver.
- Local test only; nothing here touches mainnet.
