# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **Trust the Solidity, not the older root-level markdown** (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale). Line numbers drift — re-verify against current code before acting.

## Current state (2026-07-02)

`dev` has the full v0.3 escrow + Merkle settlement rewrite merged (PR #1, merge commit `fd28f27`). VERSION `0.3.0` on `dev`.

Active development on branch **`feature/phase2-signature-verification`** (forked from `dev`): Phase 2 replaces host-tx off-chain task verification with EIP-712 signed attestations. See [TASK_VERIFICATION.md](TASK_VERIFICATION.md).

**v0.3 recap (merged to `dev`):**
- **Stage A** — correctness/anti-abuse fixes (task verification, anti-abuse gate, pause coverage).
- **Stage B1** — **ERC20 escrow + post-campaign Merkle settlement** replaces the old host-pull live-distribution model.
- **Stage B2** — **multi-standard NFT (ERC721 + ERC1155) escrow + Merkle settlement**; legacy live NFT pool removed.
- **Stage B3** — deleted the now-dead live-reward scaffolding.

The contract is **escrow + verify + Merkle-settle**. There is no live mid-campaign claim path. Off-chain rewards remain informational only.

Toolchain: Foundry 1.7.1, OZ + forge-std submodules initialized. **62 tests passing** (5 suites) on the Phase 2 branch. Build clean, `forge fmt --check` clean. Contract size 21.1KB runtime (24.576KB limit — 3.4KB headroom, watch this on future features).

Decisions locked by the founder: **no upgradeability** (immutable, no proxy); **Merkle settlement after campaign end** is the reward claim model (not live mid-campaign); **`grantHostRole` stays open/unguarded** intentionally for now; **signature verification replaces** (not runs alongside) host-tx verification; **single `SIGNER_ROLE`** for now (no N-of-M threshold yet); replay guard = per-task version counter, which doubles as an update/reverification mechanism.

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed` lifecycle, claim flow.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — escrow + Merkle settlement for ERC20 and multi-standard NFT rewards.
- [TASK_VERIFICATION.md](TASK_VERIFICATION.md) — Phase 2: EIP-712 signed attestations for off-chain task completion, replay/update model, signer rotation.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — original findings with current FIXED / OPEN / INTENTIONAL status.
- [BRANCHES.md](BRANCHES.md) — branch topology, v0.3 hardening branch (merged), Phase 2 branch (active).
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — toolchain setup, test coverage, how to build/run.
- [NEXT_STEPS.md](NEXT_STEPS.md) — pick-up list: hardening items + Phase 2/3 roadmap.
