# Reward System — Web3Campaigns

> As of `fix/per-campaign-module-pinning`. Both ERC20 (B1) and NFT (B2) use escrow + post-campaign Merkle settlement; `RANK_TIERED`/`SCORE_TIERED` add an on-chain alternative (see below). The legacy live-distribution system was deleted in B3. **Security note**: `claimERC20` now rejects claims on swept campaigns (`AlreadySwept`) — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3.

## Model: escrow + post-campaign Merkle settlement

The blockchain's job here is to **guarantee payment from escrow**; distribution *math* (fixed/tiered/FCFS/sybil-filtering) is computed **off-chain** after the campaign ends and committed as a Merkle root. This removes live-claim front-running, silent-zero claims, and the host-wallet rug/brick vector.

There is **no ETH reward path** — ETH only enters via `receive()` and is recoverable by admin via `withdrawETH()`, which sweeps the balance to a stored, admin-settable treasury (`setTreasury`), not an arbitrary caller-supplied address (see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #10).

## ERC20 (DONE — Stage B1)

State (CampaignStorage.sol): `_erc20RewardToken`, `_erc20Escrowed`, `_erc20Distributed`, `_erc20MerkleRoot`, `_erc20SettlementClaimed`, `_campaignClosedAt`, `_erc20Swept`.

Host flow (CampaignManagement.sol):
1. `configureERC20Reward(id, token)` — Draft only; records the reward token. **Does not commit a settlement mode** — token configuration is common to all three ERC20 paths, so MERKLE is committed later by `setERC20MerkleRoot`, and the tiered modes by the module (see "On-chain tiered settlement" below).
2. `fundCampaignERC20(id, amount)` — escrows tokens INTO the contract via `SafeERC20.safeTransferFrom(host -> contract)`. Allowed in Draft/Open/Ended (top-up). **Escrow is credited with the amount ACTUALLY received, not the nominal `amount` requested** — measured via `balanceOf(this)` before/after the pull, so a fee-on-transfer token that skims its own cut in transit can never over-credit escrow beyond what the contract actually custodies. Reverts `NoFundsReceived` if a token skims 100% (nothing arrives). **If a protocol-fee module is registered** (see "Protocol fee" below), the fee is computed on the RECEIVED amount, not the nominal one: `_erc20Escrowed += (received - feeAmount)`, and `feeAmount` is forwarded to the module's treasury in the same call. With no fee module (`_feeModule == address(0)`, the default) and a standard (non-fee-on-transfer) token, behavior is unchanged: `_erc20Escrowed += amount`.
3. `endCampaign(id)` — at/after `endTime`.
4. `setERC20MerkleRoot(id, root)` — Ended only; commits off-chain allocations **and commits the campaign to MERKLE settlement** (the mutual-exclusion lock — reverts `SettlementModeAlreadySet` if the campaign already adopted a tiered mode). Updatable while Ended, frozen at Closed.
5. `withdrawUnclaimedERC20(id)` — after Closed + `CLAIM_GRACE_PERIOD` (30 days); sweeps `escrowed - distributed` to host; single-sweep guarded by `_erc20Swept`.

Participant claim (ParticipantManagement.sol):
- `claimERC20(id, amount, proof)` — status Ended or Closed; **reverts `AlreadySwept` if the campaign's unclaimed escrow has already been swept back to the host** (prevents a late claim from draining another campaign's commingled ERC20 escrow — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3); requires root set; **reverts `RootDisputeWindowActive` until `ROOT_DISPUTE_WINDOW` (24h) has elapsed since the root was last (re-)published** (allocation-fairness mitigation — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14); one claim per account (`_erc20SettlementClaimed`); leaf is the **OZ StandardMerkleTree** format `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`; verified with OZ `MerkleProof.verify`; escrow-accounted (`InsufficientEscrow` if `distributed + amount > escrowed`); pays via `safeTransfer` from escrow. `nonReentrant + whenNotPaused` (Web3Campaigns wrapper).
- `claimERC20For(id, account, amount, proof)` — **sponsored (gasless) variant**: anyone (in practice the project backend, which pays the gas) submits the claim on behalf of `account`; tokens are always paid to `account`, never the caller. Shares the full claim body with `claimERC20` (all the same guards apply, run against `account`), so the worst a third-party caller can do is deliver an account's own allocation to its own wallet earlier than it might have chosen. Rejects `account == address(0)`. See "Sponsored (gasless) claims" below.
- Off-chain tooling must build the tree with `@openzeppelin/merkle-tree` using leaf encoding `["address","uint256"]` to match.

