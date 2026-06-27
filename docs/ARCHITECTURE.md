# Architecture — Web3Campaigns

Dapp-Drop is a Web3 quest/campaign-and-reward platform (Galxe/Zealy-style): hosts create campaigns with tasks; participants complete + get verified, then claim ERC20/NFT/off-chain rewards. Solidity + Foundry + OpenZeppelin, deployed to Sepolia (chain 11155111). Frontend lives in a separate repo — out of scope here. `dev` is the source-of-truth branch (see [BRANCHES.md](BRANCHES.md)).

## Composition (all state shared via one abstract storage base)

```
AccessControl (OZ)
  └─ CampaignStorage (abstract): ALL state, structs, enums, roles, errors, base modifiers
       ├─ CampaignManagement     (create campaigns, configure rewards, lifecycle transitions)
       ├─ ParticipantManagement  (completeTask, verify, claimReward, reward payout internals)
       └─ CampaignViewFunctions  (read-only getters)
            ↓ + ReentrancyGuard + Pausable
       Web3Campaigns  ← DEPLOYED ENTRYPOINT; wraps mutators with whenNotPaused/nonReentrant via super.*
```

`Web3Campaigns` has a no-arg constructor. The constructor chain grants the deployer `DEFAULT_ADMIN_ROLE` + `HOST_ROLE` (CampaignManagement) and `EMERGENCY_ADMIN` (Web3Campaigns).

## Roles

- `DEFAULT_ADMIN_ROLE` — revokeHostRole, withdrawETH.
- `HOST_ROLE` — createCampaign. **Note: `grantHostRole` is intentionally open/unguarded** (anyone can self-grant) per founder decision; see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- `EMERGENCY_ADMIN` — emergencyPause / emergencyUnpause.
- `MODERATOR_ROLE` — `flagAccount(user, score)` to set the suspicious-activity gate used in `completeTask`.
- **Per-campaign `host`** — campaign ownership enforced by the `onlyHost` modifier (`campaign.host == msg.sender`), distinct from `HOST_ROLE`. Funds/configures/settles rewards and sweeps unclaimed escrow for its own campaigns.

## Lifecycle state machine (strictly forward, no reverse)

`Draft → Open → Ended → Closed`

- **Draft**: configure tasks + rewards. Entered via `createCampaign` (HOST_ROLE).
- `openCampaign` (host): Draft→Open. `completeTask` allowed only when Open + within start/end time.
- `endCampaign` (host): Open→Ended, requires `block.timestamp >= endTime` (NOTE: code requires this despite a comment claiming early-end is allowed — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)).
- `closeCampaign` (host): Ended→Closed (records `_campaignClosedAt` to start the unclaimed-sweep grace window).

## Reward / claim flow (v0.3 — escrow + Merkle settlement)

ERC20 (Stage B1, done): `configureERC20Reward` (Draft) → `fundCampaignERC20` (escrow into contract) → run campaign → `endCampaign` → `setERC20MerkleRoot` (off-chain allocations) → participants `claimERC20(amount, proof)` from escrow → after `Closed` + 30-day grace, host `withdrawUnclaimedERC20`. See [REWARD_SYSTEM.md](REWARD_SYSTEM.md).

NFT: still the legacy live pool (`claimReward`) until Stage B2 migrates it to multi-standard (ERC721 + ERC1155) Merkle settlement.

## Conventions

Uses OZ `AccessControl` (not Ownable), `SafeERC20`, `ReentrancyGuard`, `Pausable`. Custom errors, events on state changes. Tasks capped (20), tiers capped (10), batch ops capped (`MAX_BATCH_SIZE = 50`, `addNFTsToPool` ≤ 100/call). Reward mechanics: see [REWARD_SYSTEM.md](REWARD_SYSTEM.md).
