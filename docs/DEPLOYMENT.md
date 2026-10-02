# Deployment — Web3Campaigns

> **`Web3Campaigns` alone is not a usable system.** It is the entrypoint and the sole custodian of funds, but NFT settlement and on-chain tiered rewards live in *satellite* contracts that must be deployed **and registered back on it**, and `withdrawETH` needs a treasury. `script/DeployWeb3Campaigns.s.sol` does all of this; `test/DeploymentSmoke.t.sol` fails if it ever stops doing it. See [ARCHITECTURE.md](ARCHITECTURE.md) for why the system is split this way (EIP-170).

## What gets deployed

| Contract | Required? | Purpose |
|---|---|---|
| `Web3Campaigns` | always | Entrypoint; holds ALL funds + campaign state |
| `OnChainRewardModule` | always | RANK_TIERED / SCORE_TIERED settlement logic |
| `NFTSettlementModule` | always | NFT Merkle settlement + per-campaign escrow bookkeeping |
| `FeeModule` | only if `FEE_BPS > 0` | Protocol fee skim at `fundCampaignERC20` |

The script deploys them in that order (satellites take the entrypoint address as an immutable constructor arg), then wires them:

```
setOnChainRewardModule(rewardModule)   // else tiered rewards revert NotOnChainRewardModule
setNFTSettlementModule(nftModule)      // else NFT deposits revert
setTreasury(TREASURY_ADDRESS)          // else withdrawETH reverts TreasuryNotSet
setFeeModule(feeModule)                // only when FEE_BPS > 0
```

## Configuration (env vars — all optional, all default safely)

| Var | Default | Notes |
|---|---|---|
| `TREASURY_ADDRESS` | the deployer | `withdrawETH` destination. Rotatable later via `setTreasury`. |
| `FEE_BPS` | `0` | `0` = **no `FeeModule` deployed, fees fully disabled** — the intended beta default. Max 1000 (10%). |
| `FEE_ADMIN` | the deployer | `FeeModule` admin. **Should be a distinct key/multisig in production** — see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md). |
| `FEE_TREASURY` | `TREASURY_ADDRESS` | Where protocol fees land. |
| `SIGNER_ADDRESS` | the deployer | Sole `SIGNER_ROLE` holder (the backend attestation key). If it differs from the deployer, the script grants it and **revokes the deployer's constructor-granted `SIGNER_ROLE` in the same run**. |
| `SETTLER_ADDRESS` | the deployer | Sole `SETTLER_ROLE` holder (the platform-automation key). Same grant-then-revoke behaviour as `SIGNER_ADDRESS`. |

**Address parsing is strict.** Every address var is read via the script's `envAddressOr`: unset or empty means use the default, and anything else must parse as an address or the script aborts. Mixed-case input must also match its EIP-55 checksum. This is deliberate: plain `vm.envOr(name, address)` silently falls back to the default on a malformed value, so a typo'd `SIGNER_ADDRESS` would have quietly left `SIGNER_ROLE` on the deployer. `address(0)` is rejected for `SIGNER_ADDRESS`/`SETTLER_ADDRESS`. `DEFAULT_ADMIN_ROLE` is never revoked by the script.

Required for the Makefile targets: `SEPOLIA_RPC_URL`, `DEPLOYER_ACCOUNT` (a **keystore account name**, never a raw key), `ETHERSCAN_API_KEY`.

## Procedure

```bash
make deploy-sepolia-dry     # 1. simulate first, every time -- prints all addresses, broadcasts nothing
make deploy-sepolia         # 2. broadcast + verify on Etherscan
```

### Test deploy (defaults)

For a throwaway or test deployment, set no role/treasury vars. The deployer key ends up with every role (`DEFAULT_ADMIN_ROLE`, `HOST_ROLE`, `EMERGENCY_ADMIN`, `MODERATOR_ROLE`, `SIGNER_ROLE`, `SETTLER_ROLE`) and is the treasury. The dry run's log shows the same address on the `admin / mod / emerg`, `signer`, `settler` and `treasury` lines.

### Beta deploy (dedicated role keys)

Per frontend `docs/DECISIONS_v0.6.0.md` Decision 1, `SIGNER_ROLE` and `SETTLER_ROLE` must go straight to dedicated backend addresses and never sit on the deployer key:

```bash
export SIGNER_ADDRESS=0x...     # backend attestation signer (public address only -- never the key)
export SETTLER_ADDRESS=0x...    # platform-automation settler
export TREASURY_ADDRESS=0x...   # withdrawETH destination
make deploy-sepolia-dry         # check the signer / settler / treasury log lines are the intended addresses
make deploy-sepolia
```

Then verify on-chain (role ids are `keccak256` of the role name):