Views (CampaignViewFunctions.sol): `getERC20Settlement(id)` → (token, escrowed, distributed, merkleRoot, closedAt, swept); `hasClaimedERC20(id, account)`; `getERC20ClaimableAt(id)` → timestamp claims open (0 if no root yet).

## Protocol fee (optional, applies to `fundCampaignERC20` on any ERC20 settlement path)

`fundCampaignERC20` checks the admin-rotatable `_feeModule` (`setFeeModule`/`getFeeModule` — a satellite contract, mirroring `OnChainRewardModule`; see [ARCHITECTURE.md](ARCHITECTURE.md)). If registered, it calls `IFeeModule(_feeModule).computeFee(id, received)` (a `view` call — a `STATICCALL`, so the module cannot reenter with a state-changing call) — **on the amount actually received**, not the nominal `amount` the host requested to fund, so a fee-on-transfer token's own in-transit skim is never double-counted or overstated by the protocol fee. Skims the returned `feeAmount` to the returned `treasury`, and escrows `received - feeAmount`. The host still pays the full `amount` from their wallet in one `safeTransferFrom`; `feeAmount` is then forwarded on in a second transfer within the same call (itself also subject to whatever in-transit skim the token applies, same as any other transfer of that token). Emits `ProtocolFeeCollected(id, treasury, feeAmount)` alongside the existing `CampaignFundedERC20` (which reports the **net escrowed** amount, not the gross amount the host paid).

With no fee module registered (`_feeModule == address(0)`, the default), behavior is byte-for-byte unchanged from before this feature existed.

Applies **only** to `fundCampaignERC20` — NFT deposits and the on-chain tiered path are not fee-skimmed (v1 scope). Unlike reward-module rotation, a fee-module rotation carries no in-flight hazard and needs no per-campaign pinning: `computeFee` has no persistent per-campaign state, so a rotation only changes the rate/treasury for funding calls made *after* it.

## ERC20 on-chain tiered settlement (RANK_TIERED / SCORE_TIERED) — dispute-free alternative

Payout amounts are computed purely from on-chain completion state — no host-published root to dispute — in the separately-deployed `OnChainRewardModule` (its own EIP-170 budget). `Web3Campaigns` keeps all custody; the module only decides who gets paid how much and calls back into the trusted `payOnChainReward`.

Flow: `configureERC20Reward` (token only, no mode lock) → host calls `module.setRankTiers`/`setScoreTiers` (Draft), which commits the mode via the `setSettlementMode` callback and **pins the module to the campaign** (once, idempotent) → run campaign (the module is notified of each qualifying completion for rank/score bookkeeping) → `endCampaign` → participants call `module.claimReward(id)` — or anyone calls `module.claimRewardFor(id, participant)` on their behalf (sponsored/gasless, always pays the participant) — paid from escrow via `payOnChainReward`.

- **`claimReward` self-check**: before evaluating any rank/score/tier logic, the module calls `getCampaignRewardModule(id)` and reverts `OnChainRewardModule__NotAuthoritativeModule` if it isn't `address(this)` — so a module acting on stale local state for a campaign it's no longer authoritative for can't even begin computing a payout. Defense-in-depth; see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- **Authorization**: `payOnChainReward` accepts only the per-campaign pinned module (`RewardModuleMismatch` otherwise), independent of the rotatable global default — see [ARCHITECTURE.md](ARCHITECTURE.md).
- **Mutual exclusivity**: a campaign commits to exactly one of MERKLE / RANK_TIERED / SCORE_TIERED; the first commit wins and any cross-mode second commit reverts `SettlementModeAlreadySet`.

## NFT — multi-standard (ERC721 + ERC1155), Merkle settlement (Stage B2), split into `NFTSettlementModule` (satellite)

All NFT settlement logic (Merkle roots, leaf-claimed tracking, per-campaign escrow bookkeeping) lives in the separately-deployed `NFTSettlementModule` (its own EIP-170 budget), not on `Web3Campaigns` — extracted to reclaim `Web3Campaigns`' bytecode headroom, mirroring the `OnChainRewardModule`/`FeeModule` satellite pattern (see [ARCHITECTURE.md](ARCHITECTURE.md)). `Web3Campaigns` keeps **all** NFT custody (it alone implements OZ `ERC721Holder`/`ERC1155Holder`) and all deposit bookkeeping; the module only decides who gets paid what and calls back into the trusted `executeNFTTransferOut` to move a token.

