# Task Verification — Web3Campaigns

> Phase 2 (`feature/phase2-signature-verification`, forked from `dev` post-v0.3). Replaces host-tx verification of off-chain tasks with EIP-712 signed attestations.

## Model: signed attestations, not host transactions

Previously the host sent an on-chain tx (`verifyTaskCompletion`/`batchVerifyTaskCompletion`) per participant per off-chain task (Twitter follow, Discord join, etc.) — gas the host ate, and it didn't scale past a few hundred users. Now a **`SIGNER_ROLE`** key (typically the host's backend, after checking the actual social API) signs an EIP-712 attestation off-chain, and **anyone** can submit it on-chain — the contract only trusts the recovered signer, not `msg.sender`. This is **trust-minimized, not trustless**: verification correctness still depends on the signer's backend being honest and its key staying uncompromised. Key rotation/revocation is a plain `AccessControl` `grantRole`/`revokeRole(SIGNER_ROLE, ...)` call by `DEFAULT_ADMIN_ROLE` — no custom rotation function needed.

`ONCHAIN_HOLD_ERC20`/`ONCHAIN_HOLD_ERC721` are unaffected — they remain self-verified on-chain in `completeTask` and are explicitly rejected by the signature path (`Web3Campaigns__TaskNotVerifiableByHost`) to prevent a compromised signer from forging on-chain-verifiable facts.

## EIP-712 domain & typehash

Domain: `EIP712("Web3Campaigns", "1")`, standard OZ `EIP712` (name/version/chainId/verifyingContract — `verifyingContract` is the deployed `Web3Campaigns` address, so a signature for one deployment can never validate against another).

```
TaskAttestation(uint256 campaignId,address participant,uint256 taskIndex,bool completed,uint256 version,uint256 deadline)
```

`TASK_ATTESTATION_TYPEHASH` is a public constant on `CampaignStorage` for off-chain tooling to reference directly.

## Replay guard = update mechanism (the version counter)

`_taskAttestationVersion[participant][campaignId][taskIndex]` starts at 0. Each accepted attestation must target `currentVersion + 1`, and using it advances state to that version — so:
- **A used signature can never be replayed** (its `version` field no longer matches `current + 1`).
- **The signer can issue a fresh attestation later** to flip `completed` back to `false` (correcting a mistake) or re-affirm `true` (re-verifying a task that requires periodic proof, e.g. continued token holding via an off-chain indexer) — just by signing the next version. No separate nonce mapping needed.
- Read the current version via `getTaskAttestationVersion(campaignId, participant, taskIndex)` before constructing a new attestation to sign.

`totalParticipants` only increments on a participant's first-ever `completed=true` transition — flipping a completion back to `false` does **not** decrement it (it tracks lifetime participation, not current status).

## Functions

- `verifyTaskCompletionWithSignature(campaignId, participant, taskIndex, completed, deadline, signature)` — `ParticipantManagement.sol`. Requires campaign Open/Ended, task exists and isn't `ONCHAIN_HOLD_*`, `block.timestamp <= deadline`, and the recovered signer holds `SIGNER_ROLE`. Anyone may call it (gas payer need not be the host or signer).
- `batchVerifyTaskCompletionWithSignatures(campaignId, participants[], taskIndices[], completedFlags[], deadlines[], signatures[])` — loops the single-item function; **atomic** (the whole tx reverts if any one attestation is invalid/expired — no silent partial application).
- Both are `whenNotPaused`-wrapped in `Web3Campaigns.sol`.

## Off-chain integration sketch

A backend signing service should, per attestation:
1. Verify the actual completion (Twitter API, Discord webhook, etc.).
2. Read `getTaskAttestationVersion(campaignId, participant, taskIndex)` → `v`.
3. Sign `TaskAttestation{campaignId, participant, taskIndex, completed, version: v+1, deadline}` under the `Web3Campaigns` EIP-712 domain with a `SIGNER_ROLE` key.
4. Hand the signature to the participant/relayer/host to submit via `verifyTaskCompletionWithSignature` (or batch it).

## Removed

`verifyTaskCompletion` and `batchVerifyTaskCompletion` (host-tx path) are gone — replaced wholesale, not run alongside (deliberate scope decision; see `docs/NEXT_STEPS.md`).

## Open items / caveats
- **Trust model**: this is signer-trusted, not trustless. A compromised `SIGNER_ROLE` key can mint arbitrary completions until revoked. No threshold (N-of-M) signing yet — single-signer by design for this phase; see `docs/NEXT_STEPS.md` if that needs revisiting.
- **Contract size**: `Web3Campaigns` is now 21.1KB runtime (24.576KB limit) — 3.4KB headroom left. Future features should watch `forge build --sizes`.

Related: [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md), [TEST_AND_BUILD.md](TEST_AND_BUILD.md).
