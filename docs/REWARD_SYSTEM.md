# Reward System — Web3Campaigns

> As of `fix/per-campaign-module-pinning`. Both ERC20 (B1) and NFT (B2) use escrow + post-campaign Merkle settlement; `RANK_TIERED`/`SCORE_TIERED` add an on-chain alternative (see below). The legacy live-distribution system was deleted in B3. **Security note**: `claimERC20` now rejects claims on swept campaigns (`AlreadySwept`) — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3.

## Model: escrow + post-campaign Merkle settlement

The blockchain's job here is to **guarantee payment from escrow**; distribution *math* (fixed/tiered/FCFS/sybil-filtering) is computed **off-chain** after the campaign ends and committed as a Merkle root. This removes live-claim front-running, silent-zero claims, and the host-wallet rug/brick vector.

There is **no ETH reward path** — ETH only enters via `receive()` and is recoverable by admin via `withdrawETH`.

## ERC20 (DONE — Stage B1)

State (CampaignStorage.sol): `_erc20RewardToken`, `_erc20Escrowed`, `_erc20Distributed`, `_erc20MerkleRoot`, `_erc20SettlementClaimed`, `_campaignClosedAt`, `_erc20Swept`.

Host flow (CampaignManagement.sol):
1. `configureERC20Reward(id, token)` — Draft only; records the reward token. **Does not commit a settlement mode** — token configuration is common to all three ERC20 paths, so MERKLE is committed later by `setERC20MerkleRoot`, and the tiered modes by the module (see "On-chain tiered settlement" below).
2. `fundCampaignERC20(id, amount)` — escrows tokens INTO the contract via `SafeERC20.safeTransferFrom(host -> contract)`. Allowed in Draft/Open/Ended (top-up). `_erc20Escrowed += amount`.
3. `endCampaign(id)` — at/after `endTime`.
4. `setERC20MerkleRoot(id, root)` — Ended only; commits off-chain allocations **and commits the campaign to MERKLE settlement** (the mutual-exclusion lock — reverts `SettlementModeAlreadySet` if the campaign already adopted a tiered mode). Updatable while Ended, frozen at Closed.
5. `withdrawUnclaimedERC20(id)` — after Closed + `CLAIM_GRACE_PERIOD` (30 days); sweeps `escrowed - distributed` to host; single-sweep guarded by `_erc20Swept`.

Participant claim (ParticipantManagement.sol):
- `claimERC20(id, amount, proof)` — status Ended or Closed; **reverts `AlreadySwept` if the campaign's unclaimed escrow has already been swept back to the host** (prevents a late claim from draining another campaign's commingled ERC20 escrow — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3); requires root set; one claim per account (`_erc20SettlementClaimed`); leaf is the **OZ StandardMerkleTree** format `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`; verified with OZ `MerkleProof.verify`; escrow-accounted (`InsufficientEscrow` if `distributed + amount > escrowed`); pays via `safeTransfer` from escrow. `nonReentrant + whenNotPaused` (Web3Campaigns wrapper).
- Off-chain tooling must build the tree with `@openzeppelin/merkle-tree` using leaf encoding `["address","uint256"]` to match.

Views (CampaignViewFunctions.sol): `getERC20Settlement(id)` → (token, escrowed, distributed, merkleRoot, closedAt, swept); `hasClaimedERC20(id, account)`.

## ERC20 on-chain tiered settlement (RANK_TIERED / SCORE_TIERED) — dispute-free alternative

Payout amounts are computed purely from on-chain completion state — no host-published root to dispute — in the separately-deployed `OnChainRewardModule` (its own EIP-170 budget). `Web3Campaigns` keeps all custody; the module only decides who gets paid how much and calls back into the trusted `payOnChainReward`.

Flow: `configureERC20Reward` (token only, no mode lock) → host calls `module.setRankTiers`/`setScoreTiers` (Draft), which commits the mode via the `setSettlementMode` callback and **pins the module to the campaign** (once, idempotent) → run campaign (the module is notified of each qualifying completion for rank/score bookkeeping) → `endCampaign` → participants call `module.claimReward(id)`, paid from escrow via `payOnChainReward`.

- **`claimReward` self-check**: before evaluating any rank/score/tier logic, the module calls `getCampaignRewardModule(id)` and reverts `OnChainRewardModule__NotAuthoritativeModule` if it isn't `address(this)` — so a module acting on stale local state for a campaign it's no longer authoritative for can't even begin computing a payout. Defense-in-depth; see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- **Authorization**: `payOnChainReward` accepts only the per-campaign pinned module (`RewardModuleMismatch` otherwise), independent of the rotatable global default — see [ARCHITECTURE.md](ARCHITECTURE.md).
- **Mutual exclusivity**: a campaign commits to exactly one of MERKLE / RANK_TIERED / SCORE_TIERED; the first commit wins and any cross-mode second commit reverts `SettlementModeAlreadySet`.

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

## Cancellation refund (`cancelCampaign`)

`cancelCampaign(id)` (CampaignManagement.sol) — host-only, requires status Draft or Open **and** `campaign.totalParticipants == 0`; transitions to the terminal `Cancelled` status. Deliberately restrictive: once one participant has genuinely engaged, cancellation is permanently blocked (`CampaignHasParticipants`), closing a bait-and-switch path where a host could let participants do free work and cancel right before `Ended` to dodge paying out.

- **ERC20**: refunded immediately in the same call via the internal `_refundERC20IfAny` — no grace period, since no Merkle root could ever have been published pre-Ended (claims require `Ended`/`Closed`), so no claim was ever possible. Silently no-ops if no ERC20 reward was configured/escrowed (unlike the explicit `withdrawUnclaimedERC20`, which reverts on nothing-to-sweep).
- **NFT**: not auto-refunded (no on-chain enumerable per-campaign inventory list to iterate) — instead, `withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` become **immediately callable** (no grace wait) once status is `Cancelled` (see `_requireSweepable`'s early-return for that status). Host calls them with the specific tokenIds/ids they know they deposited.
- Emits `CampaignCancelled(id, host, refundedERC20)` plus the usual `CampaignStatusUpdated`.

## Off-chain reward

`setOffChainReward(id, description, metadata)` — no on-chain payout; informational (stored in the standalone `_offChainReward` mapping). View: `getOffChainReward(id)`.

## Removed (B1–B3)

The entire live-distribution system is gone: ERC20 setters (`setERC20RewardFixed/FCFS/Tiered`, legacy `setCampaignReward`), NFT pool (`setNFTReward`/`addNFTsToPool`), `claimReward`, the `_processERC20Reward`/`_processNFTReward`/`_verifyAllTasksCompleted` internals, the `DistributionMode`/`RewardType` enums, the `RewardTier`/`NFTPool`/`ERC20Reward`/`NFTReward`/`CampaignRewardConfig` structs, claim-rank state (`_claimOrder`/`_rewardTiers`/`claimCount`), and 23 unused errors. Related: [[ARCHITECTURE]], [[SECURITY_FINDINGS]], [[TEST_AND_BUILD]].
