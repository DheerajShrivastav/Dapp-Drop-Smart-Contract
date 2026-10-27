# Sepolia deployments

## Current: v0.7.0 (2026-10-27)

Source: `dev` @ `5aa3e13` (PRs #23–#26 merged; tag `v0.7.0-sepolia`). 297 tests passing, `Web3Campaigns` 24,142B (434B headroom). All four contracts verified on Etherscan.

| Contract | Address | Deploy tx |
|---|---|---|
| `Web3Campaigns` (entrypoint) | [`0xC562505899faCee1F8f755F009cf6FbA3EA3E8Da`](https://sepolia.etherscan.io/address/0xc562505899facee1f8f755f009cf6fba3ea3e8da) | `0x3a93334f2807b9f79dbb93e209bef9fa3d8027f734749368207b915549e10a84` (block 12006087) |
| `OnChainRewardModule` | [`0xDF0A0dd1459401EB75dBD2B64b9713B59626D19B`](https://sepolia.etherscan.io/address/0xdf0a0dd1459401eb75dbd2b64b9713b59626d19b) | `0x84f8095f49174b7fcefd303786567b16f9dfcadf77f9ef67542621449c830a7c` |
| `NFTSettlementModule` | [`0xeb1229154D92234641000991345Ed725B112dB09`](https://sepolia.etherscan.io/address/0xeb1229154d92234641000991345ed725b112db09) | `0xe6d62d85728f55211368e67f435ef47cf9fb7d90640f1c41754f1005ec3b3331` |
| `OnChainRewardLib` (linked library, CREATE2) | [`0x9d23b4D7FC09BafC193f23469557c6DB7B647016`](https://sepolia.etherscan.io/address/0x9d23b4d7fc09bafc193f23469557c6db7b647016) | `0x0e131160378bfe94b4b48f81ced7674347a546915d3f7141ea4fcb4d7970f09b` |
| `FeeModule` | none (`FEE_BPS` unset: fees disabled) | — |

Wiring txs: `setOnChainRewardModule` `0x3efc3b9d…f1542`, `setNFTSettlementModule` `0xad960ca2…10a84`, `setTreasury` `0x89c6dddb…ca20`.

**Roles:** one wallet, `0xcCF284b8281dFe66d756EAe86eE93E004cF8612C`, holds `DEFAULT_ADMIN_ROLE`, `MODERATOR_ROLE`, `EMERGENCY_ADMIN`, `SIGNER_ROLE` and `SETTLER_ROLE`, and is the treasury (founder decision 2026-10-27: launch fast; split the roles before mainnet). The wallet is an EIP-7702-delegated account (MetaMask smart account).

**Checked on-chain after deploy:** `VERSION()` = "0.7.0"; `paused()` = false; `getCampaignCount()` = 0; `getTreasury()` = the wallet; `getFeeModule()` = `address(0)`; both modules' `WEB3_CAMPAIGNS()` = the entrypoint; the three wiring txs emitted their events.

**Deploy command that worked** (see "Things that will bite you" in [DEPLOYMENT.md](../DEPLOYMENT.md)): `--broadcast --slow --skip-simulation --gas-estimate-multiplier 125`. Two earlier attempts each burned one nonce on a failed `OnChainRewardLib` CREATE2 (out of gas on Foundry's local estimates), with no other effect.

## Previous: v0.6.0 (2026-07-20) — superseded, still live

| Contract | Address |
|---|---|
| `Web3Campaigns` | `0xf0A2Fac02ffBA4A7762f2f0d611253B6C97bB1B3` |
| `OnChainRewardModule` | `0x167475bcB8BE2346A8DFAbdAC017e388B56F35B4` |
| `NFTSettlementModule` | `0xf85Fe37e9dA3Ae5529a39fc47eb6780934f69747` |

The contracts are immutable, so this deployment keeps running. Its known issues are fixed only in v0.7.0 (see [SECURITY_FINDINGS.md](../SECURITY_FINDINGS.md)). Its campaign 8 has 10 USDC escrow claimable back by the host after its grace period (~2026-10-29).
