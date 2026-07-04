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

- `DEFAULT_ADMIN_ROLE` — revokeHostRole, withdrawETH, and grants/revokes every other role including `SIGNER_ROLE` (the key-rotation path for compromised backend signers).
- `HOST_ROLE` — createCampaign. **Note: `grantHostRole` is intentionally open/unguarded** (anyone can self-grant) per founder decision; see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).
- `EMERGENCY_ADMIN` — emergencyPause / emergencyUnpause.
- `MODERATOR_ROLE` — `flagAccount(user, score)` to set the suspicious-activity gate used in `completeTask`.
- `SIGNER_ROLE` — backend keys authorized to sign EIP-712 off-chain task-completion attestations consumed by `verifyTaskCompletionWithSignature`. See [TASK_VERIFICATION.md](TASK_VERIFICATION.md).
- **Per-campaign `host`** — campaign ownership enforced by the `onlyHost` modifier (`campaign.host == msg.sender`), distinct from `HOST_ROLE`. Funds/configures/settles rewards and sweeps unclaimed escrow for its own campaigns.

## Lifecycle state machine (strictly forward, no reverse)

`Draft → Open → Ended → Closed`

- **Draft**: configure tasks + rewards. Entered via `createCampaign` (HOST_ROLE).
- `openCampaign` (host): Draft→Open. `completeTask` (self-verify) allowed only when Open + within start/end time. `verifyTaskCompletionWithSignature` (signed off-chain verification) allowed when Open or Ended.
- `endCampaign` (host): Open→Ended, requires `block.timestamp >= endTime` (NOTE: code requires this despite a comment claiming early-end is allowed — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)).
- `closeCampaign` (host): Ended→Closed (records `_campaignClosedAt` to start the unclaimed-sweep grace window).

## Reward / claim flow (v0.3 — escrow + Merkle settlement)

ERC20 (Stage B1, done): `configureERC20Reward` (Draft) → `fundCampaignERC20` (escrow into contract) → run campaign → `endCampaign` → `setERC20MerkleRoot` (off-chain allocations) → participants `claimERC20(amount, proof)` from escrow → after `Closed` + 30-day grace, host `withdrawUnclaimedERC20`. See [REWARD_SYSTEM.md](REWARD_SYSTEM.md).

NFT (Stage B2, done): `depositERC721Rewards`/`depositERC1155Rewards` (escrow per campaign) → `endCampaign` → `setNFTMerkleRoot` → participants `claimNFT(standard, token, tokenId, amount, proof)` → host `withdrawUnclaimedERC721`/`withdrawUnclaimedERC1155` after grace. Supports ERC721 + ERC1155; the contract custodies via OZ `ERC721Holder`/`ERC1155Holder`.

## Task verification (Phase 2 — signed attestations)

Off-chain tasks (social follows, Discord joins, `ONCHAIN_TX`) are verified via EIP-712 signed attestations from a `SIGNER_ROLE` key, not host transactions — `verifyTaskCompletionWithSignature`/`batchVerifyTaskCompletionWithSignatures` replaced the old `verifyTaskCompletion`/`batchVerifyTaskCompletion`. `ONCHAIN_HOLD_ERC20/ERC721` remain self-verified on-chain in `completeTask` and are not signature-overridable. Full detail: [TASK_VERIFICATION.md](TASK_VERIFICATION.md).

## Conventions

Uses OZ `AccessControl` (not Ownable), `EIP712`, `SafeERC20`, `ReentrancyGuard`, `Pausable`. Custom errors, events on state changes. Tasks capped (20), batch ops capped (`MAX_BATCH_SIZE = 50`, NFT deposits ≤ 100/call). Reward mechanics: see [REWARD_SYSTEM.md](REWARD_SYSTEM.md).
