# Security & Correctness Findings — Web3Campaigns

> Original code-audit findings, annotated with current status through the invariant-test hardening pass (`feature/invariant-tests`, forked from `dev` post-Phase-2 merge). Verify line numbers before acting.

## Status legend
✅ FIXED · 🟡 OPEN · 🔵 INTENTIONAL (founder decision) · ⏳ ADDRESSED IN PROGRESS

## HIGH

1. 🔵 **`grantHostRole` is unguarded** (CampaignManagement.sol) — anyone can self-grant `HOST_ROLE`. **Left open intentionally by founder decision (for now).** Revisit when adding the staked/curated hosting model.
2. ✅ **ERC20 rewards pulled from host's live wallet** — **FIXED in Stage B1.** Rewards are now escrowed in the contract (`fundCampaignERC20`) and paid from escrow via Merkle settlement (`claimERC20`). No host-pull, no allowance-revoke brick, no rug. See [[REWARD_SYSTEM]].
3. ✅ **Cross-campaign ERC20 escrow drain via `claimERC20` after sweep** — **FOUND AND FIXED by the escrow-solvency invariant suite** (`test/invariant/EscrowSolvency.invariant.t.sol`), not by manual review, and was **live on `dev`** (shipped in B1) before this fix. `claimERC20` never checked `_erc20Swept` despite a code comment claiming it did. Because ERC20 escrow is a single commingled token balance (unlike NFTs, which are earmarked per campaign), after a host swept campaign A's unclaimed funds back to themselves post-grace, a late claimant on A could still claim — paid out of **campaign B's** escrow, leaving B underwater. Fixed: `claimERC20` now reverts `AlreadySwept` once a campaign has been swept. Regression test: `test_ClaimERC20_BlockedAfterSweep_NoCrossCampaignDrain`.

## MEDIUM

4. ✅ **Silent zero-reward claims** (FCFS/TIERED/pool-exhaustion) — **FIXED** for ERC20 (B1) and NFT (B2): only winners with a valid proof can claim; `InsufficientEscrow`/`NFTNotEscrowed` revert rather than silently paying 0. Legacy NFT pool path removed in B2.
5. ✅ **On-chain hold verification broken** (52-byte vs 64-byte `abi.decode`) — **FIXED in Stage A.** `completeTask` now requires the correct 64-byte `abi.encode(address,uint256)` for `ONCHAIN_HOLD_ERC20/721`. (Tests in `test/StageAFixes.t.sol`.)
6. ✅ **Claim-rank front-running** (TIERED/FCFS earliest-claimer advantage) — **FIXED** for ERC20 (B1) and NFT (B2): allocations are predetermined in the Merkle tree, not by claim order.
7. ✅ **`ONCHAIN_TX` task hard-reverts / bricks campaigns** — **FIXED in Stage A.** No longer reverts in `completeTask` (now `NotSelfVerifiable`); is settled via `verifyTaskCompletionWithSignature`/`batchVerifyTaskCompletionWithSignatures` (Phase 2 — replaced the old host-tx `verifyTaskCompletion`/`batchVerifyTaskCompletion`). `ONCHAIN_HOLD_*` remain self-verified and signer-unoverridable.

## LOW / INFORMATIONAL

8. ✅ **`_suspiciousActivityScore` dead state** — **FIXED in Stage A.** Wired via `MODERATOR_ROLE` + `Web3Campaigns.flagAccount(user, score)` + `AccountFlagged` event; gate in `completeTask` now functional.
9. ✅ **`endCampaign` comment/code contradiction** — **FIXED in Stage A** (comment corrected; behavior = end only at/after `endTime`, no early end).
10. 🟡 **`withdrawETH` arbitrary `_to`** (admin-gated, low risk) — still present; deferred. Consider restricting to a stored treasury.
11. ✅ **Unguarded external-call loops** — claims are single-transfer (ERC20 `safeTransfer`; NFT one token per claim). Deposit/sweep loops are host-only, capped at 100/call, and `nonReentrant`.
12. ✅ **Pause coverage gap on `createCampaign`** — **FIXED in Stage A** (virtual + `whenNotPaused` wrapper). The other reward/host functions were already pause-gated via the virtual `onlyHost` override.
13. 🟡 `== 0` existence checks (id-sentinel `incorrect-equality`) — low risk by design; unchanged.

