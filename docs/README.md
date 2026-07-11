# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **Trust the Solidity, not the older root-level markdown** (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale). Line numbers drift — re-verify against current code before acting.

## Current state (2026-07-11)

`dev` has v0.3 escrow + Merkle settlement (PR #1), Phase 2 signature verification (PR #2), the invariant-test hardening pass including a real security fix (PR #3), `cancelCampaign` (PR #4), on-chain tiered settlement + per-campaign module pinning (PR #6), its invariant suite (PR #7), the Merkle root dispute window (PR #8), and that window's own invariant suite (PR #9) all merged. VERSION `0.5.0` on `dev`.

Active development on branch **`feature/protocol-fee-module`**: a `FeeModule` satellite contract, mirroring `OnChainRewardModule`, skimming a flat fee at `fundCampaignERC20` — see [ARCHITECTURE.md](ARCHITECTURE.md).

**Recap (merged to `dev`):**
- **v0.3 (Stage A/B1/B2/B3)** — correctness fixes, then the reward system fully rebuilt as escrow + Merkle settlement for ERC20 and multi-standard NFT (ERC721 + ERC1155).
- **Phase 2** — off-chain task verification rebuilt as EIP-712 `SIGNER_ROLE`-signed attestations, replacing host-tx `verifyTaskCompletion`. Raised via the `no-mistakes` automated pipeline, which caught its own real bug (`TaskManagedBySignature`) during review.
- **Invariant hardening** — stateful-fuzz suites for escrow/settlement/attestation. **Found and fixed a real HIGH-severity bug that had been live on `dev`**: a cross-campaign ERC20 escrow drain via `claimERC20` (see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3). Also raised via `no-mistakes`, which caught a methodological flaw in the fuzz-test design itself and a flaky coverage-guard.
- **On-chain tiered settlement + per-campaign module pinning** — RANK_TIERED/SCORE_TIERED via the separately-deployed `OnChainRewardModule`, with payout authority bound to a per-campaign pin rather than the rotatable global default (closes a mid-campaign rotation hazard). Its own stateful-fuzz invariant suite followed as a separate PR.
- **Merkle root dispute window** — `ROOT_DISPUTE_WINDOW` (24h) delays claims against a freshly-(re-)published root, giving the community time to catch an unfair allocation before funds move (see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14). A manual PR review caught and fixed a self-griefing gap (same-root republish indefinitely stalling claims) before merge.
- **Root dispute window invariant coverage** — a 5th stateful-fuzz suite, covering both the ERC20 and NFT dispute-window paths via a ghost mirror of the rearm rule. Caught a real bug in the test handler itself (a missing `vm.prank`) during development.

The contract is **escrow + verify + Merkle-settle**, plus an on-chain-computed dispute-free alternative for ERC20 tiered rewards. There is no live mid-campaign Merkle claim path. Off-chain rewards remain informational only.

Toolchain: Foundry 1.7.1, OZ + forge-std submodules initialized. **145 tests passing** (13 suites, including 5 stateful-fuzz invariant suites) on `feature/protocol-fee-module`. Build clean, `forge fmt --check` clean. Contract size 23,829B runtime (24,576B limit — **~747B headroom, critical**; the fee module itself proved the satellite-contract pattern is now mandatory for any feature with real logic, but even minimal wiring still costs several hundred bytes — 1-2 more integrations this size and the entrypoint is out of room).

Decisions locked by the founder: **no upgradeability** (immutable, no proxy); **Merkle settlement after campaign end** is the reward claim model (not live mid-campaign); **`grantHostRole` stays open/unguarded** intentionally for now; **signature verification replaces** (not runs alongside) host-tx verification; **single `SIGNER_ROLE`** for now (no N-of-M threshold yet); replay guard = per-task version counter, which doubles as an update/reverification mechanism; **`cancelCampaign` requires zero participants** (no partial-cancel-after-engagement escape hatch).

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed(→Cancelled)` lifecycle, claim flow.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — escrow + Merkle settlement for ERC20 and multi-standard NFT rewards, plus cancellation refund.
- [TASK_VERIFICATION.md](TASK_VERIFICATION.md) — Phase 2: EIP-712 signed attestations for off-chain task completion, replay/update model, signer rotation.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — original findings with current FIXED / OPEN / INTENTIONAL status, plus the invariant-found cross-campaign drain bug.
- [BRANCHES.md](BRANCHES.md) — branch topology, merged branches, active protocol-fee-module branch.
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — toolchain setup, test coverage (unit + invariant suites), how to build/run.
- [NEXT_STEPS.md](NEXT_STEPS.md) — pick-up list: hardening items + Phase 2/3 roadmap.