State: `_nftMerkleRoot`, `_nftRootSetAt`, `_nftLeafClaimed`, and the per-campaign escrow ownership maps `_escrowedERC721` (id→token→tokenId→held) / `_escrowedERC1155` (id→token→tokenId→amount) all live on `NFTSettlementModule`. `Web3Campaigns`/`CampaignStorage` keeps only `_nftModule` (global default, admin-rotatable via `setNFTSettlementModule`) and `_campaignNFTModule` (per-campaign pin, see below).

Host flow:
1. `depositERC721Rewards(id, token, tokenIds[])` / `depositERC1155Rewards(id, token, ids[], amounts[])` (still on `Web3Campaigns`, `CampaignManagement.sol`) — escrow NFTs per campaign (Draft/Open/Ended), max 100/call; pins the campaign's `NFTSettlementModule` on first call (see "Per-campaign pinning" below), then forwards the deposit bookkeeping to the pinned module via `INFTSettlementModule.recordERC721Deposit`/`recordERC1155Deposit` before pulling custody. The ownership maps prevent one campaign's settlement from spending another's escrow.
2. `NFTSettlementModule.setNFTMerkleRoot(id, root)` — called directly on the module (not `Web3Campaigns`); Ended only; commits off-chain allocations. Updatable while Ended. Reverts `NotAuthoritativeModule` if the campaign never received a deposit (never pinned).
3. `NFTSettlementModule.withdrawUnclaimedERC721(id, token, tokenIds[])` / `withdrawUnclaimedERC1155(id, token, ids[], amounts[])` — reclaim still-escrowed NFTs after Closed + grace (or immediately once `Cancelled`).

Participant claim (called on the module, not `Web3Campaigns`):
- `NFTSettlementModule.claimNFT(id, standard, token, tokenId, amount, proof)` — status Ended/Closed; leaf `keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount))))`; **reverts `RootDisputeWindowActive` until `ROOT_DISPUTE_WINDOW` (24h) has elapsed since the root was last (re-)published** (same mitigation as the ERC20 path — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14); per-leaf claim guard (`_nftLeafClaimed`); decrements per-campaign escrow (reverts `NFTNotEscrowed` if not held); calls back into `Web3Campaigns.executeNFTTransferOut` to move the token (ERC721 via `safeTransferFrom`, ERC1155 via `safeTransferFrom(...,amount,"")`). `Web3Campaigns.executeNFTTransferOut` is `nonReentrant + whenNotPaused` and authorizes solely against the campaign's pinned module (`NFTModuleMismatch` otherwise).
- `NFTSettlementModule.claimNFTFor(id, account, standard, token, tokenId, amount, proof)` — **sponsored (gasless) variant**, same semantics as `claimERC20For`: the NFT is always delivered to `account`, never the caller. If `account` is a contract, the ERC721/1155 receiver check still applies exactly as it would for a self-submitted claim.
- Off-chain tooling builds the tree with leaf encoding `["address","uint8","address","uint256","uint256"]`.

Views (on the module): `getNFTMerkleRoot`, `isNFTLeafClaimed`, `isERC721Escrowed`, `getERC1155Escrowed`, `getNFTClaimableAt(id)` → timestamp claims open (0 if no root yet). `Web3Campaigns.getCampaignNFTModule(id)` returns the pinned module address (or `address(0)` if never pinned).

### Per-campaign pinning (at first deposit, not at root-set)

`_nftModule` is the global default; a campaign pins to whichever instance is current **the first time it receives an NFT deposit** (`CampaignManagement._pinNFTModule`, idempotent, emits `NFTModulePinned`) — deliberately earlier than the reward module's pin-at-mode-adoption trigger, because escrow bookkeeping starts accumulating at deposit time, which can precede any root ever being published. `Web3Campaigns.executeNFTTransferOut` authorizes solely against this per-campaign pin, so a later admin rotation of `_nftModule` can never desync a campaign's already-recorded escrow bookkeeping — the same protection `_campaignRewardModule` gives the on-chain tiered reward path. Every module entrypoint independently re-verifies `getCampaignNFTModule(id) == address(this)` before acting on its own state (defense-in-depth self-check, same pattern as `OnChainRewardModule.claimReward`).

