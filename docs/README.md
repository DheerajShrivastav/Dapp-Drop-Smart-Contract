# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **Trust the Solidity, not the older root-level markdown** (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale). Line numbers drift — re-verify against current code before acting.

## Current state (2026-07-12)

`dev` has v0.3 escrow + Merkle settlement (PR #1), Phase 2 signature verification (PR #2), the invariant-test hardening pass including a real security fix (PR #3), `cancelCampaign` (PR #4), on-chain tiered settlement + per-campaign module pinning (PR #6), its invariant suite (PR #7), the Merkle root dispute window (PR #8), that window's own invariant suite (PR #9), the protocol fee module (PR #10), and the NFT settlement module extraction (PR #11) all merged. VERSION `0.5.0` on `dev`.

Active development on branch **`feature/fee-on-transfer-erc20`**: `fundCampaignERC20` now measures the amount actually received via `balanceOf` before/after the pull, instead of trusting the caller-supplied `amount`, so a fee-on-transfer ERC20 can no longer over-credit escrow beyond what the contract actually custodies — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).

**Recap (merged to `dev`):**
- **v0.3 (Stage A/B1/B2/B3)** — correctness fixes, then the reward system fully rebuilt as escrow + Merkle settlement for ERC20 and multi-standard NFT (ERC721 + ERC1155).
- **Phase 2** — off-chain task verification rebuilt as EIP-712 `SIGNER_ROLE`-signed attestations, replacing host-tx `verifyTaskCompletion`. Raised via the `no-mistakes` automated pipeline, which caught its own real bug (`TaskManagedBySignature`) during review.
- **Invariant hardening** — stateful-fuzz suites for escrow/settlement/attestation. **Found and fixed a real HIGH-severity bug that had been live on `dev`**: a cross-campaign ERC20 escrow drain via `claimERC20` (see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3). Also raised via `no-mistakes`, which caught a methodological flaw in the fuzz-test design itself and a flaky coverage-guard.
- **On-chain tiered settlement + per-campaign module pinning** — RANK_TIERED/SCORE_TIERED via the separately-deployed `OnChainRewardModule`, with payout authority bound to a per-campaign pin rather than the rotatable global default (closes a mid-campaign rotation hazard). Its own stateful-fuzz invariant suite followed as a separate PR.
- **Merkle root dispute window** — `ROOT_DISPUTE_WINDOW` (24h) delays claims against a freshly-(re-)published root, giving the community time to catch an unfair allocation before funds move (see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14). A manual PR review caught and fixed a self-griefing gap (same-root republish indefinitely stalling claims) before merge.
- **Root dispute window invariant coverage** — a 5th stateful-fuzz suite, covering both the ERC20 and NFT dispute-window paths via a ghost mirror of the rearm rule. Caught a real bug in the test handler itself (a missing `vm.prank`) during development.
- **Protocol fee module** — `FeeModule` satellite contract skims a flat `feeBps` at `fundCampaignERC20`, routed to a treasury; no per-campaign pinning needed since fee computation has no persistent per-campaign state to desync across a rotation.
- **NFT settlement module extraction** — all NFT Merkle-settlement logic + escrow bookkeeping moved into a new `NFTSettlementModule` satellite contract to reclaim entrypoint headroom; `Web3Campaigns` retains all NFT custody. Unlike the fee/reward modules, the NFT module needs per-campaign pinning (persistent escrow state) — pinned at **first deposit**, earlier than the reward module's pin-at-mode-adoption, since escrow bookkeeping can precede any root ever being published. PR review caught two real gaps before merge: a missing `is INFTSettlementModule` declaration (Aderyn's Missing Inheritance finding) and untested pause coverage (the module's claim/sweep functions lost their direct `whenNotPaused` wrapper) — both fixed, both now tested. See [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- **Fee-on-transfer ERC20 support (in progress)** — `fundCampaignERC20` now credits escrow with the amount actually received (`balanceOf` before/after the pull), not the nominal `amount` requested, closing a previously-documented gap where a fee-on-transfer token would silently under-fund escrow relative to what the contract believed it held. Protocol fee (if registered) is likewise computed on the received amount. Standard tokens: byte-for-byte unchanged behavior.

The contract is **escrow + verify + Merkle-settle**, plus an on-chain-computed dispute-free alternative for ERC20 tiered rewards. There is no live mid-campaign Merkle claim path. Off-chain rewards remain informational only.

Toolchain: Foundry 1.7.1, OZ + forge-std submodules initialized. **153 tests passing** (14 suites, including 5 stateful-fuzz invariant suites) on `feature/fee-on-transfer-erc20`. Build clean, `forge fmt --check` clean. Contract size 23,258B runtime (24,576B limit — **~1,318B headroom**, down from ~1,540B before this pass's balance-diff logic + new error).

Decisions locked by the founder: **no upgradeability** (immutable, no proxy); **Merkle settlement after campaign end** is the reward claim model (not live mid-campaign); **`grantHostRole` stays open/unguarded** intentionally for now; **signature verification replaces** (not runs alongside) host-tx verification; **single `SIGNER_ROLE`** for now (no N-of-M threshold yet); replay guard = per-task version counter, which doubles as an update/reverification mechanism; **`cancelCampaign` requires zero participants** (no partial-cancel-after-engagement escape hatch).

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed(→Cancelled)` lifecycle, claim flow.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — escrow + Merkle settlement for ERC20 and multi-standard NFT rewards, plus cancellation refund.
- [TASK_VERIFICATION.md](TASK_VERIFICATION.md) — Phase 2: EIP-712 signed attestations for off-chain task completion, replay/update model, signer rotation.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — original findings with current FIXED / OPEN / INTENTIONAL status, plus the invariant-found cross-campaign drain bug.
- [BRANCHES.md](BRANCHES.md) — branch topology, merged branches, active fee-on-transfer-erc20 branch.
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — toolchain setup, test coverage (unit + invariant suites), how to build/run.
- [NEXT_STEPS.md](NEXT_STEPS.md) — pick-up list: hardening items + Phase 2/3 roadmap.
