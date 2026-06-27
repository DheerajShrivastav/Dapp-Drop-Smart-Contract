# Dapp-Drop Smart Contract — AI Context Docs

> Code-verified reference for the Web3Campaigns contract suite, written for AI agents (and humans) to consult before making code changes.
>
> **These docs reflect the `dev` branch and were derived by reading the actual Solidity, NOT the other markdown docs (README/CAMPAIGN_WORKFLOW/SECURITY_AUDIT_PLAN are stale).** Line numbers drift — re-verify against current code before acting.

## Index

- [ARCHITECTURE.md](ARCHITECTURE.md) — 5-contract composition, deployed entrypoint, roles, `Draft→Open→Ended→Closed` lifecycle.
- [REWARD_SYSTEM.md](REWARD_SYSTEM.md) — ERC20 / NFT / off-chain rewards, FIXED/TIERED/FCFS modes, host-pull vs escrow, claim ranking.
- [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) — code-verified issues, severity-ordered (unguarded `grantHostRole`, ERC20 host-pull, broken on-chain verify, silent zero-claims, dead state…).
- [BRANCHES.md](BRANCHES.md) — branch topology: `dev` = source of truth; `flexible-reward-system` obsolete; `single-tx-campaign-setup` has one unmerged feature to port.
- [TEST_AND_BUILD.md](TEST_AND_BUILD.md) — test coverage gaps, toolchain config, how to make the repo runnable.
