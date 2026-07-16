// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {DeployWeb3Campaigns} from "../script/DeployWeb3Campaigns.s.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {OnChainRewardModule} from "../src/OnChainRewardModule.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {FeeModule} from "../src/FeeModule.sol";
import {MockERC721} from "./NFTSettlement.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Guards the deploy script against rot. It calls the REAL `DeployWeb3Campaigns.deploy()`
/// (not a copy of its logic) and then drives one full campaign through each of the three reward
/// paths -- ERC20 Merkle, NFT Merkle, and on-chain tiered -- so that a deployment which forgets to
/// deploy or register a satellite fails here rather than on-chain.
///
/// This exists because the script previously deployed only `Web3Campaigns`, which silently produced
/// a half-dead system: NFT deposits and tiered rewards revert with no module registered, and
/// withdrawETH reverts with no treasury set. Nothing in the suite caught that, because every other
/// test wires the modules up by hand in its own setUp.
contract DeploymentSmokeTest is Test {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    DeployWeb3Campaigns public deployScript;

    Web3Campaigns public campaigns;
    OnChainRewardModule public rewardModule;
    NFTSettlementModule public nftModule;

    ERC20Mock public token;
    MockERC721 public nft721;

    address public treasury;
    address public host1;
    address public p1;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        treasury = vm.addr(50);
        host1 = vm.addr(2);
        p1 = vm.addr(4);

        deployScript = new DeployWeb3Campaigns();
        // Fees disabled (feeBps = 0) -- the intended beta default, and what `make deploy-sepolia`
        // produces with no FEE_BPS in the environment.
        DeployWeb3Campaigns.Deployment memory d = deployScript.deploy(treasury, 0, address(0), address(0));
        campaigns = d.campaigns;
        rewardModule = d.rewardModule;
        nftModule = d.nftModule;

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);
        nft721 = new MockERC721();
        nft721.mint(host1, 1);

        // grantHostRole is intentionally open/unguarded (founder decision) -- no admin prank needed.
        campaigns.grantHostRole(host1);
    }

    /*//////////////////////////////////////////////////////////////
                          WIRING / CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_Deploy_AdminRoleHeldByDeployingCaller() public view {
        // Web3Campaigns' constructor grants DEFAULT_ADMIN_ROLE to msg.sender, which is whoever
        // called deploy() -- the script contract here, the deployer EOA under --broadcast.
        assertTrue(campaigns.hasRole(DEFAULT_ADMIN_ROLE, address(deployScript)));
    }

    function test_Deploy_TreasuryIsSet() public view {
        // Without this, withdrawETH reverts TreasuryNotSet forever.
        assertEq(campaigns.getTreasury(), treasury);
    }

    function test_Deploy_FeesDisabledByDefault() public view {
        assertEq(campaigns.getFeeModule(), address(0));
    }

    function test_Deploy_ModulesPointAtTheDeployedEntrypoint() public view {
        assertEq(rewardModule.WEB3_CAMPAIGNS(), address(campaigns));
        assertEq(nftModule.WEB3_CAMPAIGNS(), address(campaigns));
    }

    function test_Deploy_WithFeesEnabled_DeploysAndWiresFeeModule() public {
        address feeAdmin = vm.addr(51);
        address feeTreasury = vm.addr(52);

        DeployWeb3Campaigns.Deployment memory d = deployScript.deploy(treasury, 250, feeAdmin, feeTreasury);

        assertTrue(address(d.feeModule) != address(0));
        assertEq(d.campaigns.getFeeModule(), address(d.feeModule));
        assertEq(d.feeModule.admin(), feeAdmin);
        assertEq(d.feeModule.treasury(), feeTreasury);
        assertEq(d.feeModule.feeBps(), 250);
    }

    /*//////////////////////////////////////////////////////////////
                       END-TO-END REWARD PATHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Proves the ERC20 Merkle path works on a freshly-deployed system. This one needs no
    /// satellite, so it would have passed even against the old script -- it's here as the baseline.
    function test_Deploy_ERC20MerkleClaim_EndToEnd() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, keccak256(bytes.concat(keccak256(abi.encode(p1, uint256(100 ether))))));
        vm.warp(block.timestamp + campaigns.ROOT_DISPUTE_WINDOW() + 1);

        vm.prank(p1);
        campaigns.claimERC20(id, 100 ether, new bytes32[](0));

        assertEq(token.balanceOf(p1), 100 ether);
    }

    /// @dev Proves the NFT path works end to end. Reverts at depositERC721Rewards if the script
    /// forgot to deploy the NFTSettlementModule or call setNFTSettlementModule.
    function test_Deploy_NFTMerkleClaim_EndToEnd() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), ids);
        vm.stopPrank();

        // The campaign pinned to the module the script actually deployed.
        assertEq(campaigns.getCampaignNFTModule(id), address(nftModule));

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        nftModule.setNFTMerkleRoot(
            id, keccak256(bytes.concat(keccak256(abi.encode(p1, uint8(0), address(nft721), uint256(1), uint256(1)))))
        );
        vm.warp(block.timestamp + campaigns.ROOT_DISPUTE_WINDOW() + 1);

        vm.prank(p1);
        nftModule.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, new bytes32[](0));

        assertEq(nft721.ownerOf(1), p1);
    }

    /// @dev Proves the on-chain tiered path works end to end. Reverts at setRankTiers if the script
    /// forgot to deploy the OnChainRewardModule or call setOnChainRewardModule.
    function test_Deploy_TieredClaim_EndToEnd() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        vm.prank(host1);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);
        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 100 ether;
        vm.prank(host1);
        rewardModule.setRankTiers(id, startRanks, endRanks, amounts);

        // The campaign pinned to the module the script actually deployed.
        assertEq(campaigns.getCampaignRewardModule(id), address(rewardModule));

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.prank(p1);
        campaigns.completeTask(id, 0);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(p1);
        rewardModule.claimReward(id);

        assertEq(token.balanceOf(p1), 100 ether);
    }

    /// @dev The treasury the script set is a real, working withdrawal destination -- not just a
    /// stored value. Uses the script contract's admin role, mirroring how the deployer EOA would.
    function test_Deploy_WithdrawETH_ReachesConfiguredTreasury() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(campaigns).call{value: 1 ether}("");
        assertTrue(sent);

        uint256 before = treasury.balance;
        vm.prank(address(deployScript));
        campaigns.withdrawETH();

        assertEq(treasury.balance - before, 1 ether);
    }
}
