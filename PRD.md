# Dapp-Drop Platform PRD — Frontend Web App & Backend Services

> Product Requirements Document for the application layer that sits on top of the already-built and tested `Web3Campaigns` contract suite (v0.5.0, `dev` branch + `feature/permissionless-lifecycle`). The contract layer is **fixed** — this document defines the product around it, not changes to it. Contract behavior referenced here is verified against [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/REWARD_SYSTEM.md](docs/REWARD_SYSTEM.md), [docs/TASK_VERIFICATION.md](docs/TASK_VERIFICATION.md), and [docs/HUMANITY_GATING.md](docs/HUMANITY_GATING.md).

**Status:** Draft v1 · 2026-07-19
**Decisions locked for this PRD** (founder, 2026-07-19):
- **Chain:** testnet (Sepolia, where the contracts already deploy) for development/beta; a single EVM **L2 for production launch** (which L2 is still open — see §6).
- **MVP scope:** full platform — all three settlement modes (Merkle ERC20, on-chain tiered ERC20, Merkle NFT), host wizard, discovery, sponsored claims, keeper, notifications — phased internally but all in the launch scope.
- **Sponsored (gasless) claims:** platform-paid, **gated** — only for Humanity-verified participants, bounded by per-campaign and global relayer budget caps.
- **Sybil gating:** **per-campaign host choice** ("Humanity-verified only" toggle at campaign creation), per the design in [docs/HUMANITY_GATING.md](docs/HUMANITY_GATING.md).

---

## 1. Product Overview

### 1.1 What we're building

Dapp-Drop is a Galxe/Zealy-style quest-and-reward platform: projects ("hosts") create marketing campaigns composed of tasks (follow on X, join Discord, hold a token, make an on-chain tx, verify humanity); participants complete tasks to qualify; rewards (ERC20 tokens or NFTs) are escrowed on-chain up front and settled after the campaign ends — via Merkle-proof claims or fully on-chain tiered payouts.

The contract layer already provides trustless escrow, lifecycle enforcement, EIP-712 attestation verification, Merkle settlement with a 24-hour dispute window, tiered on-chain settlement, sponsored-claim entrypoints, protocol fees, and a 30-day unclaimed-funds grace period. **Everything user-facing — discovery, task UX, verification orchestration, allocation building, gas sponsorship, automation, analytics — is the product defined here.**

### 1.2 Product goals

1. A host can take a campaign from idea to live in under 15 minutes without understanding Merkle trees, dispute windows, or module pinning.
2. A participant can join a campaign, complete tasks, and claim a reward without ever paying gas (when sponsorship applies) and without reading a single contract address.
3. Campaigns always progress on schedule — the keeper guarantees `endCampaign` fires at `endTime` regardless of host activity.
4. Sybil accounts are excluded from reward allocations on gated campaigns with zero per-participant host effort.
5. The platform never holds custody of reward funds — the contract escrow does. The backend's power is limited to what the contract trust model already grants it (allocation contents, attestation signing, sponsorship decisions).

### 1.3 Personas

**Host / Campaign Creator** — a marketing or growth lead at a Web3 project. Comfortable with a wallet; not necessarily a developer. Wants: audience growth, provable engagement, control over budget, no support burden from claim problems. Fears: paying sybils, funds getting stuck, looking incompetent in front of their community. Note: `HOST_ROLE` is currently self-serve (`grantHostRole` is intentionally open on-chain), so the product treats "becoming a host" as a signup flow, not a sales gate. A staked/curated hosting tier is a known future item.

**Participant / Claimer** — an airdrop hunter or genuine community member. Ranges from power users running many wallets (the sybil problem) to first-timers who barely know what gas is. Wants: clear task lists, instant feedback on completion, rewards without gas friction. Fears: doing tasks and getting nothing, scams, connecting a wallet to a malicious site.

**Platform Admin / Operator** — internal. Operates the signer key, keeper, relayer, and treasury; responds to disputes raised during the 24h root window; moderates abusive campaigns/accounts (holds `MODERATOR_ROLE` → `flagAccount`, `EMERGENCY_ADMIN` → pause). Needs: operational dashboards, alerting, key-rotation runbooks, spend controls on the relayer.

### 1.4 Explicitly out of scope for this PRD

- Any smart-contract change (including the deferred `IHumanityModule`).
- The staked/curated host tier (future).
- Mobile native apps (responsive web only at launch).
- Multichain deployment (single L2 at launch; architecture should not preclude it).
- Off-chain/"informational" rewards beyond displaying them (contract treats them as informational only).

---

## 2. Frontend Requirements

Single responsive web app, two main surfaces (participant-facing and host dashboard) plus an internal admin surface (§2.7). All reads come from the backend indexer (§3.5), never live multicall-the-world from the browser; writes go through the connected wallet (or the relayer for sponsored paths).

### 2.1 Wallet connection

