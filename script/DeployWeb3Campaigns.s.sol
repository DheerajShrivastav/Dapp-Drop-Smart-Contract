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
/// - SIGNER_ADDRESS   : sole SIGNER_ROLE holder.        Default: the deployer.
/// - SETTLER_ADDRESS  : sole SETTLER_ROLE holder.       Default: the deployer.
/// A beta deploy should set SIGNER_ADDRESS/SETTLER_ADDRESS to dedicated backend keys so those
/// roles never sit on the deployer key; the deployer then loses them in the same run.
contract DeployWeb3Campaigns is Script {
    struct Config {
        address deployer; // account executing the deployment; the constructor grants it every role
        address treasury;
        uint256 feeBps;
        address feeAdmin;
        address feeTreasury;
        address signer;
        address settler;
    }

    struct Deployment {
        Web3Campaigns campaigns;
        OnChainRewardModule rewardModule;
        NFTSettlementModule nftModule;
        FeeModule feeModule; // address(0) when fees are disabled (FEE_BPS unset/0)
    }

    function run() external returns (Deployment memory d) {
        // `--account`/`--sender` sets the script's msg.sender to the deployer address.
        Config memory c = readConfig(msg.sender);

        vm.startBroadcast();
        d = deploy(c);
        vm.stopBroadcast();

        _log(d, c);
    }

    /// @notice Resolve the deployment config from env vars, defaulting each to the deployer.
    /// Address vars go through envAddressOr, which reverts on malformed input; address(0) is
    /// rejected by deploy().
    function readConfig(address _deployer) public view returns (Config memory c) {
        c.deployer = _deployer;
        c.treasury = envAddressOr("TREASURY_ADDRESS", _deployer);
        c.feeBps = vm.envOr("FEE_BPS", uint256(0));
        c.feeAdmin = envAddressOr("FEE_ADMIN", _deployer);
        c.feeTreasury = envAddressOr("FEE_TREASURY", c.treasury);
        c.signer = envAddressOr("SIGNER_ADDRESS", _deployer);
        c.settler = envAddressOr("SETTLER_ADDRESS", _deployer);
    }

    /// @notice Read an address env var, returning `_default` only when it is unset or empty.
    /// Unlike vm.envOr(name, address), which silently falls back to the default on unparseable
    /// input, a typo here reverts -- a mistyped SIGNER_ADDRESS must never quietly leave the role
    /// on the deployer. Mixed-case input must also match its EIP-55 checksum.
    function envAddressOr(string memory _name, address _default) public view returns (address addr) {
        string memory raw = vm.envOr(_name, string(""));
        if (bytes(raw).length == 0) {
            return _default;
        }
        addr = vm.parseAddress(raw);
        if (_isMixedCase(raw)) {
            require(keccak256(bytes(raw)) == keccak256(bytes(vm.toString(addr))), "address env var: bad checksum");
        }
    }

    /// @dev True if the string contains both a-f and A-F, i.e. it claims to carry an EIP-55 checksum
    /// (all-lowercase / all-uppercase hex carries none). The "0x" prefix has no a-f/A-F letters.
    function _isMixedCase(string memory _s) internal pure returns (bool) {
        bytes memory b = bytes(_s);
        bool lower;
        bool upper;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "f") lower = true;
            else if (b[i] >= "A" && b[i] <= "F") upper = true;
        }
        return lower && upper;
    }

    /// @notice Deploy + wire the whole system. Deliberately broadcast-free so the deployment smoke
    /// test can call the REAL wiring logic rather than re-implementing it (see
    /// test/DeploymentSmoke.t.sol) -- a copy would let the script rot without failing a test.
    /// @dev Whoever executes this ends up holding DEFAULT_ADMIN_ROLE and every other constructor-
    /// granted role: the deployer EOA under `forge script --broadcast`, or the script contract
    /// itself when called from a test. `_c.deployer` must name that account.
    /// `_c.treasury` must be non-zero (setTreasury rejects address(0)). `_c.feeBps == 0` skips
    /// FeeModule entirely, and `_c.feeAdmin`/`_c.feeTreasury` are then ignored.
    function deploy(Config memory _c) public returns (Deployment memory d) {
        require(_c.signer != address(0), "SIGNER_ADDRESS is zero");
        require(_c.settler != address(0), "SETTLER_ADDRESS is zero");

        d.campaigns = new Web3Campaigns();
        require(d.campaigns.hasRole(bytes32(0), _c.deployer), "Config.deployer is not the deploying account");

        // Satellites take the entrypoint's address as an immutable trust anchor, so they must be
        // deployed after it -- and registered back on it, below, or their features stay dead.
        d.rewardModule = new OnChainRewardModule(address(d.campaigns));
        d.nftModule = new NFTSettlementModule(address(d.campaigns));

        d.campaigns.setOnChainRewardModule(address(d.rewardModule));
        d.campaigns.setNFTSettlementModule(address(d.nftModule));
        d.campaigns.setTreasury(_c.treasury);

        // Fees are opt-in: with FEE_BPS unset/0 no FeeModule is deployed and _feeModule stays
        // address(0), which fundCampaignERC20 treats as "no fee" -- the intended beta default.
        if (_c.feeBps > 0) {
            d.feeModule = new FeeModule(_c.feeAdmin, _c.feeBps, _c.feeTreasury);
            d.campaigns.setFeeModule(address(d.feeModule));
        }

        _assignSoleHolder(d.campaigns, d.campaigns.SIGNER_ROLE(), _c.signer, _c.deployer);
        _assignSoleHolder(d.campaigns, d.campaigns.SETTLER_ROLE(), _c.settler, _c.deployer);
    }

    /// @dev The constructor grants `_role` to the deployer. If a different holder is configured,
    /// hand it over and revoke the deployer's implicit grant so exactly one account holds it.
    /// DEFAULT_ADMIN_ROLE is never touched.
    function _assignSoleHolder(Web3Campaigns _campaigns, bytes32 _role, address _holder, address _deployer) internal {
        if (_holder != _deployer) {
            _campaigns.grantRole(_role, _holder);
            _campaigns.revokeRole(_role, _deployer);
        }
        require(
            _campaigns.hasRole(_role, _holder) && (_holder == _deployer || !_campaigns.hasRole(_role, _deployer)),
            "role handover failed"
        );
    }

    function _log(Deployment memory d, Config memory c) internal pure {
        console.log("Web3Campaigns       :", address(d.campaigns));
        console.log("OnChainRewardModule :", address(d.rewardModule));
        console.log("NFTSettlementModule :", address(d.nftModule));
        console.log("admin / mod / emerg :", c.deployer);
        console.log("signer              :", c.signer);
        console.log("settler             :", c.settler);
        console.log("treasury            :", c.treasury);
        if (c.feeBps > 0) {
            console.log("FeeModule           :", address(d.feeModule));
            console.log("feeBps              :", c.feeBps);
        } else {
            console.log("FeeModule           : (none -- fees disabled)");
        }
    }
}
