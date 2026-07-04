# Reward System — Web3Campaigns

> As of `feature/invariant-tests` (forked from `dev` post-Phase-2 merge). Both ERC20 (B1) and NFT (B2) use escrow + post-campaign Merkle settlement. The legacy live-distribution system was deleted in B3. **Security note**: `claimERC20` now rejects claims on swept campaigns (`AlreadySwept`) — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3.

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
- `claimERC20(id, amount, proof)` — status Ended or Closed; **reverts `AlreadySwept` if the campaign's unclaimed escrow has already been swept back to the host** (prevents a late claim from draining another campaign's commingled ERC20 escrow — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3); requires root set; one claim per account (`_erc20SettlementClaimed`); leaf is the **OZ StandardMerkleTree** format `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`; verified with OZ `MerkleProof.verify`; escrow-accounted (`InsufficientEscrow` if `distributed + amount > escrowed`); pays via `safeTransfer` from escrow. `nonReentrant + whenNotPaused` (Web3Campaigns wrapper).
- Off-chain tooling must build the tree with `@openzeppelin/merkle-tree` using leaf encoding `["address","uint256"]` to match.

Views (CampaignViewFunctions.sol): `getERC20Settlement(id)` → (token, escrowed, distributed, merkleRoot, closedAt, swept); `hasClaimedERC20(id, account)`.

## NFT — multi-standard (ERC721 + ERC1155), Merkle settlement (Stage B2)

State (CampaignStorage.sol): `_nftMerkleRoot`, `_nftLeafClaimed`, and the per-campaign escrow ownership maps `_escrowedERC721` (id→token→tokenId→held) / `_escrowedERC1155` (id→token→tokenId→amount). Web3Campaigns inherits OZ `ERC721Holder` + `ERC1155Holder` for safe custody.

Host flow (CampaignManagement.sol):
1. `depositERC721Rewards(id, token, tokenIds[])` / `depositERC1155Rewards(id, token, ids[], amounts[])` — escrow NFTs per campaign (Draft/Open/Ended), max 100/call. The ownership maps prevent one campaign's settlement from spending another's escrow.
2. `setNFTMerkleRoot(id, root)` — Ended only; commits off-chain allocations. Updatable while Ended.
3. `withdrawUnclaimedERC721(id, token, tokenIds[])` / `withdrawUnclaimedERC1155(id, token, ids[], amounts[])` — reclaim still-escrowed NFTs after Closed + grace.

Participant claim (ParticipantManagement.sol):
- `claimNFT(id, standard, token, tokenId, amount, proof)` — status Ended/Closed; leaf `keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount))))`; per-leaf claim guard (`_nftLeafClaimed`); decrements per-campaign escrow (reverts `NFTNotEscrowed` if not held); ERC721 via `safeTransferFrom`, ERC1155 via `safeTransferFrom(...,amount,"")`. `nonReentrant + whenNotPaused`.
- Off-chain tooling builds the tree with leaf encoding `["address","uint8","address","uint256","uint256"]`.

Views: `getNFTMerkleRoot`, `isNFTLeafClaimed`, `isERC721Escrowed`, `getERC1155Escrowed`.

## Off-chain reward

`setOffChainReward(id, description, metadata)` — no on-chain payout; informational (stored in the standalone `_offChainReward` mapping). View: `getOffChainReward(id)`.

## Removed (B1–B3)

The entire live-distribution system is gone: ERC20 setters (`setERC20RewardFixed/FCFS/Tiered`, legacy `setCampaignReward`), NFT pool (`setNFTReward`/`addNFTsToPool`), `claimReward`, the `_processERC20Reward`/`_processNFTReward`/`_verifyAllTasksCompleted` internals, the `DistributionMode`/`RewardType` enums, the `RewardTier`/`NFTPool`/`ERC20Reward`/`NFTReward`/`CampaignRewardConfig` structs, claim-rank state (`_claimOrder`/`_rewardTiers`/`claimCount`), and 23 unused errors. Related: [[ARCHITECTURE]], [[SECURITY_FINDINGS]], [[TEST_AND_BUILD]].
