# Morpheus Bounty PoC — C-L2-1: DepositPool `claimReferrerTierFor` ignores `claimReceiver`

**Finding.** DepositPool has two third-party claim paths sharing one authorisation
set (`claimSender`). `claimFor` honours a position owner's protected `claimReceiver`:
when one is set, it overrides the caller's `receiver_` argument. `claimReferrerTierFor`
never reads `claimReceiver` at all — it checks only that the caller is an authorised
claim sender, then pays the referrer's accrued tier rewards to any `receiver_` the
caller names, **even after the referrer set a protected claim receiver**. That set-a-receiver
step is the exact mitigation the known finding W-H2 documents for the staking path;
on the referrer-tier path it is inert. The theft also stamps the victim's `lastClaim`
(starting the 14-day after-claim lock), and a zero-address variant destroys the
rewards outright.

**Target.** DepositPool (Ethereum), stETH proxy `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`;
all five asset pools share implementation `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`
(Sourcify-verified source). Function: `claimReferrerTierFor()`.

## Run it

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`).
One command from the repo root:

```
forge test
```

The fork is pinned in-code (`test/Lane2.t.sol`, `setUp()`): Ethereum mainnet block
**26,480,107** via the public endpoint `https://eth.drpc.org`. No other setup, no
keys, no live-chain transactions — the tests run entirely against a local fork.
If that endpoint is unreachable, swap in another archive-capable Ethereum RPC at
the same block in the `createSelectFork` line.

## What the tests assert

All actors are fresh unprivileged EOAs (no owner/admin/multisig impersonation
anywhere). Assertions are on the mint payload's receiver and amount handed to the
LayerZero transport (see the disclosed plumbing note below).

Position setup for every test: a staker stakes 100 stETH naming a referrer; over one
19-day window the referrer accrues tier rewards (~82.13 MOR at the pin) and the
staker accrues staking rewards (~553.04 MOR).

- `test_C1_referrerTierFor_ignores_set_claimReceiver` — **centrepiece (branch A).**
  The referrer sets `claimReceiver` to their own safe address *after* accrual; the
  authorised sender still diverts the full referrer-tier reward to himself. The
  victim's own claim then reverts on the 14-day after-claim lock (stamped by the
  theft), and after the lock, `DS: nothing to claim`.
- `test_C1b_referrerTierFor_unsetReceiver_anyReceiver` — **branch B.** Receiver
  unset: the sender pays the full amount to an arbitrary third party he chooses.
- `test_C1c_referrerTierFor_zeroReceiver_burns` — **branch C.** Receiver =
  `address(0)`: the full accrual is consumed into a mint payload naming the zero
  address — the rewards are destroyed, not redirected.
- `test_control_WH2_unsetReceiver_claimFor_steals` — **known-issue control.**
  The W-H2 named branch (`claimFor`, receiver unset) reproduced as the rig control.
- `test_contrast_claimFor_respects_set_claimReceiver` — **contrast.** Identical
  setup on `claimFor`: the set receiver overrides the sender's `receiver_` argument
  and is paid in full — the protection the referrer path lacks.

## Expected output

```
Ran 5 tests for test/Lane2.t.sol:Lane2Test
[PASS] test_C1_referrerTierFor_ignores_set_claimReceiver() (gas: ...)
[PASS] test_C1b_referrerTierFor_unsetReceiver_anyReceiver() (gas: ...)
[PASS] test_C1c_referrerTierFor_zeroReceiver_burns() (gas: ...)
[PASS] test_contrast_claimFor_respects_set_claimReceiver() (gas: ...)
[PASS] test_control_WH2_unsetReceiver_claimFor_steals() (gas: ...)
Suite result: ok. 5 passed; 0 failed; 0 skipped
```

## Disclosed harness plumbing

Two stubs, neither touching the authorisation logic under test (100% deployed
DepositPool code):

1. **LayerZero endpoint stand-in.** The LayerZero EndpointV1 gateway code at its
   deployed address is replaced by a recording contract (`LZRecorder`, `vm.etch`)
   so the mint payload — receiver + amount — that
   `DepositPool → Distributor → L1SenderV2` hands to LayerZero can be asserted.
   The endpoint is third-party transport; its fee mechanics are not the surface
   under test.
2. **Oracle answers pinned.** Tests warp up to 19 days, past the deployed feeds'
   freshness windows, so the ChainLink consumer's answers are pinned via
   `vm.mockCall` to the values it returns at the fork block. The price path is
   not the surface under test.

Also: a static fork produces no Lido rebase, so `_accrue()` donates 10 stETH to
the Distributor to create real distributable yield before triggering
`distributeRewards(0)`. The donation-forced distribution shape is C4 QA-01 —
KNOWN; it is used only as a yield source, never as a claim.

## Layout

- `test/Lane2.t.sol` — the PoC (3 candidate branches + known-issue control + contrast).
- `src/Ifaces.sol`, `src/Lane2Ifaces.sol` — minimal hand-written interfaces for the
  deployed contracts, plus the `LZRecorder` stand-in described above.
- `lib/forge-std/` — forge-std v1.17.0 (vendored).
