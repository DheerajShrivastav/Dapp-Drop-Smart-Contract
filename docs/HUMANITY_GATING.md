# Humanity Gating — Web3Campaigns

> Founder decisions (2026-07-13): sybil resistance uses **Humanity Protocol** via their **off-chain OAuth SDK**; the flow must be **fully automated** — no manual signing step, no host involvement per participant. Humanity Protocol has **no on-chain interface yet** (still building one), which fixes the design below.

## The constraint that shapes everything

A smart contract cannot call a web API. Humanity Protocol's verification status currently lives only behind their OAuth SDK, so **verification status must pass through the project backend to have any effect on-chain**. There is no design that avoids this today. The moment Humanity Protocol ships an on-chain registry, a trust-minimized upgrade path exists (see "Future" below) — until then, the backend is the trust root for humanity status, and pretending otherwise (e.g. a backend-synced on-chain allowlist) only adds gas costs and sync lag without removing that trust.

## Decision: enforce off-chain, at the three points the backend already controls

**No contract changes.** Humanity gating rides entirely on infrastructure that already exists and is already automated:

### 1. Merkle campaigns — filter the allocation tree (primary enforcement)

The backend builds the Merkle allocation tree after a campaign ends ([REWARD_SYSTEM.md](REWARD_SYSTEM.md)). For a humanity-gated campaign, it checks each candidate wallet's Humanity Protocol status **at tree-build time** and simply omits unverified wallets. A wallet not in the tree has no leaf, so it *mathematically cannot claim* — `claimERC20`/`claimNFT` reject any proof that doesn't recompute the published root (`InvalidMerkleProof`). This is the strongest enforcement point: it needs no gas, no signature, and no new trust — the root commitment mechanism already on-chain does all the work.

### 2. Sponsored claims — re-check at submission (secondary checkpoint)

With sponsored (gasless) claims (`claimERC20For`/`claimNFTFor`/`claimRewardFor`), the backend is the party submitting claim transactions and paying gas. It re-checks humanity status immediately before submitting. Note the limits: this is a *courtesy* checkpoint, not enforcement — sponsored entrypoints are deliberately permissionless, so a user who is IN the tree can always self-claim with their own gas. Enforcement is point 1 (not being in the tree at all); point 2 only ensures the project doesn't *sponsor* a claim it considers ineligible.

### 3. On-chain tiered campaigns — required `HUMANITY_VERIFICATION` task

`RANK_TIERED`/`SCORE_TIERED` campaigns have no Merkle tree to filter, but they already gate payouts on required tasks: `OnChainRewardModule.claimReward` refuses to pay any participant who has not completed **all required tasks** (`_currentlyQualified`, see [REWARD_SYSTEM.md](REWARD_SYSTEM.md)). So a humanity-gated tiered campaign adds `HUMANITY_VERIFICATION` as a **required** task. Completion is settled by the existing signed-attestation path ([TASK_VERIFICATION.md](TASK_VERIFICATION.md)).

**On "no signer" — an important clarification.** The `SIGNER_ROLE` attestation flow is *not* a manual process. The signer key lives on the backend server and signs programmatically, inside the OAuth callback handler, in the same request — exactly how every other off-chain task (social follow, Discord join) is already settled. No human signs anything; no host asks anyone for anything. "Automated, no signer involvement" in the founder decision is satisfied in spirit: what's excluded is *manual* signing, and there is none anywhere in this design. (A design with literally no signature at all would require Humanity Protocol's on-chain registry, which does not exist yet.)

## End-user experience

1. User clicks "Verify humanity" once in the app → completes Humanity Protocol's OAuth.
2. Backend receives the callback, verifies status via the Humanity SDK, stores it, and (for tiered campaigns) immediately signs + submits the `HUMANITY_VERIFICATION` attestation.
3. Everything after that is automatic — allocation filtering, claim sponsorship checks, tiered-payout qualification. The user never sees any of it; the host does nothing per-participant.

One OAuth, once per wallet, ever. That is the entire user-facing surface.

## Backend spec (what the other repo must implement)

- **On Humanity OAuth callback**: verify with the Humanity SDK; persist `wallet → verified` (with timestamp); for any active humanity-gated tiered campaign the wallet participates in, sign and submit the `HUMANITY_VERIFICATION` attestation via `verifyTaskCompletionWithSignature` (leaf/typehash spec in [TASK_VERIFICATION.md](TASK_VERIFICATION.md)).
- **At Merkle tree build** (per humanity-gated campaign): re-query stored status for every candidate wallet; exclude unverified wallets from the leaf set; build with `@openzeppelin/merkle-tree` (leaf encodings in [REWARD_SYSTEM.md](REWARD_SYSTEM.md)); publish via `setERC20MerkleRoot` / `NFTSettlementModule.setNFTMerkleRoot`.
- **Before sponsoring any claim**: re-check stored status; decline sponsorship (do not submit) if unverified. Do not treat this as enforcement — see point 2 above.
- **Revocation handling**: if Humanity Protocol reports a verification revoked, the backend may sign a `completed=false` re-attestation (the version-counter update path in [TASK_VERIFICATION.md](TASK_VERIFICATION.md)) to disqualify the participant from tiered payouts, and must exclude the wallet from any *future* tree builds. Already-published roots are immutable once the campaign closes — a revocation after root publish does not claw back an allocation (accepted limitation, same trust window as any off-chain allocation input).

## Trust model (stated plainly)

- The backend is the trust root for humanity status in every feasible design today. A compromised backend could include unverified wallets in a tree or attest falsely — but that same backend already controls tree contents entirely (it chooses every allocation), so humanity gating adds **no new trust** beyond what Merkle settlement already assumes. See the host/allocation trust boundary in [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md) (#14 and the B1–B2 notes).
- The `ROOT_DISPUTE_WINDOW` (24h) applies unchanged: a tree that visibly includes sybil wallets can be caught and escalated before funds move.
- `HUMANITY_VERIFICATION` gating for tiered campaigns inherits the single-`SIGNER_ROLE` trust boundary documented in [TASK_VERIFICATION.md](TASK_VERIFICATION.md) (rotate the key if compromised).

## Future: `IHumanityModule` (deliberately NOT built yet)

When Humanity Protocol ships an on-chain credential registry on the deployment chain, add a rotatable satellite adapter — the established pattern (`OnChainRewardModule`/`FeeModule`/`NFTSettlementModule`):

```solidity
interface IHumanityModule {
    function isVerified(address account) external view returns (bool);
}
```

consulted at claim time for humanity-gated campaigns. That is the day gating becomes trustless (no backend in the loop). Building the adapter *before* their registry exists would just wrap a backend-synced allowlist — identical trust to today's design with extra gas per user — so it is intentionally deferred until their launch, not ours. (Contract-size note: `Web3Campaigns` has <1KB of EIP-170 headroom; the claim-time check for the ERC20 Merkle path would be inline and must be size-measured when this is picked up. The NFT and tiered paths live in satellites with ample room.)

Related: [[TASK_VERIFICATION]], [[REWARD_SYSTEM]], [[SECURITY_FINDINGS]], [[ARCHITECTURE]].
