# Branch Topology — Dapp-Drop

**Active work:** `feature/invariant-tests` (forked from `dev` post-Phase-2 merge) holds stateful-fuzz invariant test suites for escrow/settlement/attestation. Found and fixed a real HIGH-severity bug already live on `dev` (cross-campaign ERC20 drain via `claimERC20` — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3). 75 tests passing; not yet merged to `dev` — **prioritize this fix for review/merge.**

Merged to `dev`: `feature/v0.3-security-hardening` (Stage A + B1–B3) as PR #1 (`fd28f27`); `feature/phase2-signature-verification` (EIP-712 signed attestations, raised via the `no-mistakes` pipeline) as PR #2. `dev` is now VERSION 0.4.0.

---

Four original branches, two independent dev lines from common ancestor `563f9f5` (master baseline / "security audit plan").

- **`dev` = SOURCE OF TRUTH.** VERSION 0.4.0, Solidity 0.8.31. Full escrow + Merkle settlement rewrite (PR #1) + signed task verification (PR #2) merged. Use this branch as the base for all new work.
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
