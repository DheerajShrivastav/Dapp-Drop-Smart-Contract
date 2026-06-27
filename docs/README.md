# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **Trust the Solidity, not the older root-level markdown** (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale). Line numbers drift — re-verify against current code before acting.

## Current state (2026-06-27)

Active development on branch **`feature/v0.3-security-hardening`** (forked from `dev`). VERSION `0.3.0`. Two milestones landed:

- **Stage A** (commit `85cf83d`) — correctness/anti-abuse fixes (task verification, anti-abuse gate, pause coverage).
- **Stage B1** (commit `24f472a`) — **ERC20 escrow + post-campaign Merkle settlement** replaces the old host-pull live-distribution model.

Still **in progress**: Stage B2 (multi-standard NFT escrow + Merkle settlement) and B3 (delete the now-dead live-reward structs). Until B2 lands, the **legacy live NFT pool path is still present** (`setNFTReward`/`addNFTsToPool`/`claimReward` NFT branch).

Toolchain: Foundry 1.7.1, OZ + forge-std submodules initialized. **35 tests passing.** Build clean. (Repo does not yet pass `forge fmt --check` — pre-existing; new code matches local style.)

Decisions locked by the founder: **no upgradeability** (immutable, no proxy); **Merkle settlement after campaign end** is the claim model (not live mid-campaign); **`grantHostRole` stays open/unguarded** intentionally for now.

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed` lifecycle, claim flow.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — escrow + Merkle settlement (ERC20 done; NFT pending B2), funding, claiming, unclaimed sweep.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — original findings with current FIXED / OPEN / INTENTIONAL status.
- [BRANCHES.md](BRANCHES.md) — branch topology and the v0.3 hardening branch.
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — toolchain setup, test coverage, how to build/run.
