// Filename: script/DeployWeb3Campaigns.s.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {OnChainRewardModule} from "../src/OnChainRewardModule.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {FeeModule} from "../src/FeeModule.sol";

/// @notice Deploys the full Web3Campaigns system: the entrypoint plus its satellite modules, wired
/// together. Deploying `Web3Campaigns` alone is NOT a usable system -- NFT rewards and on-chain
/// tiered rewards both revert until their modules are deployed and registered, and withdrawETH
/// reverts until a treasury is set. See docs/DEPLOYMENT.md.
///
/// Optional env vars (all have safe defaults):
/// - TREASURY_ADDRESS : withdrawETH destination.        Default: the deployer.
/// - FEE_BPS          : protocol fee, 0 disables fees.  Default: 0 (no FeeModule deployed).
/// - FEE_ADMIN        : FeeModule admin key.            Default: the deployer.
/// - FEE_TREASURY     : where protocol fees are sent.   Default: TREASURY_ADDRESS.
contract DeployWeb3Campaigns is Script {
    struct Deployment {
        Web3Campaigns campaigns;
        OnChainRewardModule rewardModule;
        NFTSettlementModule nftModule;
        FeeModule feeModule; // address(0) when fees are disabled (FEE_BPS unset/0)
    }

    function run() external returns (Deployment memory d) {
        // `--account`/`--sender` sets the script's msg.sender to the deployer address.
        address deployer = msg.sender;
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(0));
        address feeAdmin = vm.envOr("FEE_ADMIN", deployer);
        address feeTreasury = vm.envOr("FEE_TREASURY", treasury);

        vm.startBroadcast();
        d = deploy(treasury, feeBps, feeAdmin, feeTreasury);
        vm.stopBroadcast();

        _log(d, deployer, treasury, feeBps);
    }

    /// @notice Deploy + wire the whole system. Deliberately broadcast-free so the deployment smoke
    /// test can call the REAL wiring logic rather than re-implementing it (see
    /// test/DeploymentSmoke.t.sol) -- a copy would let the script rot without failing a test.
    /// @dev Whoever calls this ends up holding DEFAULT_ADMIN_ROLE (Web3Campaigns' constructor grants
    /// it to msg.sender): the deployer EOA under `forge script --broadcast`, or the script contract
    /// itself when called from a test.
    /// @param _treasury withdrawETH destination (must be non-zero -- setTreasury rejects address(0)).
    /// @param _feeBps Protocol fee in basis points; 0 skips FeeModule entirely (fees disabled).
    /// @param _feeAdmin FeeModule admin; ignored when _feeBps == 0.
    /// @param _feeTreasury Protocol-fee destination; ignored when _feeBps == 0.
    function deploy(address _treasury, uint256 _feeBps, address _feeAdmin, address _feeTreasury)
        public
        returns (Deployment memory d)
    {
        d.campaigns = new Web3Campaigns();

        // Satellites take the entrypoint's address as an immutable trust anchor, so they must be
        // deployed after it -- and registered back on it, below, or their features stay dead.
        d.rewardModule = new OnChainRewardModule(address(d.campaigns));
        d.nftModule = new NFTSettlementModule(address(d.campaigns));

        d.campaigns.setOnChainRewardModule(address(d.rewardModule));
        d.campaigns.setNFTSettlementModule(address(d.nftModule));
        d.campaigns.setTreasury(_treasury);

        // Fees are opt-in: with FEE_BPS unset/0 no FeeModule is deployed and _feeModule stays
        // address(0), which fundCampaignERC20 treats as "no fee" -- the intended beta default.
        if (_feeBps > 0) {
            d.feeModule = new FeeModule(_feeAdmin, _feeBps, _feeTreasury);
            d.campaigns.setFeeModule(address(d.feeModule));
        }
    }

    function _log(Deployment memory d, address deployer, address treasury, uint256 feeBps) internal pure {
        console.log("Web3Campaigns       :", address(d.campaigns));
        console.log("OnChainRewardModule :", address(d.rewardModule));
        console.log("NFTSettlementModule :", address(d.nftModule));
        console.log("admin / roles       :", deployer);
        console.log("treasury            :", treasury);
        if (feeBps > 0) {
            console.log("FeeModule           :", address(d.feeModule));
            console.log("feeBps              :", feeBps);
        } else {
            console.log("FeeModule           : (none -- fees disabled)");
        }
    }
}
