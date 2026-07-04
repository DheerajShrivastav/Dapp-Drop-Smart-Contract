# Test Coverage & Build — Web3Campaigns

> As of `feature/phase2-signature-verification` (forked from `dev` post-v0.3 merge).

## Toolchain (now set up)

Foundry **1.7.1** installed (`~/.foundry/bin` — `export PATH="$HOME/.foundry/bin:$PATH"`). Submodules initialized (`lib/forge-std`, `lib/openzeppelin-contracts` + its sub-submodules). `foundry.toml`: solc `0.8.31`, evm `cancun`, `viaIR=true`, optimizer (runs=200), remapping `@openzeppelin/=lib/openzeppelin-contracts/`.

To build/run from a clean clone: `git submodule update --init --recursive` → `forge build` → `forge test`.

## Test suites (62 passing, 5 suites)

- `test/CampaignStorage.t.sol` (11) — lifecycle/access/batch/withdrawETH; batch task verification now via `batchVerifyTaskCompletionWithSignatures`.
- `test/StageAFixes.t.sol` (14) — ONCHAIN_HOLD 64-byte happy/bad-length/insufficient-balance, ONCHAIN_TX self-revert + signer-verify, ONCHAIN_HOLD signature-cannot-verify, signed-attestation expiry/non-signer/replay/reverification, flagAccount block/clear/only-moderator, createCampaign-paused.
- `test/MerkleSettlement.t.sol` (14) — ERC20 escrow + Merkle settlement: single/two-leaf claims, double-claim, bad proof/amount, non-allocated account, pre-root, not-ended, insufficient-escrow, paused, funding-not-configured, funding-accumulates, root-timing, grace-gated sweep + double-sweep.
- `test/NFTSettlement.t.sol` (10) — ERC721/ERC1155 claims, double-claim, bad proof, pre-root, ERC1155 over-allocation, **cross-campaign drain guard**, deposit/custody, grace-gated sweep. Includes minimal mintable `MockERC721`/`MockERC1155`.
- `test/SignatureVerification.t.sol` (13) — happy path + participant-count invariant, anyone-can-submit, false-attestation-doesn't-count, campaign-status guards, task-not-found, **signer rotation/revocation**, **domain isolation** (signature bound to a different `verifyingContract` fails), **batch atomicity** (one bad signature reverts the whole batch, no partial state), array-length/empty-batch reverts.

Claim tests build real Merkle proofs via Solidity helpers matching the OZ StandardMerkleTree + sorted-pair convention. Signature tests build real EIP-712 digests/signatures via `vm.sign` against a locally-computed domain separator mirroring `CampaignStorage`'s `TASK_ATTESTATION_TYPEHASH`.

## Still UNTESTED / gaps
- `completeTask` social self-assertion timing/anti-spam (30s) edge cases, `MAX_PARTICIPANTS_LIMIT`, batch length/size reverts.
- No fuzz/invariant tests yet (candidates: escrow solvency invariant `sum(ERC20 claims) <= escrowed`; NFT claimed leaves never exceed deposited inventory; attestation version only ever increases by 1 per accepted call).
- Multi-leaf NFT proofs (current NFT tests use single-leaf roots); add a 2+ leaf NFT tree test.

## Known issues
- CI (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, `forge test -vvv` under `FOUNDRY_PROFILE=ci`, but `foundry.toml` defines no `[profile.ci]` (falls back to default). Cosmetic.
- `actions/checkout@v4` in CI triggers a Node 20 deprecation warning — non-blocking, worth bumping to v5.
- `block.timestamp` comparison lints (rate-limit/anti-spam) — informational.
- **Contract size**: `Web3Campaigns` runtime is 21.1KB against the 24.576KB EIP-170 limit — 3.4KB headroom. Check `forge build --sizes` before adding more logic to the entrypoint contract; consider splitting a new logic contract into the diamond if this gets tight.

## Deploy
`script/DeployWeb3Campaigns.s.sol` — `new Web3Campaigns()`, no constructor args/secrets. Makefile `deploy-sepolia` uses `--account` keystore. Related: [ARCHITECTURE.md](ARCHITECTURE.md), [REWARD_SYSTEM.md](REWARD_SYSTEM.md), [TASK_VERIFICATION.md](TASK_VERIFICATION.md).
