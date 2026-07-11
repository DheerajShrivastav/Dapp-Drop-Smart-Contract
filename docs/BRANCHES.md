# Branch Topology — Dapp-Drop

**Active work:** `feature/root-dispute-window-invariant` (off `dev` post-PR #8). Adds a stateful-fuzz invariant suite for the Merkle root dispute window (`ROOT_DISPUTE_WINDOW`), covering both the ERC20 and NFT paths via a ghost mirror of the rearm rule. 123 tests passing; not yet merged.

Merged to `dev`: `feature/v0.3-security-hardening` (Stage A + B1–B3) as PR #1 (`fd28f27`); `feature/phase2-signature-verification` (EIP-712 signed attestations, raised via the `no-mistakes` pipeline) as PR #2; `feature/invariant-tests` (stateful-fuzz suites, incl. a real HIGH-severity cross-campaign ERC20 drain fix — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3, also raised via `no-mistakes`) as PR #3; `feature/cancel-campaign` (host abort + zero-participants gate) as PR #4; `fix/per-campaign-module-pinning` (on-chain tiered settlement RANK_TIERED/SCORE_TIERED via the separately-deployed `OnChainRewardModule`, ERC20 token/mode decoupling, and per-campaign module pinning — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)) as PR #6; `feature/onchain-reward-invariant` (stateful-fuzz suite for the tiered path + pinning, incl. mid-run global-module rotation) as PR #7; `feature/merkle-root-dispute-window` (`ROOT_DISPUTE_WINDOW`, plus a same-root-republish self-griefing fix from manual review — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14) as PR #8. `dev` is now VERSION 0.5.0.

---

Four original branches, two independent dev lines from common ancestor `563f9f5` (master baseline / "security audit plan").

- **`dev` = SOURCE OF TRUTH.** VERSION 0.5.0, Solidity 0.8.31. Escrow + Merkle settlement rewrite (PR #1), signed task verification (PR #2), invariant-hardening + security fix (PR #3), and `cancelCampaign` (PR #4) all merged. Use this branch as the base for all new work.
- **`origin/master`** — old baseline. Single flat `CampaignReward`. `dev` is a strict superset.
- **`origin/feature/flexible-reward-system`** — OBSOLETE / fully merged into `dev`. Safe to delete.
- **`origin/feature/single-tx-campaign-setup`** — UNMERGED, genuinely divergent (5 unique commits, never received the flexible reward system). Holds **one** unique feature not on `dev`:
  ```solidity
  createCampaignWithTasksAndReward(
      name, start, end,
      taskTypes[], descriptions[], verificationData[], isOptional[],
      rewardType, tokenAddress, amountOrTokenId
  )
  ```
  — fuses create + tasks + reward config into **one transaction**. BUT it's built on the legacy flat reward model (`RewardType` / `setCampaignReward`, single `amountOrTokenId`) and regresses VERSION 0.2.0→0.0.4 and pragma 0.8.31→0.8.20.
  - **Recommendation:** do NOT merge wholesale. Forward-**port** just the single-tx idea onto `dev`, re-signing it to accept `dev`'s `CampaignRewardConfig`-based reward params. Cannot fast-forward.

Inspect other branches without checkout: `git show <branch>:<file>`, `git diff dev <branch> -- src`.

See also [ARCHITECTURE.md](ARCHITECTURE.md).