## Sponsored (gasless) claims — claimERC20For / claimNFTFor / claimRewardFor

All three claim paths have a `...For` variant that lets **anyone** submit a claim on behalf of an allocated account, with the reward always delivered to that account — never the caller. The intended user is the project's own backend: a user clicks "claim" in the app, the backend submits the transaction and pays the gas, and the user receives their reward without holding any ETH. This achieves gasless UX with **no meta-transaction framework** (no ERC-2771 trusted forwarder, no ERC-4337 paymaster) — deliberately, since integrating ERC-2771 would change `_msgSender()` semantics across the whole contract for marginal benefit.

Why permissionless submission is safe: in every path, what's being claimed is bound to the account, not the caller — the ERC20/NFT Merkle leaf commits to `(account, ...)`, and the on-chain-tiered payout is computed purely from the participant's own rank/score state. A hostile third party can therefore only deliver an account's own allocation to that account's own wallet, possibly earlier than the account would have chosen. Each `...For` variant shares its entire body (checks-effects-payout) with the self-claim path via an internal function, so every guard (double-claim, dispute window, sweep, escrow accounting, pause) applies identically. See [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) for the forced-claim griefing discussion.

## Allocation-fairness dispute window (applies to both ERC20 and NFT roots)

`setERC20MerkleRoot`/`setNFTMerkleRoot` record when a root's VALUE last actually changed; `claimERC20`/`claimNFT` reject claims until `ROOT_DISPUTE_WINDOW` (24h, `CampaignStorage`) has elapsed since that timestamp. Publishing a genuinely different root — including a host correcting a bad allocation — rearms the window from scratch; republishing the byte-identical root is a no-op and does **not** rearm it (otherwise a host could indefinitely stall a published root's claims by "updating" to an unchanged value). This is a delay-based mitigation giving the community time to catch an unfair root and escalate (e.g. `emergencyPause`) before funds move; there is no on-chain flagging/veto mechanism. Sweeps need no separate gating: they require `Closed` + `CLAIM_GRACE_PERIOD` (30 days), which already dominates the 24h window since roots freeze at `Closed`. Full rationale and limitations: [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #14.

## Cancellation refund (`cancelCampaign`)

`cancelCampaign(id)` (CampaignManagement.sol) — host-only, requires status Draft or Open **and** `campaign.totalParticipants == 0`; transitions to the terminal `Cancelled` status. Deliberately restrictive: once one participant has genuinely engaged, cancellation is permanently blocked (`CampaignHasParticipants`), closing a bait-and-switch path where a host could let participants do free work and cancel right before `Ended` to dodge paying out.

- **ERC20**: refunded immediately in the same call via the internal `_refundERC20IfAny` — no grace period, since no Merkle root could ever have been published pre-Ended (claims require `Ended`/`Closed`), so no claim was ever possible. Silently no-ops if no ERC20 reward was configured/escrowed (unlike the explicit `withdrawUnclaimedERC20`, which reverts on nothing-to-sweep).
- **NFT**: not auto-refunded (no on-chain enumerable per-campaign inventory list to iterate) — instead, `NFTSettlementModule.withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` become **immediately callable** (no grace wait) once status is `Cancelled` (see the module's `_requireSweepable`'s early-return for that status). Host calls them with the specific tokenIds/ids they know they deposited.
- Emits `CampaignCancelled(id, host, refundedERC20)` plus the usual `CampaignStatusUpdated`.

## Off-chain reward

`setOffChainReward(id, description, metadata)` — no on-chain payout; informational (stored in the standalone `_offChainReward` mapping). View: `getOffChainReward(id)`.

## Removed (B1–B3)

The entire live-distribution system is gone: ERC20 setters (`setERC20RewardFixed/FCFS/Tiered`, legacy `setCampaignReward`), NFT pool (`setNFTReward`/`addNFTsToPool`), `claimReward`, the `_processERC20Reward`/`_processNFTReward`/`_verifyAllTasksCompleted` internals, the `DistributionMode`/`RewardType` enums, the `RewardTier`/`NFTPool`/`ERC20Reward`/`NFTReward`/`CampaignRewardConfig` structs, claim-rank state (`_claimOrder`/`_rewardTiers`/`claimCount`), and 23 unused errors. Related: [[ARCHITECTURE]], [[SECURITY_FINDINGS]], [[TEST_AND_BUILD]].
