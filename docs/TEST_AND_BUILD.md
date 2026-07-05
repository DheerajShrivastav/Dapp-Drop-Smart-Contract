# Test Coverage & Build — Web3Campaigns

> As of `feature/cancel-campaign` (forked from `dev` post-invariant-hardening merge).

## Toolchain (now set up)

Foundry **1.7.1** installed (`~/.foundry/bin` — `export PATH="$HOME/.foundry/bin:$PATH"`). Submodules initialized (`lib/forge-std`, `lib/openzeppelin-contracts` + its sub-submodules). `foundry.toml`: solc `0.8.31`, evm `cancun`, `viaIR=true`, optimizer (runs=200), remapping `@openzeppelin/=lib/openzeppelin-contracts/`, plus an `[invariant]` profile (`runs=128`, `depth=30`, `fail_on_revert=false`).

To build/run from a clean clone: `git submodule update --init --recursive` → `forge build` → `forge test`.

## Test suites (84 passing, 9 suites)

Unit/example-based:
- `test/CampaignStorage.t.sol` (11) — lifecycle/access/batch/withdrawETH; batch task verification via `batchVerifyTaskCompletionWithSignatures`.
- `test/StageAFixes.t.sol` (14) — ONCHAIN_HOLD 64-byte happy/bad-length/insufficient-balance, ONCHAIN_TX self-revert + signer-verify, ONCHAIN_HOLD signature-cannot-verify, signed-attestation expiry/non-signer/replay/reverification, flagAccount block/clear/only-moderator, createCampaign-paused.
- `test/MerkleSettlement.t.sol` (15) — ERC20 escrow + Merkle settlement: single/two-leaf claims, double-claim, bad proof/amount, non-allocated account, pre-root, not-ended, insufficient-escrow, paused, funding-not-configured, funding-accumulates, root-timing, grace-gated sweep + double-sweep, **cross-campaign drain regression** (`test_ClaimERC20_BlockedAfterSweep_NoCrossCampaignDrain`).
- `test/NFTSettlement.t.sol` (10) — ERC721/ERC1155 claims, double-claim, bad proof, pre-root, ERC1155 over-allocation, cross-campaign drain guard, deposit/custody, grace-gated sweep. Includes minimal mintable `MockERC721`/`MockERC1155` (reused by the NFT invariant handler).
- `test/SignatureVerification.t.sol` (16) — happy path + participant-count invariant, anyone-can-submit, false-attestation-doesn't-count, campaign-status guards, task-not-found, signer rotation/revocation, domain isolation, batch atomicity, array-length/empty-batch reverts.
- `test/CancelCampaign.t.sol` (9) — Draft/Open cancellation success, ERC20 refund, **the abuse vector closed** (`test_CancelCampaign_RevertsOnceAParticipantHasEngaged` — cancel blocked the moment one participant completes a task), status guards (Ended/already-Cancelled/not-host/paused), immediate NFT reclaim post-cancel (no grace wait). Includes a local minimal mintable `MockERC721Cancel`.

