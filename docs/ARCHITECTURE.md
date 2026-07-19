# Architecture — Web3Campaigns

Dapp-Drop is a Web3 quest/campaign-and-reward platform (Galxe/Zealy-style): hosts create campaigns with tasks; participants complete + get verified, then claim ERC20/NFT/off-chain rewards. Solidity + Foundry + OpenZeppelin, deployed to Sepolia (chain 11155111). Frontend lives in a separate repo — out of scope here. `dev` is the source-of-truth branch (see [BRANCHES.md](BRANCHES.md)).

## Composition (all state shared via one abstract storage base)

```
AccessControl (OZ) + EIP712 (OZ)
  └─ CampaignStorage (abstract): ALL state, structs, enums, roles, errors, base modifiers
       ├─ CampaignManagement     (create campaigns, configure rewards, lifecycle transitions)
       ├─ ParticipantManagement  (completeTask, verify, claimReward, reward payout internals)
       └─ CampaignViewFunctions  (read-only getters)
            ↓ + ReentrancyGuard + Pausable + ERC721Holder + ERC1155Holder
       Web3Campaigns  ← DEPLOYED ENTRYPOINT; wraps mutators with whenNotPaused/nonReentrant via super.*
```

`Web3Campaigns` has a no-arg constructor. The constructor chain grants the deployer `DEFAULT_ADMIN_ROLE` + `HOST_ROLE` (CampaignManagement), `EMERGENCY_ADMIN` + `MODERATOR_ROLE` + `SIGNER_ROLE` (Web3Campaigns), and calls `EIP712("Web3Campaigns", "1")` (CampaignStorage) for signed-attestation support (see [TASK_VERIFICATION.md](TASK_VERIFICATION.md)).

## Roles

- `DEFAULT_ADMIN_ROLE` — revokeHostRole, setTreasury + withdrawETH (sweeps to the stored treasury, not an arbitrary address), the module setters (`setOnChainRewardModule`/`setFeeModule`/`setNFTSettlementModule`), and grants/revokes every other role including `SIGNER_ROLE` (the key-rotation path for compromised backend signers).
- `HOST_ROLE` — createCampaign. **Note: `grantHostRole` is intentionally open/unguarded** (anyone can self-grant) per founder decision; see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- `EMERGENCY_ADMIN` — emergencyPause / emergencyUnpause.
- `MODERATOR_ROLE` — `flagAccount(user, score)` to set the suspicious-activity gate used in `completeTask`.
- `SIGNER_ROLE` — backend keys authorized to sign EIP-712 off-chain task-completion attestations consumed by `verifyTaskCompletionWithSignature`. See [TASK_VERIFICATION.md](TASK_VERIFICATION.md).
- **Per-campaign `host`** — campaign ownership enforced by the `onlyHost` modifier (`campaign.host == msg.sender`), distinct from `HOST_ROLE`. Funds/configures/settles rewards and sweeps unclaimed escrow for its own campaigns.

## Lifecycle state machine (strictly forward, no reverse)

```
Draft → Open → Ended → Closed
  ↓        ↓
  └──→ Cancelled (only while totalParticipants == 0)
```

