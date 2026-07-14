# Branch Topology — Dapp-Drop

**Active work:** `feature/sponsored-claims` (off `dev` post-PR #14). Gasless UX via permissionless sponsored-claim entrypoints — `claimERC20For` (Web3Campaigns), `claimNFTFor` (NFTSettlementModule), `claimRewardFor` (OnChainRewardModule) — each sharing its full body with the self-claim path; rewards always go to the allocated account, never the caller, so the project backend can pay gas for users with no meta-transaction framework — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md). 183 tests passing; not yet merged.

Merged to `dev`: `feature/v0.3-security-hardening` (Stage A + B1–B3) as PR #1 (`fd28f27`); `feature/phase2-signature-verification` (EIP-712 signed attestations, raised via the `no-mistakes` pipeline) as PR #2; `feature/invariant-tests` (stateful-fuzz suites, incl. a real HIGH-severity cross-campaign ERC20 drain fix — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3, also raised via `no-mistakes`) as PR #3; `feature/cancel-campaign` (host abort + zero-participants gate) as PR #4; `fix/per-campaign-module-pinning` (on-chain tiered settlement RANK_TIERED/SCORE_TIERED via the separately-deployed `OnChainRewardModule`, ERC20 token/mode decoupling, and per-campaign module pinning — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)) as PR #6; `feature/onchain-reward-invariant` (stateful-fuzz suite for the tiered path + pinning, incl. mid-run global-module rotation) as PR #7; `feature/merkle-root-dispute-window` (`ROOT_DISPUTE_WINDOW`, plus a same-root-republish self-griefing fix from manual review — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14) as PR #8; `feature/root-dispute-window-invariant` (stateful-fuzz invariant suite for `ROOT_DISPUTE_WINDOW`, covering both ERC20 and NFT paths via a ghost mirror of the rearm rule) as PR #9; `feature/protocol-fee-module` (`FeeModule` satellite contract skimming a flat fee at `fundCampaignERC20`, no per-campaign pinning needed) as PR #10; `feature/nft-settlement-module` (`NFTSettlementModule` satellite contract extracting all NFT Merkle-settlement logic + escrow bookkeeping, pinned per-campaign at first deposit; PR review caught and fixed a missing `is INFTSettlementModule` declaration and untested pause coverage before merge) as PR #11; `feature/fee-on-transfer-erc20` (`fundCampaignERC20` credits escrow with the amount actually received via `balanceOf` before/after, not the nominal amount, closing a documented fee-on-transfer gap) as PR #12; `feature/fee-on-transfer-invariant` (a 6th stateful-fuzz suite fuzzing escrow solvency against a fee-on-transfer token, a non-blocking follow-up from PR #12's review; a review-flagged negative-control misattribution in its writeup was corrected before merge) as PR #13; `feature/hardening-sweep` (treasury-gated `withdrawETH` closing the `arbitrary-send-eth` finding, `.code.length` reward-token guards, multi-leaf NFT proof tests) as PR #14. `dev` is now VERSION 0.5.0.

---

Four original branches, two independent dev lines from common ancestor `563f9f5` (master baseline / "security audit plan").

- **`dev` = SOURCE OF TRUTH.** VERSION 0.5.0, Solidity 0.8.31. Escrow + Merkle settlement rewrite (PR #1), signed task verification (PR #2), invariant-hardening + security fix (PR #3), `cancelCampaign` (PR #4), on-chain tiered settlement + per-campaign module pinning (PR #6) with its invariant suite (PR #7), the Merkle root dispute window (PR #8) with its own invariant suite (PR #9), the protocol fee module (PR #10), the NFT settlement module extraction (PR #11), fee-on-transfer ERC20 support (PR #12), its invariant coverage (PR #13), and the hardening sweep (PR #14) all merged. Use this branch as the base for all new work.
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
