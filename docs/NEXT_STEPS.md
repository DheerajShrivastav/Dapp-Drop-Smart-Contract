# Next Steps — Web3Campaigns v0.3+

> Pick-up list. v0.3 escrow + Merkle settlement and Phase 2 signature verification are both merged to `dev` (PR #1, PR #2). Invariant/fuzz hardening is in progress on `feature/invariant-tests` (75 tests passing). Ordered roughly by priority.

## Hardening / open items (on the current model)

- [x] **Fuzz / invariant tests.** Done on `feature/invariant-tests`: escrow-solvency (`sum(ERC20 claims) <= escrowed`), NFT inventory (claimed <= deposited, ERC721 + ERC1155), and attestation-version replay-guard invariants. **Found and fixed a real HIGH-severity bug already live on `dev`**: `claimERC20` didn't check `_erc20Swept`, letting a late claim on a swept campaign drain a *different* campaign's escrow (ERC20 escrow is a commingled pool). See `docs/SECURITY_FINDINGS.md` #3 and `test/invariant/EscrowSolvency.invariant.t.sol`. **This fix should be prioritized for review/merge — it's a security fix to code already on `dev`.**
- [ ] **Allocation-fairness dispute window.** Escrow guarantees funds can't be rugged after a root is committed, but a malicious host can publish an unfair root (omit/short-change winners). Add a challenge/timelock window between `setERC20MerkleRoot`/`setNFTMerkleRoot` and when claims/sweeps finalize. (Both ERC20 + NFT roots.)
- [ ] **Fee-on-transfer ERC20 handling.** Escrow accounting assumes standard tokens; fee-on-transfer tokens under-fund escrow. Either measure received balance in `fundCampaignERC20` (balance-before/after) or whitelist tokens. Document the assumption either way.
- [ ] **Multi-leaf NFT proof test** in the unit suite (current NFT unit tests use single-leaf roots; the invariant suite covers many campaigns but each still with a single-leaf root).
- [ ] **Reward-configuration invariant coverage** — current invariants focus on the settlement/claim/sweep lifecycle; access-control fuzzing on `configureERC20Reward`/deposits is still open.
- [ ] **`withdrawETH` treasury restriction (low).** Replace the arbitrary `_to` with a stored, admin-settable treasury to clear the `arbitrary-send-eth` flag.
- [ ] **Repo-wide `forge fmt`.** Repo does not pass `forge fmt --check` (pre-existing). Do a single formatting pass so CI's `forge fmt --check` goes green — as its own commit to keep diffs reviewable.
- [ ] **`grantHostRole` is intentionally open.** Revisit when adding the staked/curated hosting model (founder decision to leave open for now).
- [ ] **`.code.length` check** on `configureERC20Reward` / NFT deposits to reject EOA/empty token addresses early.
- [ ] **Contract size headroom.** `Web3Campaigns` runtime is 21.1KB / 24.576KB limit (3.4KB left) after Phase 2. Watch `forge build --sizes` before adding more logic; consider splitting a new logic contract into the diamond if a future feature won't fit.

## Phase 2 (merged to `dev` via PR #2)

- [x] **Signature-based off-chain task verification.** `SIGNER_ROLE` + EIP-712 `TaskAttestation` (`{campaignId, participant, taskIndex, completed, version, deadline}`) — `verifyTaskCompletionWithSignature`/`batchVerifyTaskCompletionWithSignatures` **replace** (not run alongside) the old host-tx `verifyTaskCompletion`/`batchVerifyTaskCompletion`. Signer rotation/revocation via plain `AccessControl` `grantRole`/`revokeRole(SIGNER_ROLE, ...)`. Replay guard = per-`(participant,campaign,task)` version counter, which doubles as an update/reverification mechanism (signer can flip `completed` back to false or re-affirm it by signing the next version). Single-signer for now (no N-of-M threshold). Trust-minimized, not trustless — documented in `docs/TASK_VERIFICATION.md`. Merged to `dev` via the `no-mistakes` pipeline (PR #2), which itself caught and fixed a real bug during review (signer revocation bypassable via self-assertion — see `TaskManagedBySignature`).
- [ ] **Protocol fee.** Simple `feeBps` skimmed at `fundCampaignERC20` (and/or NFT deposit), routed to a treasury. Get it into the data model before integrators exist.
- [ ] **`cancelCampaign` + refund.** Let a host cancel in Draft (and maybe Open) and refund escrowed ERC20/NFTs — an "oops" path for misconfigured campaigns.

## Phase 3 (post-PMF)

- [ ] **Sybil gating** — World ID / Gitcoin Passport at claim for high-value campaigns (the `HUMANITY_VERIFICATION` task type is currently unenforced).
- [ ] **Gasless claims** — ERC-2771 / paymaster so users don't pay gas to claim small rewards.
- [ ] **`MAX_PARTICIPANTS_LIMIT` enforcement** and `JOIN_COOLDOWN` (declared constants currently unenforced).
- [ ] **Staked/open hosting tier** — `selfRegisterAsHost() payable` gated by a refundable stake / creation fee, slashable on abuse (the deliberate version of today's open `grantHostRole`).

## Process reminders (from CLAUDE.md)
Before each commit: `forge build` clean · `forge test` green · review the full diff. Toolchain: `export PATH="$HOME/.foundry/bin:$PATH"`. See [[TEST_AND_BUILD]], [[SECURITY_FINDINGS]], [[REWARD_SYSTEM]].
