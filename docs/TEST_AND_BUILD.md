# Test Coverage & Build — Web3Campaigns

> As of `feature/v0.3-security-hardening`.

## Toolchain (now set up)

Foundry **1.7.1** installed (`~/.foundry/bin` — `export PATH="$HOME/.foundry/bin:$PATH"`). Submodules initialized (`lib/forge-std`, `lib/openzeppelin-contracts` + its sub-submodules). `foundry.toml`: solc `0.8.31`, evm `cancun`, `viaIR=true`, optimizer (runs=200), remapping `@openzeppelin/=lib/openzeppelin-contracts/`.

To build/run from a clean clone: `git submodule update --init --recursive` → `forge build` → `forge test`.

## Test suites (35 passing)

- `test/CampaignStorage.t.sol` (11) — original lifecycle/access/batch/withdrawETH.
- `test/StageAFixes.t.sol` (10) — ONCHAIN_HOLD 64-byte happy/bad-length/insufficient-balance, ONCHAIN_TX self-revert + host-verify, ONCHAIN_HOLD host-cannot-verify, flagAccount block/clear/only-moderator, createCampaign-paused.
- `test/MerkleSettlement.t.sol` (14) — single/two-leaf claims, double-claim, bad proof/amount, non-allocated account, pre-root, not-ended, insufficient-escrow, paused, funding-not-configured, funding-accumulates, root-timing, grace-gated sweep + double-sweep.

Includes a Solidity Merkle helper (`_leaf`/`_hashPair`) matching the OZ StandardMerkleTree + sorted-pair convention, so claim tests build real proofs.

## Still UNTESTED / gaps
- Legacy NFT pool path (`claimReward`/`_processNFTReward`) — untested and slated for removal in B2; don't add coverage, replace it.
- `completeTask` social self-assertion timing/anti-spam (30s) edge cases, `MAX_PARTICIPANTS_LIMIT`, batch length/size reverts.
- No fuzz/invariant tests yet (candidate: escrow solvency invariant `sum(claims) <= escrowed`).

## Known issues
- Repo does **not** pass `forge fmt --check` (pre-existing formatting; new code matches local style). CI (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, `forge test -vvv` under `FOUNDRY_PROFILE=ci`, but `foundry.toml` defines no `[profile.ci]` (falls back to default). A repo-wide `forge fmt` pass is a separate cleanup decision.
- `block.timestamp` comparison lints (rate-limit/anti-spam) — informational.

## Deploy
`script/DeployWeb3Campaigns.s.sol` — `new Web3Campaigns()`, no constructor args/secrets. Makefile `deploy-sepolia` uses `--account` keystore. Related: [[ARCHITECTURE]], [[REWARD_SYSTEM]].
