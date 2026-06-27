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
- `HOST_ROLE` — createCampaign.
- `EMERGENCY_ADMIN` — emergencyPause / emergencyUnpause.
- **Per-campaign `host`** — campaign ownership enforced by the `onlyHost` modifier (`campaign.host == msg.sender`), distinct from `HOST_ROLE`.

## Lifecycle state machine (strictly forward, no reverse)

`Draft → Open → Ended → Closed`

- **Draft**: configure tasks + rewards. Entered via `createCampaign` (HOST_ROLE).
- `openCampaign` (host): Draft→Open. `completeTask` allowed only when Open + within start/end time.
- `endCampaign` (host): Open→Ended, requires `block.timestamp >= endTime` (NOTE: code requires this despite a comment claiming early-end is allowed — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)).
- `closeCampaign` (host): Ended→Closed. `claimReward` allowed only when Ended.

## Conventions

Uses OZ `AccessControl` (not Ownable), `SafeERC20`, `ReentrancyGuard`, `Pausable`. Custom errors, events on state changes. Tasks capped (20), tiers capped (10), batch ops capped (`MAX_BATCH_SIZE = 50`, `addNFTsToPool` ≤ 100/call). Reward mechanics: see [REWARD_SYSTEM.md](REWARD_SYSTEM.md).
