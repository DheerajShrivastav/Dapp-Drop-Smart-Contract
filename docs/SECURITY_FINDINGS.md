# Security & Correctness Findings — Web3Campaigns (`dev`)

Findings from a code-only audit of the `dev` branch (docs are stale — trust code). **Verify each still applies (line numbers drift) before acting.** Ordered by severity.

## HIGH

1. **`grantHostRole` is unguarded** (CampaignManagement.sol ~L33-35) — NO access modifier; anyone can self-grant `HOST_ROLE` and create campaigns. Only `revokeHostRole` is admin-gated. Almost certainly unintended — should be `onlyRole(DEFAULT_ADMIN_ROLE)`.
2. **ERC20 rewards pulled from host's live wallet, not escrow** (ParticipantManagement.sol ~L343): `safeTransferFrom(campaign.host, claimant, amount)`. If the host revokes allowance or drains their balance, **every** `claimReward` reverts for all participants → accidental or malicious brick/rug. Only NFTs are truly escrowed. Slither flags as `arbitrary-send-erc20`. Fix = escrow ERC20 in the contract at config time.

## MEDIUM

3. **Silent zero-reward claims**: FCFS after pool empty, TIERED with unmatched rank, or exhausted NFT pool all SUCCEED, set `_participantClaimedReward = true`, but pay 0 — participant permanently barred from re-claiming even if pool/allowance is later replenished. Consider reverting or deferring the claimed flag.
4. **On-chain hold verification is broken** (`completeTask`, ParticipantManagement.sol): checks `verificationData.length != 52` then `abi.decode(..., (address,uint256))` which needs 64 bytes. Length check (packed/52) and decode (standard/64) contradict → `ONCHAIN_HOLD_ERC20/ERC721` tasks are effectively unusable. (Audit-plan "Issue 12", NOT fixed.)
5. **Claim-rank front-running**: TIERED/FCFS best rewards go to the earliest `claimReward` tx → MEV / race. No fair ordering.
6. **`ONCHAIN_TX` task type hard-reverts** in both `completeTask` and `verifyTaskCompletion`. A non-optional ONCHAIN_TX task makes `claimReward` permanently impossible (bricks the campaign).

## LOW / INFORMATIONAL

7. **`_suspiciousActivityScore` is dead state** — read in `completeTask` but NEVER written anywhere; the anti-abuse gate does nothing. (Slither: uninitialized-state.)
8. **`endCampaign` requires `block.timestamp >= endTime`** despite a comment claiming early-end is allowed — code contradicts comment.
9. **`withdrawETH`** sends the full balance to a caller-supplied `_to` (arbitrary-send-eth) — mitigated by `DEFAULT_ADMIN_ROLE` + `nonReentrant` + zero-addr check.
10. **Unguarded external-call loops**: `addNFTsToPool` and `_processNFTReward` are NOT individually `nonReentrant` (only the `Web3Campaigns` wrappers are); bounded by caps, so low risk.
11. **Pause coverage gaps**: `createCampaign`, `addTaskToCampaign`, and the reward-config setters are NOT `whenNotPaused`-wrapped (still callable while paused).
12. Many `== 0` existence checks (id-sentinel) flagged `incorrect-equality` — low risk by design.

## Not yet implemented

From `SECURITY_AUDIT_PLAN.md` (treat that plan as historical): `MAX_PARTICIPANTS` enforcement, `JOIN_COOLDOWN`, `ERC721_BATCH`, remove-task, cancel-campaign, `.code.length` token checks.

See also [REWARD_SYSTEM.md](REWARD_SYSTEM.md), [TEST_AND_BUILD.md](TEST_AND_BUILD.md), [ARCHITECTURE.md](ARCHITECTURE.md).
