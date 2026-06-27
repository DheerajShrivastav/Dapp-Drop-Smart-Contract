# Reward System — Web3Campaigns

> As of `feature/v0.3-security-hardening`. ERC20 has moved to escrow + Merkle settlement (Stage B1). NFT is still the legacy live pool until Stage B2.

## Model: escrow + post-campaign Merkle settlement

The blockchain's job here is to **guarantee payment from escrow**; distribution *math* (fixed/tiered/FCFS/sybil-filtering) is computed **off-chain** after the campaign ends and committed as a Merkle root. This removes live-claim front-running, silent-zero claims, and the host-wallet rug/brick vector.

There is **no ETH reward path** — ETH only enters via `receive()` and is recoverable by admin via `withdrawETH`.

## ERC20 (DONE — Stage B1)

State (CampaignStorage.sol): `_erc20RewardToken`, `_erc20Escrowed`, `_erc20Distributed`, `_erc20MerkleRoot`, `_erc20SettlementClaimed`, `_campaignClosedAt`, `_erc20Swept`.

Host flow (CampaignManagement.sol):
1. `configureERC20Reward(id, token)` — Draft only; records the reward token, sets `rewardsConfigured`.
2. `fundCampaignERC20(id, amount)` — escrows tokens INTO the contract via `SafeERC20.safeTransferFrom(host -> contract)`. Allowed in Draft/Open/Ended (top-up). `_erc20Escrowed += amount`.
3. `endCampaign(id)` — at/after `endTime`.
4. `setERC20MerkleRoot(id, root)` — Ended only; commits off-chain allocations. Updatable while Ended, frozen at Closed.
5. `withdrawUnclaimedERC20(id)` — after Closed + `CLAIM_GRACE_PERIOD` (30 days); sweeps `escrowed - distributed` to host; single-sweep guarded by `_erc20Swept`.

Participant claim (ParticipantManagement.sol):
- `claimERC20(id, amount, proof)` — status Ended or Closed; requires root set; one claim per account (`_erc20SettlementClaimed`); leaf is the **OZ StandardMerkleTree** format `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`; verified with OZ `MerkleProof.verify`; escrow-accounted (`InsufficientEscrow` if `distributed + amount > escrowed`); pays via `safeTransfer` from escrow. `nonReentrant + whenNotPaused` (Web3Campaigns wrapper).
- Off-chain tooling must build the tree with `@openzeppelin/merkle-tree` using leaf encoding `["address","uint256"]` to match.

Views (CampaignViewFunctions.sol): `getERC20Settlement(id)` → (token, escrowed, distributed, merkleRoot, closedAt, swept); `hasClaimedERC20(id, account)`.

## NFT (LEGACY — replaced in Stage B2)

Still the old live escrowed-pool FCFS path: `setNFTReward` + `addNFTsToPool` (escrows ERC721 via raw `transferFrom`), claimed through `claimReward` → `_processNFTReward` (sequential from `tokenIds[distributedCount]`, up to `maxPerParticipant`). This retains the front-running/silent-zero behavior and is slated for replacement by multi-standard (ERC721 + ERC1155) Merkle settlement in B2. Do not build on this path.

## Off-chain reward

`setOffChainReward(id, description, metadata)` — no on-chain payout; informational, relies on the `RewardClaimed` event / host fulfillment.

## Removed in B1

The old ERC20 distribution-mode system is gone: `setERC20RewardFixed/FCFS/Tiered`, legacy `setCampaignReward`, `_processERC20Reward`, and `claimReward`'s ERC20 branch. The `DistributionMode`/`RewardTier`/tier/claim-rank structures still exist in storage but are now **dead** (scheduled for deletion in B3). Related: [[ARCHITECTURE]], [[SECURITY_FINDINGS]], [[TEST_AND_BUILD]].