- **FR-W1** Support injected wallets (MetaMask, Rabby), WalletConnect v2, and Coinbase Wallet at minimum.
- **FR-W2** Wrong-network detection with a one-click switch/add-chain prompt for the target chain (Sepolia in dev, launch L2 in prod). All contract writes are disabled with an explanatory state while on the wrong chain.
- **FR-W3** Sign-In With Ethereum (SIWE, EIP-4361) establishes the backend session. Browsing and viewing campaigns requires **no wallet at all**; a wallet is required only to participate, claim, or host.
- **FR-W4** Session model: a SIWE session maps one wallet ⇄ one backend session. Linked off-chain accounts (X/Twitter, Discord) and Humanity verification status attach to the wallet, not the browser session.
- **FR-W5** Never request seed phrases or private keys anywhere in the product. Contract addresses shown in UI must link to the block explorer.

### 2.2 Campaign discovery (participant home)

Nothing on-chain supports browse/search — this is entirely frontend + indexer.

- **FR-D1** Browse view of Open campaigns: card grid with campaign name, host identity, reward summary (token + total pool, or NFT collection), time remaining, participant count vs. cap (when a cap is set), task count, and badges: settlement type, "Gasless claims", "Humanity-verified only".
- **FR-D2** Filters: reward type (ERC20 / NFT), settlement mode, status (Open / Ended–claimable / Closed), gated vs. open, ending-soon. Sort: newest, ending soon, largest reward pool, most participants. Full-text search over campaign title/description (off-chain metadata, §3.5).
- **FR-D3** Campaign detail page: full description, task list with per-task status for the connected wallet, reward structure explained in plain language per settlement mode (see §4.3 messaging), lifecycle timeline (opens/ends/claim-window states with real timestamps), host profile link, contract address + campaign ID with explorer links.
- **FR-D4** "My campaigns" view for participants: joined campaigns grouped by actionable state — *tasks remaining*, *awaiting results* (Ended, root not yet claimable), *claimable now*, *claimed*, *missed/expired*.
- **FR-D5** Campaign states must render from indexer data with ≤ 1 block-confirmation lag for lifecycle transitions (§4.2 sets the freshness NFR).

### 2.3 Task-completion UX (per task type)

The contract defines task *verification*; the product defines what a task *means* to a user. Each task in the creation wizard carries off-chain metadata (title, instructions, target URL/handle/server) stored by the backend and rendered here.

- **FR-T1 Off-chain social tasks (signed-attestation path)** — e.g. follow on X, join Discord:
  1. Participant connects the relevant social account via OAuth (once per account, reusable across campaigns).
  2. Participant performs the action (deep link out: "Open X → Follow @project").
  3. Participant clicks **Verify**. Backend checks via the platform API (§3.2), and on success signs the EIP-712 attestation.
  4. Submission to `verifyTaskCompletionWithSignature`: default is **backend-submitted** (the attestation flow already has the backend in the loop; submitting the tx too makes task completion fully gasless). Fallback: hand the signed attestation to the user to submit from their own wallet (must work if the relayer is down or budget-exhausted).
  5. UI states: not-started → action pending → verifying (async, poll) → verified ✓ / failed with a *specific* reason ("We couldn't find a follow from @their-handle — make sure the right account is connected") and a retry that respects verifier rate limits.
