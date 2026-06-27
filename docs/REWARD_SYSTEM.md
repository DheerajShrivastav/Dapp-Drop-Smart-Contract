# Reward System — Web3Campaigns

Reward config (on `dev`) is three **independent** sub-rewards that can all be active on one campaign, stored in `CampaignRewardConfig` (CampaignStorage.sol). There is **no ETH reward path** — ETH only enters via `receive()` and is recoverable by admin via `withdrawETH`.

## ERC20

`ERC20Reward { enabled, tokenAddress, distributionMode, fixedAmount, totalPool, distributedAmount }`. Three modes via `DistributionMode { FIXED, TIERED, FCFS }`:

- **FIXED**: every claimant gets `fixedAmount`.
- **TIERED**: amount by `claimRank` matched against `_rewardTiers[campaignId]` (`RewardTier { startRank, endRank, amount }`); no match → 0.
- **FCFS**: `fixedAmount` only if `distributedAmount + fixedAmount <= totalPool`, else 0 (no revert).

> **IMPORTANT:** ERC20 is paid via `IERC20(token).safeTransferFrom(campaign.host, msg.sender, amount)` — pulled **directly from the host's live wallet at claim time, NOT from contract escrow**. Host must maintain a standing allowance to the contract. (ParticipantManagement.sol ~L343)

## NFT (ERC721) — bulk pool, FCFS only

Host pre-funds via `addNFTsToPool` (NFTs escrowed **into** the contract via raw `transferFrom`). On claim, up to `maxPerParticipant` NFTs are sent from the contract via `nft.transferFrom(address(this), msg.sender, tokenId)`, sequentially from `tokenIds[distributedCount]`. Pool exhausted → 0 NFTs, no revert. Contract does **not** implement `onERC721Received` (fine for raw `transferFrom`; would break on `safeTransferFrom` minting).

## Off-chain

`OffChainReward { description, metadata }` — no on-chain payout; relies on the `RewardClaimed` event / host fulfillment.

## Claim ranking

Rank = order of `claimReward` txs (incrementing `campaign.claimCount`). TIERED/FCFS give the best rewards to the earliest claimers → front-runnable / MEV race (no commit-reveal). See [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).

## Reward setters (CampaignManagement, require Draft status)

`setERC20RewardFixed`, `setERC20RewardFCFS`, `setERC20RewardTiered`, `setNFTReward`, `addNFTsToPool` (Draft **or** Open), `setOffChainReward`. Legacy `setCampaignReward` kept as a thin wrapper. The `RewardType` enum and old `CampaignReward` struct are legacy / event-only.

Payout internals: `_processERC20Reward`, `_processNFTReward`, `_verifyAllTasksCompleted` (all in ParticipantManagement.sol). See also [ARCHITECTURE.md](ARCHITECTURE.md), [TEST_AND_BUILD.md](TEST_AND_BUILD.md).