```bash
W3C=<Web3Campaigns address from the log>
SIGNER=$(cast keccak "SIGNER_ROLE"); SETTLER=$(cast keccak "SETTLER_ROLE")
cast call $W3C "hasRole(bytes32,address)(bool)" $SIGNER  $SIGNER_ADDRESS   --rpc-url $SEPOLIA_RPC_URL  # true
cast call $W3C "hasRole(bytes32,address)(bool)" $SIGNER  <deployer>        --rpc-url $SEPOLIA_RPC_URL  # false
cast call $W3C "hasRole(bytes32,address)(bool)" $SETTLER $SETTLER_ADDRESS  --rpc-url $SEPOLIA_RPC_URL  # true
cast call $W3C "hasRole(bytes32,address)(bool)" $SETTLER <deployer>        --rpc-url $SEPOLIA_RPC_URL  # false
cast call $W3C "getTreasury()(address)" --rpc-url $SEPOLIA_RPC_URL                                     # TREASURY_ADDRESS
```

Unset these vars afterwards (`unset SIGNER_ADDRESS SETTLER_ADDRESS TREASURY_ADDRESS`) so a later test deploy from the same shell doesn't inherit them.

### Rotating `MODERATOR_ROLE` / `EMERGENCY_ADMIN` later

The script leaves both on the deployer. To move either to a dedicated key or multisig, the `DEFAULT_ADMIN_ROLE` holder grants the new holder first, then revokes the deployer:

```bash
ROLE=$(cast keccak "EMERGENCY_ADMIN")   # or "MODERATOR_ROLE"
cast send $W3C "grantRole(bytes32,address)"  $ROLE <new holder> --account $DEPLOYER_ACCOUNT --rpc-url $SEPOLIA_RPC_URL
cast send $W3C "revokeRole(bytes32,address)" $ROLE <deployer>   --account $DEPLOYER_ACCOUNT --rpc-url $SEPOLIA_RPC_URL
```

The same pattern rotates `SIGNER_ROLE`/`SETTLER_ROLE` after deployment.

## Post-deploy verification

The deployer EOA holds `DEFAULT_ADMIN_ROLE`, `HOST_ROLE`, `EMERGENCY_ADMIN` and `MODERATOR_ROLE` (granted in the constructor chain). It also holds `SIGNER_ROLE` and `SETTLER_ROLE` **unless** `SIGNER_ADDRESS`/`SETTLER_ADDRESS` were set, in which case only those addresses do. Before announcing the deployment, confirm on-chain:

1. `getTreasury()` → your intended treasury, **not** `address(0)`.
2. `getFeeModule()` → `address(0)` for a fees-disabled beta, else the deployed `FeeModule`.
3. `OnChainRewardModule.WEB3_CAMPAIGNS()` and `NFTSettlementModule.WEB3_CAMPAIGNS()` → the deployed `Web3Campaigns` address (proves the satellites anchor to the right entrypoint).
4. Run one throwaway campaign end-to-end per reward path you intend to use. The registration of the reward/NFT modules has **no global getter** — it is only observable functionally, or per-campaign via `getCampaignRewardModule(id)` / `getCampaignNFTModule(id)` once a campaign adopts/deposits.
5. `SIGNER_ROLE` is held by exactly your backend's signing key: set `SIGNER_ADDRESS` at deploy time (beta), or rotate afterwards with `grantRole`/`revokeRole` (see above and [TASK_VERIFICATION.md](TASK_VERIFICATION.md)).
6. `SETTLER_ROLE` the same way (`SETTLER_ADDRESS`, or rotate afterwards) if your platform-automation key differs from the deployer — it's the key allowed to fill a Merkle-settlement vacuum on a campaign abandoned for 14+ days (`SETTLEMENT_FALLBACK_DELAY`, see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)). No separate global getter exists for it either; check via `hasRole(SETTLER_ROLE, addr)`.

## Things that will bite you

- **`grantHostRole` is open by design** — anyone can self-grant `HOST_ROLE`. Founder decision, stays open through beta ([NEXT_STEPS.md](NEXT_STEPS.md)). Do not treat a deployed instance as permissioned.
- **No upgradeability.** Founder decision: immutable, no proxy. A contract bug means redeploying and migrating. The satellite modules *are* rotatable (`setOnChainRewardModule`/`setNFTSettlementModule`/`setFeeModule`) — that's the escape hatch for module bugs, and it is why per-campaign pinning exists so a rotation can't desync in-flight campaigns ([SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)).
- **Module rotation does not migrate state.** Campaigns already pinned to an old module keep using it. A rotation only affects campaigns that haven't pinned yet.
- **`Web3Campaigns` is now within a few bytes of the EIP-170 limit (15B headroom).** Any change to the entrypoint needs `forge build --sizes` *before* writing a single line, not after ([TEST_AND_BUILD.md](TEST_AND_BUILD.md)) — the satellite-contract pattern is effectively mandatory for anything nontrivial from here on.
- **Sybil/humanity gating is enforced off-chain**, by the backend, at tree-build time — not by the contracts ([HUMANITY_GATING.md](HUMANITY_GATING.md)).
- **`SETTLER_ROLE` is a genuine (if bounded and time-gated) trust expansion** — treat the key the same way you'd treat `SIGNER_ROLE`: platform-controlled, rotatable via `DEFAULT_ADMIN_ROLE`, and never handed to an untrusted party. It can only ever fill a settlement vacuum on a campaign its own host abandoned for 14+ days, never override a host-published root — see the trust-model note in [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).

Related: [[ARCHITECTURE]], [[TEST_AND_BUILD]], [[SECURITY_FINDINGS]], [[NEXT_STEPS]].
