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

Required for the Makefile targets: `SEPOLIA_RPC_URL`, `DEPLOYER_ACCOUNT` (a **keystore account name**, never a raw key), `ETHERSCAN_API_KEY`.

## Procedure

```bash
make deploy-sepolia-dry     # 1. simulate first, every time -- prints all addresses, broadcasts nothing
make deploy-sepolia         # 2. broadcast + verify on Etherscan
```

## Post-deploy verification

The deployer EOA holds `DEFAULT_ADMIN_ROLE`, `HOST_ROLE`, `EMERGENCY_ADMIN`, `MODERATOR_ROLE`, `SIGNER_ROLE`, and `SETTLER_ROLE` (all granted in the constructor chain — `SETTLER_ROLE` needs no script wiring beyond this, identical to how `SIGNER_ROLE` is handled). Before announcing the deployment, confirm on-chain:

1. `getTreasury()` → your intended treasury, **not** `address(0)`.
2. `getFeeModule()` → `address(0)` for a fees-disabled beta, else the deployed `FeeModule`.
3. `OnChainRewardModule.WEB3_CAMPAIGNS()` and `NFTSettlementModule.WEB3_CAMPAIGNS()` → the deployed `Web3Campaigns` address (proves the satellites anchor to the right entrypoint).
4. Run one throwaway campaign end-to-end per reward path you intend to use. The registration of the reward/NFT modules has **no global getter** — it is only observable functionally, or per-campaign via `getCampaignRewardModule(id)` / `getCampaignNFTModule(id)` once a campaign adopts/deposits.
5. Rotate `SIGNER_ROLE` to your backend's signing key and revoke it from the deployer if they differ (`grantRole`/`revokeRole` — see [TASK_VERIFICATION.md](TASK_VERIFICATION.md)).
6. Rotate `SETTLER_ROLE` the same way if your platform-automation key differs from the deployer — it's the key allowed to fill a Merkle-settlement vacuum on a campaign abandoned for 14+ days (`SETTLEMENT_FALLBACK_DELAY`, see [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)). No separate global getter exists for it either; check via `hasRole(SETTLER_ROLE, addr)`.

## Things that will bite you

- **`grantHostRole` is open by design** — anyone can self-grant `HOST_ROLE`. Founder decision, stays open through beta ([NEXT_STEPS.md](NEXT_STEPS.md)). Do not treat a deployed instance as permissioned.
- **No upgradeability.** Founder decision: immutable, no proxy. A contract bug means redeploying and migrating. The satellite modules *are* rotatable (`setOnChainRewardModule`/`setNFTSettlementModule`/`setFeeModule`) — that's the escape hatch for module bugs, and it is why per-campaign pinning exists so a rotation can't desync in-flight campaigns ([SECURITY_FINDINGS.md](SECURITY_FINDINGS.md)).
- **Module rotation does not migrate state.** Campaigns already pinned to an old module keep using it. A rotation only affects campaigns that haven't pinned yet.
- **`Web3Campaigns` is now within single-digit bytes of the EIP-170 limit (~7B headroom).** Any change to the entrypoint needs `forge build --sizes` *before* writing a single line, not after ([TEST_AND_BUILD.md](TEST_AND_BUILD.md)) — the satellite-contract pattern is effectively mandatory for anything nontrivial from here on.
- **Sybil/humanity gating is enforced off-chain**, by the backend, at tree-build time — not by the contracts ([HUMANITY_GATING.md](HUMANITY_GATING.md)).
- **`SETTLER_ROLE` is a genuine (if bounded and time-gated) trust expansion** — treat the key the same way you'd treat `SIGNER_ROLE`: platform-controlled, rotatable via `DEFAULT_ADMIN_ROLE`, and never handed to an untrusted party. It can only ever fill a settlement vacuum on a campaign its own host abandoned for 14+ days, never override a host-published root — see the trust-model note in [SECURITY_FINDINGS.md](SECURITY_FINDINGS.md).

Related: [[ARCHITECTURE]], [[TEST_AND_BUILD]], [[SECURITY_FINDINGS]], [[NEXT_STEPS]].