## Not yet implemented (deferred)
MAX_PARTICIPANTS enforcement, JOIN_COOLDOWN, cancel-campaign/refund, protocol fee, N-of-M threshold signing, sybil gating, gasless claims. `.code.length` token checks on `configureERC20Reward`. Allocation-fairness dispute window (Merkle root is host-controlled, see below).

## New surface added in the invariant-test pass (review focus)
- **Escrow-solvency invariant found finding #3 above** (cross-campaign ERC20 drain via `claimERC20` after sweep). This is the first bug this project's invariant/fuzz testing has caught — see `test/invariant/EscrowSolvency.invariant.t.sol`.
- **NFT inventory invariant confirmed no equivalent bug** for ERC721/ERC1155: `claimNFT` and `withdrawUnclaimedERC721/1155` check the *same* per-campaign escrow map, so a swept slice is already zeroed before a late claim could reach it. Fuzzed with a shared ERC1155 asset id across many campaigns specifically to stress the commingled-pool case (`test/invariant/NFTInventory.invariant.t.sol`).
- **Attestation-version invariant confirmed the signed-attestation replay guard holds** under adversarial fuzzing (stale-version replay, skip-ahead, non-signer, expired-deadline attempts) — the on-chain version only ever advances by exactly 1 via a genuinely valid next-version signature (`test/invariant/AttestationVersion.invariant.t.sol`).
- Foundry `[invariant]` config added (`foundry.toml`): 128 runs, depth 30, `fail_on_revert = false` (handler calls are expected to revert on bounded edge cases; ghosts stay consistent on discard).

## New surface added in Phase 2 (review focus)
- **`SIGNER_ROLE` key compromise** — a compromised signer can mint arbitrary task completions until revoked via `revokeRole(SIGNER_ROLE, ...)`. There is no on-chain rate limit or threshold; single-signer by design. Rotate quickly if compromised. See [TASK_VERIFICATION.md](TASK_VERIFICATION.md).
- **Zero-address participant guard** — `verifyTaskCompletionWithSignature` explicitly rejects `_participant == address(0)` (`Web3Campaigns__ZeroAddress`).
- **Signature replay/update model** — per-`(participant,campaign,task)` version counter; replay is impossible because the accepted version is advanced atomically. A signer *can* flip `completed` back to `false` by signing the next version — intentional (correction/re-verification path), but means partial completion counts may decrease for any off-chain aggregation that queries task state.
- **`completeTask` guard** — if any attestation has ever been accepted for a `(participant, campaign, task)` triple (`version > 0`), `completeTask` reverts `TaskManagedBySignature` to prevent mixing self-assertion and signer-controlled state.
- **Domain binding** — `verifyingContract` is encoded in the EIP-712 domain, so a signature produced for one deployment cannot validate against another. Tested in `test/SignatureVerification.t.sol`.

## New surface added in B1–B2 (review focus)
- Escrow accounting (`_erc20Escrowed`/`_erc20Distributed`) assumes **standard (non-fee-on-transfer) ERC20**; fee-on-transfer tokens would under-fund escrow. Document/whitelist or measure received balance if support is needed.
- **Merkle root is host-controlled and updatable while Ended** — a malicious host can publish a root that omits/short-changes users (off-chain trust in the host's allocation). Escrow only guarantees funds *can't be rugged after commitment*, not that the allocation is fair. Consider a dispute/timelock window later. Applies to both ERC20 and NFT roots.
- **NFT cross-campaign isolation** is enforced by the per-campaign `_escrowedERC721`/`_escrowedERC1155` ownership maps (tested: `test_ClaimNFT_CannotDrainNonEscrowedToken`). A campaign can only ever settle NFTs actually escrowed under it.
- NFT custody relies on OZ `ERC721Holder`/`ERC1155Holder`; `supportsInterface` resolves the `AccessControl` + `ERC1155Holder` diamond.
- ERC1155 over-allocation in a root is bounded by escrow: a leaf exceeding the escrowed balance reverts `NFTNotEscrowed` rather than over-paying.

Related: [[REWARD_SYSTEM]], [[TEST_AND_BUILD]], [[ARCHITECTURE]].
