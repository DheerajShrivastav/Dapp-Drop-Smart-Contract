# Security & Correctness Findings — Web3Campaigns

> Original code-audit findings, annotated with current status on `feature/v0.3-security-hardening`. Verify line numbers before acting.

## Status legend
✅ FIXED · 🟡 OPEN · 🔵 INTENTIONAL (founder decision) · ⏳ ADDRESSED IN PROGRESS

## HIGH

1. 🔵 **`grantHostRole` is unguarded** (CampaignManagement.sol) — anyone can self-grant `HOST_ROLE`. **Left open intentionally by founder decision (for now).** Revisit when adding the staked/curated hosting model.
2. ✅ **ERC20 rewards pulled from host's live wallet** — **FIXED in Stage B1.** Rewards are now escrowed in the contract (`fundCampaignERC20`) and paid from escrow via Merkle settlement (`claimERC20`). No host-pull, no allowance-revoke brick, no rug. See [[REWARD_SYSTEM]].

## MEDIUM

3. ✅ **Silent zero-reward claims** (FCFS/TIERED/pool-exhaustion) — **FIXED** for ERC20 (B1) and NFT (B2): only winners with a valid proof can claim; `InsufficientEscrow`/`NFTNotEscrowed` revert rather than silently paying 0. Legacy NFT pool path removed in B2.
4. ✅ **On-chain hold verification broken** (52-byte vs 64-byte `abi.decode`) — **FIXED in Stage A.** `completeTask` now requires the correct 64-byte `abi.encode(address,uint256)` for `ONCHAIN_HOLD_ERC20/721`. (Tests in `test/StageAFixes.t.sol`.)
5. ✅ **Claim-rank front-running** (TIERED/FCFS earliest-claimer advantage) — **FIXED** for ERC20 (B1) and NFT (B2): allocations are predetermined in the Merkle tree, not by claim order.
6. ✅ **`ONCHAIN_TX` task hard-reverts / bricks campaigns** — **FIXED in Stage A.** No longer reverts in `completeTask` (now `NotSelfVerifiable`); is host-verifiable via `verifyTaskCompletion`/`batchVerifyTaskCompletion`. `ONCHAIN_HOLD_*` remain self-verified and host-unoverridable.

## LOW / INFORMATIONAL

7. ✅ **`_suspiciousActivityScore` dead state** — **FIXED in Stage A.** Wired via `MODERATOR_ROLE` + `Web3Campaigns.flagAccount(user, score)` + `AccountFlagged` event; gate in `completeTask` now functional.
8. ✅ **`endCampaign` comment/code contradiction** — **FIXED in Stage A** (comment corrected; behavior = end only at/after `endTime`, no early end).
9. 🟡 **`withdrawETH` arbitrary `_to`** (admin-gated, low risk) — still present; deferred. Consider restricting to a stored treasury.
10. ✅ **Unguarded external-call loops** — claims are single-transfer (ERC20 `safeTransfer`; NFT one token per claim). Deposit/sweep loops are host-only, capped at 100/call, and `nonReentrant`.
11. ✅ **Pause coverage gap on `createCampaign`** — **FIXED in Stage A** (virtual + `whenNotPaused` wrapper). The other reward/host functions were already pause-gated via the virtual `onlyHost` override.
12. 🟡 `== 0` existence checks (id-sentinel `incorrect-equality`) — low risk by design; unchanged.

## Not yet implemented (deferred)
MAX_PARTICIPANTS enforcement, JOIN_COOLDOWN, cancel-campaign/refund, signature-based off-chain task verification (Phase 2), protocol fee, sybil gating, gasless claims. `.code.length` token checks on `configureERC20Reward`.

## New surface added in B1–B2 (review focus)
- Escrow accounting (`_erc20Escrowed`/`_erc20Distributed`) assumes **standard (non-fee-on-transfer) ERC20**; fee-on-transfer tokens would under-fund escrow. Document/whitelist or measure received balance if support is needed.
- **Merkle root is host-controlled and updatable while Ended** — a malicious host can publish a root that omits/short-changes users (off-chain trust in the host's allocation). Escrow only guarantees funds *can't be rugged after commitment*, not that the allocation is fair. Consider a dispute/timelock window later. Applies to both ERC20 and NFT roots.
- **NFT cross-campaign isolation** is enforced by the per-campaign `_escrowedERC721`/`_escrowedERC1155` ownership maps (tested: `test_ClaimNFT_CannotDrainNonEscrowedToken`). A campaign can only ever settle NFTs actually escrowed under it.
- NFT custody relies on OZ `ERC721Holder`/`ERC1155Holder`; `supportsInterface` resolves the `AccessControl` + `ERC1155Holder` diamond.
- ERC1155 over-allocation in a root is bounded by escrow: a leaf exceeding the escrowed balance reverts `NFTNotEscrowed` rather than over-paying.

Related: [[REWARD_SYSTEM]], [[TEST_AND_BUILD]], [[ARCHITECTURE]].
