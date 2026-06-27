# Test Coverage & Build — Web3Campaigns

## Test coverage (`test/CampaignStorage.t.sol`, contract `CampaignLifecycleTest`)

11 **unit** tests only — **no fuzz, no invariant tests.** Covers lifecycle + access basics: `createCampaign` (success + bad-time revert), `openCampaign` (success / not-host / already-open), `endCampaign` (success / time-not-ended), `grantHostRole`, `batchAddTasks`, `batchVerifyTaskCompletion`, `withdrawETH`.

### Major UNTESTED (highest-risk gaps)

- **ALL reward payout**: `claimReward`, `_processERC20Reward`, `_processNFTReward`, `_verifyAllTasksCompleted` — zero coverage. No FIXED/TIERED/FCFS, no pool exhaustion, no tier-boundary, no host-allowance transfer path.
- **ALL reward config setters**: `setERC20Reward*`, `setNFTReward`, `addNFTsToPool`, `setOffChainReward`. The ERC721 mock in setUp is essentially unused.
- **`completeTask` entirely**: on-chain verification, the broken 52-byte / `abi.decode` path, 30s anti-spam, `ONCHAIN_TX` revert.
- **Access control**: the unguarded `grantHostRole` is NOT tested; `revokeHostRole`, `emergencyPause`/`emergencyUnpause`, and `withdrawETH` non-admin revert are untested.
- `closeCampaign`, single `verifyTaskCompletion`, duplicate-claim revert, optional-task logic, batch length/size reverts, `MAX_PARTICIPANTS_LIMIT`, Pausable wrappers, fallback/receive reverts.

Building out reward/claim/NFT tests is the highest-value test work. See [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).

### Test mocks

`vm.addr(1..5)` addresses, `vm.warp(1_000_000)` to clear rate-limit cooldowns. `ERC20Mock` + `ERC721ConsecutiveMock` (1000 NFTs to host1). Imports `@openzeppelin/contracts/mocks/token/ERC20Mock.sol` and `.../ERC721ConsecutiveMock.sol` — these OZ mock paths move across OZ v5.x; confirm they exist in the pinned submodule or the test won't compile.

## Toolchain (`foundry.toml`)

solc `0.8.31`, evm `cancun`, `viaIR = true`, optimizer on (`runs = 200`), remapping `@openzeppelin/=lib/openzeppelin-contracts/`.

## Deploy

`script/DeployWeb3Campaigns.s.sol` — minimal, `new Web3Campaigns()`, no constructor args, no hardcoded addresses/secrets. Makefile `deploy-sepolia` uses `--account` keystore (no raw keys). Prior Sepolia broadcasts under `broadcast/`.

## CI (`.github/workflows/test.yml`)

Sets `FOUNDRY_PROFILE=ci` but `foundry.toml` has **no** `[profile.ci]` → silently uses default. Runs: `forge fmt --check`, `forge build --sizes`, `forge test -vvv`. `fail-fast`. Note: CI enforces `forge fmt --check` — run it locally before pushing.

## Make the repo runnable

Foundry + submodules are typically NOT installed in a fresh env:
1. Install Foundry.
2. `git submodule update --init --recursive` (`lib/forge-std` + `lib/openzeppelin-contracts` start empty).
3. `forge build`
4. `forge test`

See also [ARCHITECTURE.md](ARCHITECTURE.md).