Stateful-fuzz invariant suites (`test/invariant/`) — each pairs a `*Handler.sol` (fuzzed actions + ghost accounting) with a `*.invariant.t.sol` (assertions):
- **`EscrowSolvency.invariant.t.sol`** (3 invariants) — drives create/fund/settle → claim → sweep across many ERC20 campaigns sharing one reward token. **Found and pinned a real bug** (see `docs/SECURITY_FINDINGS.md` #3): `claimERC20` didn't check `_erc20Swept`, allowing a cross-campaign drain. Now fixed and asserted: `invariant_globalTokenAccounting`, `invariant_perCampaignBacked`, `invariant_distributedLeqEscrowed`.
- **`NFTInventory.invariant.t.sol`** (4 invariants) — same lifecycle for ERC721 (unique tokenIds) and ERC1155 (single shared asset id across all campaigns, deliberately fuzzing the commingled-pool case). Confirmed the NFT design does **not** have the ERC20 bug — `claimNFT` and `withdrawUnclaimed*` share the same per-campaign map.
- **`AttestationVersion.invariant.t.sol`** (2 invariants) — adversarially fuzzes stale-version replay, skip-ahead, non-signer, and expired-deadline attempts against the signed-attestation replay guard via `try/catch` (not `vm.expectRevert`, which would mask a real bypass under `fail_on_revert=false` — see Known Issues below); confirms the on-chain version only ever advances by exactly 1 via a genuinely valid signature. (An earlier `afterInvariant()` coverage-sanity hook was removed — it was a per-run check that could legitimately fail on a short run that happened to miss one path, and Foundry replays such failures as cached deterministic counterexamples; the call-summary table already shows both paths are exercised copiously.)

Claim tests build real Merkle proofs via Solidity helpers matching the OZ StandardMerkleTree + sorted-pair convention. Signature tests/handlers build real EIP-712 digests/signatures via `vm.sign` against a locally-computed domain separator mirroring `CampaignStorage`'s `TASK_ATTESTATION_TYPEHASH`.

## Still UNTESTED / gaps
- `completeTask` social self-assertion timing/anti-spam (30s) edge cases, `MAX_PARTICIPANTS_LIMIT`, batch length/size reverts.
- Multi-leaf NFT proofs in the unit suite (current NFT unit tests use single-leaf roots; the invariant suite exercises many campaigns but each with its own single-leaf root) — a dedicated 2+ leaf NFT tree unit test would still add value.
- No invariant coverage yet for the reward-configuration side (e.g., `configureERC20Reward`/deposit access control fuzzing) — current invariants focus on the settlement/claim/sweep lifecycle.
- No dedicated invariant/fuzz test for `cancelCampaign` yet (unit tests only) — a candidate property: cancelling never leaves more ERC20 escrowed in the contract than `_erc20Escrowed[id]` (i.e., the refund always fully drains what was owed).

## Known issues
- CI (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, `forge test -vvv` under `FOUNDRY_PROFILE=ci`, but `foundry.toml` defines no `[profile.ci]` (falls back to default). Cosmetic.
- `actions/checkout@v4` in CI triggers a Node 20 deprecation warning — non-blocking, worth bumping to v5.
- `block.timestamp` comparison lints (rate-limit/anti-spam) — informational.
- **Contract size**: `Web3Campaigns` runtime is 21.7KB against the 24.576KB EIP-170 limit — ~2.9KB headroom (shrinking; watch closely, e.g. the still-open protocol-fee item will eat further into it). Check `forge build --sizes` before adding more logic to the entrypoint contract; consider splitting a new logic contract into the diamond if this gets tight. (Invariant/handler test files do not affect this — they're not part of the deployed contract.)
- A handler bug encountered during development, worth remembering for future ERC1155 test/handler contracts: OZ's `_mint` invokes the ERC1155 receiver hook, so any contract that receives freshly-minted ERC1155 tokens (e.g. a fuzz handler) must inherit `ERC1155Holder` or implement `onERC1155Received` — otherwise the mint reverts silently under `fail_on_revert=false`, which can make an invariant vacuously true. Always sanity-check a new handler's call-summary table for suspicious 100%-revert rows.
- Using `vm.expectRevert` **inside** a stateful-fuzz handler under `fail_on_revert=false` is fragile: if the wrapped call unexpectedly succeeds (a real bug), `vm.expectRevert`'s own mismatch failure reverts the whole handler call — undoing the buggy state change too — and the fuzzer silently discards it as "just another revert," masking the bug. Prefer `try/catch` with a loud `revert("...")` on the unexpected-success branch instead (see `AttestationVersionHandler.sol`).

## Deploy
`script/DeployWeb3Campaigns.s.sol` — `new Web3Campaigns()`, no constructor args/secrets. Makefile `deploy-sepolia` uses `--account` keystore. Related: [ARCHITECTURE.md](ARCHITECTURE.md), [REWARD_SYSTEM.md](REWARD_SYSTEM.md), [TASK_VERIFICATION.md](TASK_VERIFICATION.md), [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
