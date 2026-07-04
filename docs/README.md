# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **Trust the Solidity, not the older root-level markdown** (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale). Line numbers drift — re-verify against current code before acting.

## Current state (2026-07-04)

`dev` has both the v0.3 escrow + Merkle settlement rewrite (PR #1, `fd28f27`) and Phase 2 signature verification (PR #2) merged. VERSION `0.4.0` on `dev`.

Active development on branch **`feature/invariant-tests`** (forked from `dev`): stateful-fuzz invariant test suites for the escrow/settlement/attestation lifecycle. **Found and fixed a real HIGH-severity bug already live on `dev`** — a cross-campaign ERC20 escrow drain via `claimERC20` — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3. **This fix should be prioritized for review/merge.**

**Recap (merged to `dev`):**
- **v0.3 (Stage A/B1/B2/B3)** — correctness fixes, then the reward system fully rebuilt as escrow + Merkle settlement for ERC20 and multi-standard NFT (ERC721 + ERC1155).
- **Phase 2** — off-chain task verification rebuilt as EIP-712 `SIGNER_ROLE`-signed attestations, replacing host-tx `verifyTaskCompletion`. Raised via the `no-mistakes` automated pipeline, which caught its own real bug (`TaskManagedBySignature`) during review.

The contract is **escrow + verify + Merkle-settle**. There is no live mid-campaign claim path. Off-chain rewards remain informational only.

Toolchain: Foundry 1.7.1, OZ + forge-std submodules initialized. **75 tests passing** (8 suites, including 3 stateful-fuzz invariant suites) on `feature/invariant-tests`. Build clean, `forge fmt --check` clean. Contract size 21.2KB runtime (24.576KB limit — ~3.3KB headroom, watch this on future features; invariant/handler test files don't count against this).

Decisions locked by the founder: **no upgradeability** (immutable, no proxy); **Merkle settlement after campaign end** is the reward claim model (not live mid-campaign); **`grantHostRole` stays open/unguarded** intentionally for now; **signature verification replaces** (not runs alongside) host-tx verification; **single `SIGNER_ROLE`** for now (no N-of-M threshold yet); replay guard = per-task version counter, which doubles as an update/reverification mechanism.

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed` lifecycle, claim flow.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — escrow + Merkle settlement for ERC20 and multi-standard NFT rewards.
- [TASK_VERIFICATION.md](TASK_VERIFICATION.md) — Phase 2: EIP-712 signed attestations for off-chain task completion, replay/update model, signer rotation.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — original findings with current FIXED / OPEN / INTENTIONAL status, plus the invariant-found cross-campaign drain bug.
- [BRANCHES.md](BRANCHES.md) — branch topology, merged branches, active invariant-tests branch.
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — toolchain setup, test coverage (unit + invariant suites), how to build/run.
- [NEXT_STEPS.md](NEXT_STEPS.md) — pick-up list: hardening items + Phase 2/3 roadmap.