- **Draft**: configure tasks + rewards. Entered via `createCampaign` (HOST_ROLE).
- `openCampaign` (**host-only**, deliberately): Draft→Open. Opening is the host's "config is done, go live" decision — not auto-triggered, so a half-configured/unfunded campaign can't be forced live. `completeTask` (self-verify) allowed only when Open + within start/end time. `verifyTaskCompletionWithSignature` (signed off-chain verification) allowed when Open or Ended.
- `endCampaign` (**permissionless**, time-gated): Open→Ended, requires `block.timestamp >= endTime`. Anyone (in practice the platform keeper, but also any participant) may call it once the endTime has passed — so a campaign always ends on schedule even if the host abandons it, which is what unblocks claims/settlement in the abandoned-host case. No early-end is possible (the endTime gate binds every caller). See the "Permissionless lifecycle" note in [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- `closeCampaign` (**host-only**, deliberately): Ended→Closed (records `_campaignClosedAt` to start the unclaimed-sweep grace window). Kept host-gated because closing freezes the Merkle root, so a permissionless close would let a griefer lock the host out of finalizing/correcting allocations. Closing is a host convenience (it starts the host's own reclaim clock); leaving it host-only creates no lockup — claims work indefinitely in Ended.
- `cancelCampaign` (host): Draft, Open, **or Ended** → Cancelled, **only while `campaign.totalParticipants == 0`** — the real gate is the participant count, not the status. The moment one participant has genuinely engaged (completed any task), cancellation is permanently blocked (`CampaignHasParticipants`) — this closes a bait-and-switch griefing path where a host could otherwise let participants do free work and cancel right before Ended to dodge paying out. `Ended` is included specifically because `endCampaign` is permissionless: a keeper can end a past-deadline campaign that never had a single participant, and the host must still get the same immediate refund rather than being forced into the 30-day `closeCampaign` grace path. `Closed` is deliberately excluded — once closed, the host has already chosen the grace-period path. Refunds escrowed ERC20 immediately (no grace period — safe because zero participants means no claim was ever possible). Escrowed NFTs are reclaimed via the existing `withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155`, which become immediately callable (no grace wait) once a campaign is `Cancelled`. See [REWARD_SYSTEM.md](REWARD_SYSTEM.md).

## Reward / claim flow (v0.3 — escrow + Merkle settlement)

ERC20 (Stage B1, done): `configureERC20Reward` (Draft) → `fundCampaignERC20` (escrow into contract, crediting the amount **actually received** rather than the nominal amount requested — fee-on-transfer-safe, see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)) → run campaign → `endCampaign` → `setERC20MerkleRoot` (off-chain allocations; starts a `ROOT_DISPUTE_WINDOW`, currently 24h) → participants `claimERC20(amount, proof)` from escrow once the window elapses (reverts `RootDisputeWindowActive` before then, `AlreadySwept` after host sweep — required because ERC20 escrow is a commingled pool, see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) #3) → after `Closed` + 30-day grace, host `withdrawUnclaimedERC20`. See [REWARD_SYSTEM.md](REWARD_SYSTEM.md).

NFT (Stage B2, done): `depositERC721Rewards`/`depositERC1155Rewards` (escrow per campaign, `Web3Campaigns` custodies via OZ `ERC721Holder`/`ERC1155Holder`) → `endCampaign` → `setNFTMerkleRoot` (also starts the dispute window) → participants `claimNFT(standard, token, tokenId, amount, proof)` once it elapses → host `withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` after grace. `setNFTMerkleRoot`/`claimNFT`/`withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` are called on the campaign's `NFTSettlementModule`, not on `Web3Campaigns` directly — see below.

## On-chain tiered settlement + per-campaign module pinning

An alternative to Merkle settlement: `RANK_TIERED` / `SCORE_TIERED` ERC20 rewards are computed on-chain (by completion rank or task-point score) in a separately-deployed `OnChainRewardModule`, which holds all rank/score/tier state. `Web3Campaigns` keeps all custody and pays out only via the trusted `payOnChainReward` callback. See [REWARD_SYSTEM.md](REWARD_SYSTEM.md).

`_onChainRewardModule` is the **global default** — the module instance assigned to a campaign the first time it adopts an on-chain (tiered) mode. It is admin-rotatable (`setOnChainRewardModule`), but rotation only affects *future* adoptions:
- **Pinning happens once**, in `setSettlementMode`: the first `RANK_TIERED`/`SCORE_TIERED` commit records `_campaignRewardModule[id] = _onChainRewardModule` and emits `RewardModulePinned`. Same-mode re-configs (e.g. re-publishing tiers while Draft) are idempotent — no re-pin, no re-emit.
- **`payOnChainReward` authorizes solely against the per-campaign pin** (`msg.sender == _campaignRewardModule[id]`, else `RewardModuleMismatch`), *not* the global default. So a module rotated out of the global slot stays authoritative for every campaign it was already pinned to, and a newly-registered module cannot settle campaigns adopted under an older one.

## Protocol fee module (satellite, no pinning needed)

A second satellite contract, `FeeModule`, mirrors the `OnChainRewardModule` split: `Web3Campaigns` retains all fund custody, `FeeModule` only computes a fee via `IFeeModule.computeFee(campaignId, amount) view returns (uint256 feeAmount, address treasury)`. Referenced through the admin-rotatable `_feeModule` (`setFeeModule`/`getFeeModule`; `address(0)` disables fees entirely — the default, and byte-for-byte unchanged behavior for every campaign that predates this feature).

`fundCampaignERC20` calls `computeFee` (a `view` call, so Solidity emits a `STATICCALL` — a malicious module cannot reenter with a state-changing call from inside it), skims `feeAmount` to `treasury`, and escrows the remainder. The host still pays the full gross amount from their wallet; `CampaignFundedERC20` reports the **net escrowed** amount, `ProtocolFeeCollected` reports the fee separately.

**Deliberately NOT pinned per campaign**, unlike the reward module — and this is a real architectural distinction worth understanding, not an oversight:
- The reward module holds **persistent per-campaign state** (rank/score) that accumulates across many calls over a campaign's lifetime; a rotation mid-campaign could orphan that state on the old module while claims moved to a new one, which is exactly the desync `_campaignRewardModule` pinning prevents.
- Fee computation has **no persistent per-campaign state at all**: `computeFee` is a pure function of `(amount, the module's current global config)`, evaluated and fully settled — fee transferred, escrow credited — within the single `fundCampaignERC20` call that invoked it. There is nothing left over that a later rotation could orphan or desync. A rotation only changes the rate/treasury used by funding calls made **after** it, which is the intended effect, not a hazard.

The reference `FeeModule` implementation is a flat global basis-point rate (capped at `MAX_FEE_BPS`, sanity bound not policy) with a single rotatable `admin` — deliberately minimal (no OZ `AccessControl` import) to keep this satellite's own EIP-170 footprint small, matching `OnChainRewardModule`'s lightweight-satellite style. `IFeeModule.computeFee`'s `campaignId` parameter is currently unused by this implementation but is kept in the interface so a future per-campaign fee tier can be added without changing the `fundCampaignERC20` call site.

## NFT settlement module (satellite, pinned at first deposit)

A third satellite contract, `NFTSettlementModule`, extracts all NFT Merkle-settlement logic and bookkeeping out of `Web3Campaigns` to reclaim EIP-170 headroom — `Web3Campaigns` still retains 100% of NFT custody (it alone implements `ERC721Holder`/`ERC1155Holder`); the module holds only the Merkle roots, leaf-claimed tracking, and per-campaign escrow accounting, and calls back into `executeNFTTransferOut` (a trusted callback gated to the campaign's pinned module) to actually move a token. Users call `setNFTMerkleRoot`/`claimNFT`/`withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` directly on the module instance (`getCampaignNFTModule(id)`), mirroring `OnChainRewardModule.claimReward`'s entrypoint shape — `Web3Campaigns` no longer exposes these functions itself.

`_nftModule` is the **global default**, admin-rotatable via `setNFTSettlementModule`. Unlike the reward module (pinned at settlement-mode adoption), the NFT module pins **at first deposit** (`CampaignManagement._pinNFTModule`, called from both `depositERC721Rewards` and `depositERC1155Rewards`):
- Escrow bookkeeping starts accumulating the moment a deposit lands — before any Merkle root could ever be published — so first-deposit is the earliest point a rotation could otherwise desync per-campaign state. Waiting until `setNFTMerkleRoot` (mirroring the reward module's later trigger) would leave a window between an unpinned deposit and a later root-set where a rotation could orphan already-recorded escrow.
- The pin is idempotent (`_campaignNFTModule[id]` set once, checked before overwriting) and every module entrypoint independently re-verifies it via `getCampaignNFTModule(id) == address(this)` before acting on its own state — same defense-in-depth self-check pattern as the reward module.
- A direct consequence: a campaign that never deposits an NFT can never call `setNFTMerkleRoot` (reverts `NotAuthoritativeModule`) — a strictly stronger guarantee than before, closing a drain attempt one step earlier.

## Task verification (Phase 2 — signed attestations)

Off-chain tasks (social follows, Discord joins, `ONCHAIN_TX`) are verified via EIP-712 signed attestations from a `SIGNER_ROLE` key, not host transactions — `verifyTaskCompletionWithSignature`/`batchVerifyTaskCompletionWithSignatures` replaced the old `verifyTaskCompletion`/`batchVerifyTaskCompletion`. `ONCHAIN_HOLD_ERC20/ERC721` remain self-verified on-chain in `completeTask` and are not signature-overridable. Full detail: [TASK_VERIFICATION.md](TASK_VERIFICATION.md).

## Conventions

Uses OZ `AccessControl` (not Ownable), `EIP712`, `SafeERC20`, `ReentrancyGuard`, `Pausable`. Custom errors, events on state changes. Tasks capped (20), batch ops capped (`MAX_BATCH_SIZE = 50`, NFT deposits ≤ 100/call). Participants per campaign are capped only if the host opts in via `setMaxParticipants` (0 = unlimited, the default; hard-capped at `MAX_PARTICIPANTS_LIMIT` = 100,000). Reward mechanics: see [REWARD_SYSTEM.md](REWARD_SYSTEM.md).