- **FR-T2 On-chain hold tasks (self-verified: `ONCHAIN_HOLD_ERC20` / `ONCHAIN_HOLD_ERC721`)** — participant calls `completeTask` from their own wallet; the contract checks the balance in-transaction. UI must: show the exact requirement ("Hold ≥ 100 XYZ at time of verification"), pre-check the balance off-chain and warn *before* the user pays gas for a doomed tx, then guide the wallet transaction. These are the only tasks that always cost the participant gas — label them so.
- **FR-T3 On-chain action tasks (`ONCHAIN_TX`, attestation path)** — "swap on X", "bridge to Y": backend verifies the qualifying transaction from indexed chain data, then follows the FR-T1 attestation flow. The wizard must capture machine-checkable criteria (target contract, method/event, min value, chain) — free-text-only on-chain tasks are not allowed, because the backend cannot verify what it cannot parse.
- **FR-T4 Humanity verification task** — one button: "Verify you're human", launching Humanity Protocol's OAuth (§3.6). On gated *tiered* campaigns this appears as a required task in the list (per [docs/HUMANITY_GATING.md](docs/HUMANITY_GATING.md) §3); on gated Merkle campaigns it appears as a prominent banner ("Verify by campaign end or you won't be included in rewards") since enforcement is silent tree-filtering. One OAuth per wallet, ever; verified status shows globally in the user's profile menu.
- **FR-T5 Required vs. optional tasks** are visually distinct, with the qualification rule stated per settlement mode (tiered campaigns: required tasks gate payout on-chain; Merkle campaigns: the host's allocation policy decides, and the UI must state the policy the host configured).
- **FR-T6 Participant-cap handling** — when a campaign has a cap: show remaining slots; if full, disable join-type actions with "This campaign is full" *before* a doomed transaction. The contract counts a participant at their first counted task completion, so the race (slot taken between UI check and tx) must be handled as a friendly error, not a raw revert string.

### 2.4 Claim flow

- **FR-C1** A campaign becomes claim-actionable in the UI only when the contract will actually accept the claim: status ≥ Ended **and** (for Merkle modes) a root is published **and** its 24h dispute window has elapsed. Before that, show the timeline state instead (see §4.3 for exact messaging states).
- **FR-C2 Merkle ERC20 claim**: UI fetches the wallet's leaf (amount) + proof from the backend (§3.3) and shows the exact allocation before claiming. Two buttons, one outcome:
  - **Claim gasless (default when eligible)** — POST to the relayer (§3.4); UI shows queued → submitted (tx hash) → confirmed. Eligibility: Humanity-verified wallet + campaign/global relayer budget not exhausted; when ineligible, the button explains why and offers self-claim.
  - **Claim with my wallet** — the user submits `claimERC20(amount, proof)` themselves. Always available to anyone in the tree; sponsorship is a courtesy, never a gate on the reward itself.
- **FR-C3 Merkle NFT claim**: same pattern via the campaign's pinned `NFTSettlementModule` (`claimNFT(standard, token, tokenId, amount, proof)`). The frontend must call the **per-campaign pinned module address** from the indexer — never a hardcoded module address, since the global default is admin-rotatable.
- **FR-C4 Tiered (on-chain) claim**: `OnChainRewardModule.claimReward` on the campaign's pinned module. No proof needed; UI shows computed rank/score and the projected tier payout from indexed module state, with a disclaimer that final rank is set at campaign end. No dispute window applies — claimable as soon as the host finalizes per the tiered flow.
- **FR-C5 Wallet-mismatch guard**: allocations bind to the earning wallet; funds always go to the allocated account regardless of submitter. If the connected wallet ≠ an allocated wallet, say so plainly ("This wallet has no allocation in this campaign — you participated with 0x1234…") rather than showing a generic empty state.
- **FR-C6 Post-close claims**: claims keep working after `Closed` until the host actually sweeps (30-day minimum grace). UI shows a countdown ("Claim within N days — unclaimed rewards return to the host after {date}") and flips to a terminal "expired, swept" state only after an actual sweep event, not merely after day 30.
- **FR-C7** Already-claimed, swept, dispute-window-active, and invalid-proof contract reverts each map to a specific human-readable message; no raw revert strings surface to users.

### 2.5 Campaign creation wizard (host)

A stepped wizard driving Draft-state contract calls plus off-chain metadata. Principle: **the host signs a small number of well-explained transactions, and nothing goes live until they explicitly open it** — matching the contract's deliberate host-only `openCampaign` gate.

- **FR-H1 Step 0 — Become a host**: first-time hosts get a one-time "enable hosting" transaction (`grantHostRole` self-grant — self-serve by design today). Frame as account setup, not privilege escalation.
- **FR-H2 Step 1 — Basics** (off-chain + `createCampaign`): title, description, brand imagery, category/tags; start/end times; optional participant cap (`setMaxParticipants`, 0 = unlimited, ceiling 100,000); Humanity-gating toggle (**the** per-campaign sybil decision — copy must state exactly what it does per settlement mode: tree filtering for Merkle, required task for tiered). Produces the `createCampaign` transaction; off-chain metadata is keyed to the resulting campaign ID.
- **FR-H3 Step 2 — Tasks** (≤ 20 per campaign, contract cap): task-type picker with per-type forms capturing both verification parameters (handle, server ID, token address + min balance, on-chain criteria per FR-T3) and display metadata. Required/optional flag per task, with an inline explanation of what "required" enforces under the selected settlement mode.
- **FR-H4 Step 3 — Rewards** (mode-specific):
  - *Merkle ERC20*: reward token address (contract-side EOA guard exists; frontend pre-validates it's an ERC20 and warns on fee-on-transfer tokens that escrow credits the amount actually received), total budget, and the **allocation policy** the backend will apply at tree-build time (equal split among qualifiers / proportional to task points / fixed per-task amounts / CSV upload after end). Policy is off-chain but committed in campaign metadata so participants see the rules up front. Calls `configureERC20Reward`.
  - *Tiered ERC20*: RANK_TIERED or SCORE_TIERED, tier boundaries + amounts, with a live payout-preview table. Configures via the tiered settlement path (pins the reward module on first adoption — invisible to the host, but the dashboard displays the pinned module address for transparency).
  - *NFT*: collection address(es), ERC721 token IDs / ERC1155 id+amounts to escrow (≤ 100 per deposit call; wizard auto-batches larger sets), and the allocation policy. Deposits pin the campaign's `NFTSettlementModule`.
- **FR-H5 Step 4 — Fund**: for ERC20, `approve` + `fundCampaignERC20` with the protocol fee (from the live `FeeModule` rate) itemized *before* signing: gross debit, fee to treasury, net escrowed. For NFTs, funding is the deposit step in FR-H4. Show escrow balance confirmation after.
- **FR-H6 Step 5 — Review & Open**: full summary; a "go-live checklist" hard-blocks `openCampaign` in the UI until tasks exist, rewards are configured **and funded/deposited**, and times are sane. (The contract permits opening an unfunded campaign — the product must not.) Opening is an explicit, separate host action; a completed Draft can sit indefinitely.
- **FR-H7 Draft editing**: full reconfiguration while Draft; the wizard is re-enterable. Post-Open, on-chain config is frozen — only cosmetic off-chain metadata (description text, imagery) remains editable, with an edit-history note for participant trust.

### 2.6 Host dashboard

- **FR-M1 Campaign list** with lifecycle state, funding status, participant count (and cap), tasks-completed stats, time to next transition, and pending required actions surfaced as a to-do ("Publish allocations", "Root claimable in 14h", "Sweep available in 3 days").
- **FR-M2 Live monitoring per campaign**: participants over time, per-task completion/failure rates, verification-failure reasons (host-visible aggregate), qualified-participant count under the campaign's policy, projected per-wallet payout, claim rate after settlement. Export CSV.
- **FR-M3 Allocation & settlement flow (Merkle campaigns)** — the most operationally sensitive host surface:
  1. After `Ended` (host-triggered or keeper), the dashboard prompts "Review & publish allocations".
  2. Backend computes the allocation from the committed policy (with sybil filtering applied on gated campaigns) and presents a **reviewable table** (wallet, tasks, points, amount; downloadable) plus totals reconciled against escrow.
  3. Host approves → backend builds the tree (§3.3) → host signs `setERC20MerkleRoot` (or `setNFTMerkleRoot` on the pinned module).
  4. Dashboard then shows the **24h dispute-window countdown**, explains that republishing a *different* root restarts it (same-root republish does not — contract's anti-self-griefing rule), and links the public allocation view participants can check during the window.
  5. Corrections during the window: edit → republish flow with an explicit "this restarts the 24h window" warning.
- **FR-M4 Close & sweep**: `closeCampaign` (host-only) presented as "finalize" with plain-language consequences: freezes the root permanently and starts the 30-day clock; claims continue meanwhile. After grace, "Withdraw unclaimed" runs `withdrawUnclaimedERC20` / `withdrawUnclaimedERC721` / `withdrawUnclaimedERC1155` with a pre-sweep warning that ERC20 sweep ends all further claims for that campaign (`AlreadySwept`). Recommend-but-don't-force sweeping promptly.
- **FR-M5 Cancel**: shown only when the contract will accept it — status Draft/Open/Ended **and** zero counted participants **and** no ERC20/NFT settlement committed. Copy: "Cancel and refund instantly. Available only because no one has engaged and no rewards have been committed." When blocked, explain *why* and point to the end→close→sweep path instead. ERC20 refunds are immediate; escrowed NFTs are reclaimed via the withdraw functions, immediately callable once Cancelled.
- **FR-M6 Tiered campaigns**: settlement dashboard shows on-chain rank/score leaderboards, tier fill, and claim progress; no root/dispute machinery applies and the UI must not show any.

### 2.7 Admin console (internal)

- **FR-A1** Global campaign/host/participant search; per-campaign operational view.
- **FR-A2** Relayer spend dashboard: per-campaign and global budget consumption, failure rates, gas-price posture; budget override controls.
- **FR-A3** Keeper health: upcoming/overdue `endCampaign` executions, retry state, alert status.
- **FR-A4** Moderation: `flagAccount` (MODERATOR_ROLE) with reason logging; hide campaign from discovery (off-chain, does not touch escrow — copy must be honest that a hidden campaign's contract functions still work); emergency pause/unpause (EMERGENCY_ADMIN) behind a two-person confirmation UX.
- **FR-A5** Signer/treasury operations: signer-key health and rotation runbook links, dispute-window escalation queue (reports filed against published roots), treasury/fee monitoring.

---

## 3. Backend Requirements

Services (deployable as one codebase, separable processes): **Indexer**, **Verification & Attestation service** (the EIP-712 signer), **Allocation/Merkle pipeline**, **Relayer** (sponsored claims + backend-submitted attestations), **Keeper**, **Notification service**, plus the API gateway serving the frontend. Postgres as the system of record for off-chain data; the chain as the system of record for everything the contract owns.

### 3.1 API gateway & data model

- **BR-G1** REST/JSON (or tRPC) API consumed by the frontend; SIWE-session auth; per-wallet and per-IP rate limits; strict input validation at every boundary.
- **BR-G2** Core entities: `Campaign` (on-chain mirror + off-chain metadata + allocation policy + gating flag), `Task` (verification params + display metadata), `Wallet` (SIWE identity, linked social accounts, humanity status + timestamp, flags), `TaskCompletion` (per wallet×task: status, evidence, attestation record, tx hash), `Allocation`/`MerkleTree` (versioned per publish), `SponsoredClaim` (queue + outcome), `KeeperJob`, `Notification`.
- **BR-G3** Social-account linking via OAuth (X, Discord at launch), storing the provider account ID (not just handle) to survive renames; one social account links to at most one wallet at a time on gated campaigns (an anti-sybil signal in itself — see §3.6).

### 3.2 Verification & Attestation service (EIP-712 signer)

The `SIGNER_ROLE` key is the platform's most sensitive secret after the deployer/admin keys.

- **BR-V1** Pluggable per-task-type verifiers: X follow (API lookup), Discord membership (bot/guild API), `ONCHAIN_TX` (indexed-chain query against the FR-T3 criteria). Each verifier returns pass/fail + machine-readable reason + evidence snapshot persisted to `TaskCompletion`.
- **BR-V2** On pass, sign the EIP-712 attestation exactly per [docs/TASK_VERIFICATION.md](docs/TASK_VERIFICATION.md): domain `Web3Campaigns`/`1`, the documented typehash/leaf layout, correct per-task **version counter** (the replay/update mechanism — the signer must read the current on-chain version to sign an accepted attestation), and a short signature deadline (target ≤ 1h) to bound stolen-attestation shelf life.
- **BR-V3** Submission: default backend-submitted via the relayer (batchable through `batchVerifyTaskCompletionWithSignatures`, ≤ 50/batch); attestation also returned to the client for self-submission fallback. Handle the participant-cap race: a `MaxParticipantsReached`-style revert on a new participant's first completion is a terminal-for-now outcome that must surface back through the UI, not retry forever.
- **BR-V4** Key management: signer key in a KMS/HSM (never in app memory as plaintext env), signing via KMS API. Rotation runbook: admin grants new `SIGNER_ROLE`, service switches, admin revokes old — zero-downtime, documented, drilled. All signatures logged (who/what/when/evidence) to an append-only audit log.
- **BR-V5** Abuse controls: per-wallet verification rate limits; verifiers re-check (not trust cached success) on re-verification; `completed=false` re-attestations (version-counter update path) supported for revocations (§3.6) and moderator reversals.
- **BR-V6** External-API resilience: X/Discord API failures degrade to "verification temporarily unavailable" with retry-after — never a false pass, never a silent queue-drop.

### 3.3 Allocation & Merkle pipeline

- **BR-M1** Trigger: campaign reaches `Ended` (keeper event, §3.5). Pipeline: gather qualifying completions → apply the campaign's committed allocation policy → **apply sybil filtering for gated campaigns** (§3.6 — exclude wallets without current Humanity verification at build time) → produce the allocation set → reconcile totals against on-chain escrow (hard-fail on over-allocation; surface under-allocation to the host as intentional-or-not).
- **BR-M2** Tree build with `@openzeppelin/merkle-tree` using the exact leaf encodings in [docs/REWARD_SYSTEM.md](docs/REWARD_SYSTEM.md) (ERC20 and NFT encodings differ; NFT roots go to the campaign's **pinned** module). Trees and leaves are versioned and persisted permanently — proofs must be servable for years.
- **BR-M3** Host-in-the-loop publish (FR-M3): pipeline output is a proposal; the host reviews and signs the root-setting transaction themselves (keeps allocation authority with the host, matching the contract trust model where the root-setter is the host).
- **BR-M4** Proof API: `GET /campaigns/:id/allocation/:wallet` → leaf + proof + claimable-at timestamp (root publish time + 24h) + claim status. Public read; also powers the dispute-window public allocation view (full table downloadable — transparency is the dispute window's entire purpose).
- **BR-M5** Republish handling: a changed root during the window supersedes the prior tree version and restarts the 24h clock; old proofs are marked stale and the proof API serves only the active version. Notification fan-out on every (re)publish (§3.7).

### 3.4 Sponsored-claim relayer

- **BR-R1** Endpoints: sponsored claim requests (Merkle ERC20 via `claimERC20For`, NFT via `claimNFTFor` on the pinned module, tiered via `claimRewardFor`) and internal attestation submission (§3.2). Funds always route to the allocated account by contract design — the relayer can never redirect a reward, only pay gas.
- **BR-R2** Gating (locked decision): sponsor only when (a) the claiming wallet is Humanity-verified (courtesy re-check per [docs/HUMANITY_GATING.md](docs/HUMANITY_GATING.md) — enforcement lives in tree filtering, not here), (b) the per-campaign sponsorship budget has headroom, (c) the global daily budget has headroom, (d) the wallet is not moderation-flagged. Declines return a reason so the UI can route to self-claim.
- **BR-R3** Pre-simulate every sponsored tx (`eth_call`) and refuse to pay gas for a reverting claim (dispute window active, already claimed, bad proof version). Queue with per-wallet dedupe; nonce management for concurrent submission; stuck-tx replacement policy; idempotent request handling.
- **BR-R4** Treasury ops: dedicated hot wallet, low-balance alerting, auto-top-up from a warm wallet within limits; every sponsored tx logged with cost and attributed to a campaign budget line. Kill switch halts sponsorship globally without touching self-claims.

### 3.5 Indexer / read layer

- **BR-I1** Index all contract events from `Web3Campaigns` and all satellite modules (per-campaign pinned `OnChainRewardModule` and `NFTSettlementModule` instances, `FeeModule`) — lifecycle transitions, task completions/verifications, funding + fee events, root publishes (with dispute-window deadlines), claims, sweeps, module pins, role grants, pauses. Maintain per-campaign materialized state so the frontend never derives lifecycle from raw events.
- **BR-I2** Chain-reorg safety: track confirmation depth; expose a `finalized` flag; UI treats shallow data as provisional where it matters (claims, funding totals).
- **BR-I3** Freshness: indexed state visible to the API ≤ 5s after block inclusion (p95) on the target L2. WebSocket/SSE push to the frontend for the states users actively watch (verification pending, claim pending, dispute countdown).
- **BR-I4** The indexer is the source for: discovery listings, campaign detail, per-wallet status, host analytics, keeper scheduling, and notification triggers. Any *value-bearing decision* (allocation totals, sweep availability) re-verifies against a direct RPC read at execution time rather than trusting the cache.

### 3.6 Sybil-resistance / identity pipeline

Per [docs/HUMANITY_GATING.md](docs/HUMANITY_GATING.md) — off-chain enforcement at the three control points the backend already owns. No contract changes.

- **BR-S1 Humanity OAuth flow**: "Verify humanity" → Humanity Protocol OAuth → callback verifies via their SDK → persist `wallet → verified (timestamp)`. In the same request, for any active humanity-gated **tiered** campaign the wallet participates in, sign + submit the `HUMANITY_VERIFICATION` required-task attestation. Fully automated; one OAuth per wallet ever.
- **BR-S2 Enforcement point 1 — tree filtering (primary)**: at Merkle build for gated campaigns, re-query stored status per candidate wallet; unverified wallets are omitted (no leaf ⇒ mathematically cannot claim). This is the load-bearing enforcement.
- **BR-S3 Enforcement point 2 — sponsorship gating (courtesy)**: §3.4 BR-R2. Never presented as enforcement (in-tree wallets can always self-claim).
- **BR-S4 Enforcement point 3 — tiered required task**: BR-S1's attestation against the `HUMANITY_VERIFICATION` task; the contract's required-task qualification check does the enforcing on-chain.
- **BR-S5 Revocation**: on a Humanity revocation signal — exclude from all future tree builds; for active gated tiered campaigns, sign a `completed=false` re-attestation to disqualify. Accepted limitation (documented in the host-facing copy): revocation after a root is published does not claw back that allocation.
- **BR-S6 Supplementary risk scoring (platform-level, all campaigns)**: independent of the host toggle, maintain a per-wallet risk score from cheap signals — social-account reuse across wallets, wallet funding provenance/age, verification-attempt velocity, shared IP/device clusters. Consumed by: moderator review queue (feeding `flagAccount`, which the contract enforces in `completeTask`), sponsorship gating, and a host-visible *advisory* flag on allocation review (FR-M3) — hosts decide whether to exclude advisory-flagged wallets; the platform never silently alters a non-gated campaign's allocation.
- **BR-S7 Future-proofing**: isolate identity checks behind an internal `IdentityService` interface so the deferred on-chain `IHumanityModule` (when Humanity ships a registry) slots in without reworking the pipeline.

### 3.7 Keeper / automation service

- **BR-K1** Primary job: call the permissionless `endCampaign` for every Open campaign at `endTime`. Schedule from indexed state; execute with retry + escalating gas; verify success by observing the `Ended` event, not just tx acceptance. Target: ≥ 99.9% of campaigns ended within 5 minutes of `endTime`.
- **BR-K2** The keeper is a **liveness convenience, not a liveness requirement** — anyone can call `endCampaign` after `endTime`. If a campaign is > 30 min overdue, page the on-call; the frontend may additionally expose an "End this campaign" button to any user on overdue campaigns as a decentralized fallback.
- **BR-K3** Secondary scheduled duties (notifications/prompts, not transactions — these are host-only calls the platform cannot and must not make): remind hosts to publish allocations after `Ended`, to close after high claim-rate, and that sweep is available after grace; flip UI states at dispute-window expiry and grace expiry.
- **BR-K4** Keeper wallet: separate low-value hot wallet, only ever calls `endCampaign`; balance alerts; all executions logged.

### 3.8 Notification / webhook system

- **BR-N1** Channels at launch: in-app notification center + email (wallet-linked, optional); host-configurable outbound **webhooks** (HMAC-signed, with retries/backoff and a redelivery log) for teams integrating their own tooling.
- **BR-N2** Participant events: verification result, campaign ended, allocations published ("claims open in 24h"), claims open, sponsored claim confirmed, grace-period expiry warnings (7d / 48h before sweep-eligible date for unclaimed allocations).
- **BR-N3** Host events: campaign opened/ended, participant-cap reached, funding/fee receipts, allocation proposal ready, dispute-window started/elapsed, dispute report filed against their root, claim-rate milestones, sweep available.
- **BR-N4** Admin/ops alerts (separate pager path): keeper overdue, relayer budget/balance thresholds, signer-service error spikes, dispute reports, contract paused.

---

## 4. Non-Functional Requirements

### 4.1 Chain & environment

- **NFR-1** Dev/beta on Sepolia (existing deploy target, chain 11155111). Production on a single EVM L2 — **specific L2 is an open decision (§6.1)**; all services take chain ID + contract addresses as configuration, and nothing may hardcode a chain.
- **NFR-2** Address book (entrypoint + module addresses + deploy block) ships as versioned configuration derived from the [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) output; per-campaign pinned module addresses always come from chain state via the indexer, never from static config.
- **NFR-3** RPC redundancy: two independent providers with health-checked failover for every service that reads or writes chain state.

### 4.2 Performance & availability

- **NFR-4** Discovery and campaign-detail p95 < 500ms from the indexer cache; no user-facing page blocks on a live RPC call.
- **NFR-5** Indexer freshness ≤ 5s p95 (BR-I3); verification round-trip (click Verify → result) p95 < 15s for social tasks.
- **NFR-6** Availability targets: read path 99.9%; signer + relayer 99.5% — with the explicit degradation story that self-claim and self-submission paths keep users unblocked when platform services are down (a core resilience property this architecture must preserve).
- **NFR-7** Load assumption for launch sizing: campaigns up to the 100,000-participant contract ceiling; claim-open moments are thundering herds (allocation notifications fan out at window expiry) — proof API and relayer queue must be sized and load-tested for a 100k-allocation campaign going claimable at one instant.

### 4.3 Gas & UX tradeoffs, and lifecycle messaging

- **NFR-8** Gas posture on the target L2: sponsored claims are the default happy path for verified users; self-claim always works. Every gas-costing action shows an estimate before signature. On-chain hold tasks (FR-T2) are labeled as the gas-costing exception among tasks.
- **NFR-9** The 24h dispute window and the 30-day grace period must be rendered as **named product states with honest copy**, everywhere a campaign's status is shown. Canonical participant-facing state ladder: *Open — complete tasks* → *Ended — results being finalized* → *Allocations published — claims open at {timestamp}* (with "why the wait": community review window; link to the public allocation table) → *Claims open* → *Closed — claim by {sweep-eligible date}* → *Swept — claiming ended*. A root republish resets to the "claims open at" state with an explicit "allocations were updated" note.
- **NFR-10** Every contract revert reachable through the UI maps to a specific, actionable message (already-claimed, dispute window active, swept, campaign full, not-in-tree, wrong status, unverified attestation version). A generic "transaction failed" is a defect.

### 4.4 Lifecycle edge cases (each requires explicit handling)

- **NFR-11** *Host abandons after Open*: keeper still ends it; participants can still self-submit attestations and (for tiered) claim on-chain. For an abandoned **Merkle** campaign, the contract now provides a fallback: after `endTime + 14 days` (`SETTLEMENT_FALLBACK_DELAY`) with no root ever published, the platform's `SETTLER_ROLE` may publish the root itself (and subsequently close), with the 24h dispute window applying unchanged and the host retaining override authority throughout. Product requirements: between `Ended` and day 14 the UI shows "reward publication overdue — the host has not finalized allocations"; the backend allocation pipeline (§3.3) must be able to run and publish without host approval in fallback mode; participants are notified when a fallback root is published; the settler key is an admin-console operation (§2.7) with audit logging.
- **NFR-12** *Zero-participant campaign ended by keeper*: host dashboard routes to `cancelCampaign` for the instant refund (contract accepts Ended with zero participants + no settlement committed) rather than the pointless close-and-wait-30-days path.
- **NFR-13** *Cancel blocked*: FR-M5's explanatory copy — never a dead button.
- **NFR-14** *Republished root while a claim is in flight*: relayer pre-simulation catches the stale proof; UI refreshes to the new window countdown with the "allocations updated" note.
- **NFR-15** *Sweep vs. late claimer race*: after the grace date, both host sweep and participant claims remain valid until the sweep lands; UI urgency messaging (FR-C6, BR-N2 warnings) is the mitigation; a claim that loses the race gets the specific swept message.
- **NFR-16** *Contract paused*: banner across all pages; writes disabled with an honest status; ops alert fires (BR-N4).
- **NFR-17** *Fee-on-transfer reward token*: wizard warns; escrowed (net) amount is what the dashboard and allocation reconciliation display — never the nominal funding amount.
- **NFR-18** *Signature-verification window*: attestation submission works while Open **or** Ended (contract rule) — a verification passed near `endTime` still lands; but pipeline runs (BR-M1) must define an attestation-settlement cutoff before tree build so late attestations don't miss inclusion silently (surface any post-build completions to the host on the review screen).

### 4.5 Security & compliance

- **NFR-19** Key inventory & handling: admin/deployer (cold, multisig strongly recommended — see §6.5), signer (KMS, rotation drill per BR-V4), relayer + keeper hot wallets (low-balance, scoped, monitored). No secrets in code or prompts (per repo CLAUDE.md).
- **NFR-20** Standard web hardening: OAuth state/PKCE, CSRF protection, SIWE nonce handling, per-endpoint rate limits, webhook HMAC signing, append-only audit logs on every signing and every sponsorship decision.
- **NFR-21** Frontend must never construct allocation or attestation data client-side as an input to anything trust-bearing; the client is display + signature-collection only.
- **NFR-22** Backend penetration test + an application-layer security review (the trust boundaries here — signer, relayer, allocation pipeline — are exactly the ones [docs/SECURITY_FINDINGS.md](docs/SECURITY_FINDINGS.md) assumes hold) before mainnet-L2 launch.

---

## 5. Phasing (all within the committed full-platform MVP)

| Phase | Scope | Exit criterion |
|---|---|---|
| **P0 — Foundations** | Indexer + API + wallet/SIWE + read-only discovery & campaign detail (Sepolia) | A contract-created campaign renders correctly end-to-end from indexed data |
| **P1 — Merkle ERC20 loop** | Creation wizard (ERC20 Merkle), social + on-chain-hold tasks, signer service, allocation pipeline + host review, self-claim, keeper | One real campaign runs create→open→tasks→end(keeper)→root→dispute window→self-claim on Sepolia |
| **P2 — Gasless + identity** | Humanity OAuth + gating (all 3 enforcement points), relayer with budget gating, sponsored claims, notifications | Gated campaign settles with tree filtering; sponsored claim succeeds & declines correctly |
| **P3 — Full settlement surface** | Tiered campaigns (wizard + leaderboards + `claimReward`), NFT campaigns (deposit wizard + module claims), host analytics, webhooks, admin console | All three settlement modes complete a full lifecycle in beta |
| **P4 — L2 launch** | Chain finalized (§6.1), production deploy per [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), load test (NFR-7), pen test (NFR-22), runbooks drilled | Public launch |

---

## 6. Open Questions & Decisions Still Needed

Explicitly *not* assumed in this PRD; each blocks the phase noted.

1. **Which L2?** (blocks P4; influences P0 tooling). Candidates: Base (distribution, Coinbase wallet reach), Arbitrum (DeFi depth), Optimism. Decision inputs: where target hosts' communities already are, sequencer-fee profile for 100k-claim campaigns, ecosystem grant availability.
2. **Protocol fee level & activation.** `FeeModule` supports a flat bps fee, currently disable-able (`address(0)`). Launch with fees on? At what bps? Fee-free promotional window? (Blocks P1 wizard copy — FR-H5 itemization — and revenue model.)
3. **Allocation-policy set at launch.** Which policies does the wizard commit to in v1 (equal-split / points-proportional / per-task-fixed / CSV upload)? CSV upload gives hosts arbitrary allocations — the contract trust model already assumes host allocation authority, but a *product* stance on transparency (must the policy be public before Open?) is needed. (Blocks P1 wizard + pipeline.)
4. **Dispute handling process.** The 24h window exists on-chain; who reviews an in-app dispute report, and what actions can the platform actually take (pressure the host to republish; `flagAccount`; delist from discovery — it cannot alter a root)? Define the SLA and the public policy page. (Blocks P2 launch messaging.)
5. **Admin key custody.** Multisig for `DEFAULT_ADMIN_ROLE` (module rotation, signer rotation, treasury) before mainnet-L2 — which multisig, which signers, what threshold? (Blocks P4; NFR-19.)
6. **Relayer budget defaults.** Global daily cap, per-campaign default cap, and whether hosts can *purchase* additional sponsored-claim budget (a revenue lever; interacts with Q2). (Blocks P2 configuration.)
7. **Email & comms scope.** Is email collection (optional, wallet-linked) acceptable at launch given the privacy posture, or in-app + webhooks only? (Blocks P2 notifications.)
8. ~~**Abandoned-Merkle-campaign policy.**~~ **Resolved (2026-07-19):** the contract now has a `SETTLER_ROLE` fallback — after `endTime + 14 days` with no root published, the platform can publish the allocation root (dispute window unchanged, host override retained) and later close. Remaining product decision: which allocation policy the fallback applies when the host committed one vs. didn't (default: the policy committed at campaign creation; equal-split if none) — needs ToS language. (Blocks P1 copy, P4 ToS.)
9. **Discovery curation.** Self-serve hosting + open `grantHostRole` means scam campaigns *will* be created. Launch stance: allowlist-only discovery (everything else reachable by direct link only) vs. open listing + reactive moderation? (Blocks P0/P1 discovery ranking; interacts with the future staked-host tier.)
10. **Off-chain "informational" rewards.** Contract treats them as informational only — does the product display/support them at all in v1, or drop them from the wizard? (Blocks P1 wizard scope.)

---

## 7. Success Metrics (v1)

- **Activation:** ≥ 60% of hosts who start the wizard reach a funded, opened campaign; median idea→Open < 15 min (Goal 1).
- **Participant funnel:** ≥ 70% of wallets that start a task list complete ≥ 1 verifiable task; verification-failure rate from *platform* causes (API errors, unclear instructions) < 5%.
- **Claims:** ≥ 80% of allocated wallets claim within the grace period; ≥ 90% of eligible claims routed gasless when sponsorship is available.
- **Automation:** 100% of campaigns reach `Ended` without host action when overdue (keeper SLA per BR-K1).
- **Integrity:** on gated campaigns, 0 unverified wallets present in any published tree (auditable from BR-S2 logs); dispute reports resolved within the defined SLA (Q4).
