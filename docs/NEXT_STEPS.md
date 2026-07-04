# Next Steps — Web3Campaigns v0.3+

> Pick-up list. v0.3 escrow + Merkle settlement is merged to `dev` (PR #1). Phase 2 signature verification is in progress on `feature/phase2-signature-verification` (62 tests passing). Ordered roughly by priority.

## Hardening / open items (on the current model)

- [ ] **Allocation-fairness dispute window.** Escrow guarantees funds can't be rugged after a root is committed, but a malicious host can publish an unfair root (omit/short-change winners). Add a challenge/timelock window between `setERC20MerkleRoot`/`setNFTMerkleRoot` and when claims/sweeps finalize. (Both ERC20 + NFT roots.)
- [ ] **Fee-on-transfer ERC20 handling.** Escrow accounting assumes standard tokens; fee-on-transfer tokens under-fund escrow. Either measure received balance in `fundCampaignERC20` (balance-before/after) or whitelist tokens. Document the assumption either way.
- [ ] **Fuzz / invariant tests.** Add an escrow-solvency invariant (`sum(ERC20 claims) <= escrowed`) and an NFT inventory invariant (claimed leaves never exceed deposited inventory).
- [ ] **Multi-leaf NFT proof test.** Current NFT tests use single-leaf roots; add a 2+ leaf NFT tree test (ERC20 already has a two-leaf test).
- [ ] **`withdrawETH` treasury restriction (low).** Replace the arbitrary `_to` with a stored, admin-settable treasury to clear the `arbitrary-send-eth` flag.
- [ ] **Repo-wide `forge fmt`.** Repo does not pass `forge fmt --check` (pre-existing). Do a single formatting pass so CI's `forge fmt --check` goes green — as its own commit to keep diffs reviewable.
- [ ] **`grantHostRole` is intentionally open.** Revisit when adding the staked/curated hosting model (founder decision to leave open for now).
- [ ] **`.code.length` check** on `configureERC20Reward` / NFT deposits to reject EOA/empty token addresses early.
- [ ] **Contract size headroom.** `Web3Campaigns` runtime is 21.1KB / 24.576KB limit (3.4KB left) after Phase 2. Watch `forge build --sizes` before adding more logic; consider splitting a new logic contract into the diamond if a future feature won't fit.

## Phase 2 (in progress on `feature/phase2-signature-verification`)

- [x] **Signature-based off-chain task verification.** `SIGNER_ROLE` + EIP-712 `TaskAttestation` (`{campaignId, participant, taskIndex, completed, version, deadline}`) — `verifyTaskCompletionWithSignature`/`batchVerifyTaskCompletionWithSignatures` **replace** (not run alongside) the old host-tx `verifyTaskCompletion`/`batchVerifyTaskCompletion`. Signer rotation/revocation via plain `AccessControl` `grantRole`/`revokeRole(SIGNER_ROLE, ...)`. Replay guard = per-`(participant,campaign,task)` version counter, which doubles as an update/reverification mechanism (signer can flip `completed` back to false or re-affirm it by signing the next version). Single-signer for now (no N-of-M threshold). Trust-minimized, not trustless — documented in `docs/TASK_VERIFICATION.md`. 62 tests passing; not yet merged to `dev`.
- [ ] **Protocol fee.** Simple `feeBps` skimmed at `fundCampaignERC20` (and/or NFT deposit), routed to a treasury. Get it into the data model before integrators exist.
- [ ] **`cancelCampaign` + refund.** Let a host cancel in Draft (and maybe Open) and refund escrowed ERC20/NFTs — an "oops" path for misconfigured campaigns.

## Phase 3 (post-PMF)

- [ ] **Sybil gating** — World ID / Gitcoin Passport at claim for high-value campaigns (the `HUMANITY_VERIFICATION` task type is currently unenforced).
- [ ] **Gasless claims** — ERC-2771 / paymaster so users don't pay gas to claim small rewards.
- [ ] **`MAX_PARTICIPANTS_LIMIT` enforcement** and `JOIN_COOLDOWN` (declared constants currently unenforced).
- [ ] **Staked/open hosting tier** — `selfRegisterAsHost() payable` gated by a refundable stake / creation fee, slashable on abuse (the deliberate version of today's open `grantHostRole`).

## Process reminders (from CLAUDE.md)
Before each commit: `forge build` clean · `forge test` green · review the full diff. Toolchain: `export PATH="$HOME/.foundry/bin:$PATH"`. See [[TEST_AND_BUILD]], [[SECURITY_FINDINGS]], [[REWARD_SYSTEM]].
