# Branch Topology — Dapp-Drop

Four branches, two independent dev lines from common ancestor `563f9f5` (master baseline / "security audit plan").

- **`dev` = SOURCE OF TRUTH.** Most advanced: VERSION 0.2.0, Solidity 0.8.31, full flexible reward system + batch ops (`batchAddTasks`, `batchVerifyTaskCompletion`) + admin `withdrawETH`. Strict superset of `feature/flexible-reward-system`. Use this branch for all work.
- **`origin/master`** — old baseline. Single flat `CampaignReward`. `dev` adds +841 lines of multi-asset/multi-mode rewards on top (see [REWARD_SYSTEM.md](REWARD_SYSTEM.md)).
- **`origin/feature/flexible-reward-system`** — OBSOLETE / fully merged. It is `dev`'s direct parent (tip `2fa8ea3`); `dev` = this branch + 1 refinement commit (`1e74190`). Zero commits `dev` lacks. Safe to delete.
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
