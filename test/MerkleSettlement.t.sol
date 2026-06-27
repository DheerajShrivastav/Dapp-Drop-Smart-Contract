// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Covers Stage B1: ERC20 escrow + post-campaign Merkle settlement claim path.
contract MerkleSettlementTest is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;

    address public deployer;
    address public host1;
    address public participant1;
    address public participant2;
    address public stranger;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;
    uint256 constant GRACE = 30 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        participant1 = vm.addr(4);
        participant2 = vm.addr(5);
        stranger = vm.addr(6);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);

        vm.prank(deployer);
        campaigns.grantHostRole(host1);
    }

    /*//////////////////////////////////////////////////////////////
                          MERKLE TREE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev OZ StandardMerkleTree leaf for an (account, amount) allocation.
    function _leaf(address acct, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, amt))));
    }

    /// @dev Commutative pair hash, matching OZ MerkleProof's sorted-pair convention.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /*//////////////////////////////////////////////////////////////
                               SETUP HELPER
    //////////////////////////////////////////////////////////////*/

    /// @dev Create -> configure -> fund -> open -> end -> set root. Returns campaign id.
    function _endedCampaignWithRoot(
        bytes32 root,
        uint256 fundAmount
    ) internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), fundAmount);
        campaigns.fundCampaignERC20(id, fundAmount);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, root);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimERC20_SingleLeaf_Success() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount); // single-leaf tree: root == leaf
        uint256 id = _endedCampaignWithRoot(root, amount);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(participant1);
        campaigns.claimERC20(id, amount, proof);

        assertEq(token.balanceOf(participant1), amount);
        assertTrue(campaigns.hasClaimedERC20(id, participant1));
    }

    function test_ClaimERC20_TwoLeaves_BothClaim() public {
        uint256 amt1 = 100 ether;
        uint256 amt2 = 50 ether;
        bytes32 l1 = _leaf(participant1, amt1);
        bytes32 l2 = _leaf(participant2, amt2);
        bytes32 root = _hashPair(l1, l2);

        uint256 id = _endedCampaignWithRoot(root, amt1 + amt2);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = l2;
        vm.prank(participant1);
        campaigns.claimERC20(id, amt1, proof1);

        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = l1;
        vm.prank(participant2);
        campaigns.claimERC20(id, amt2, proof2);

        assertEq(token.balanceOf(participant1), amt1);
        assertEq(token.balanceOf(participant2), amt2);

        (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, amt1 + amt2);
        assertEq(distributed, amt1 + amt2);
    }

    function test_ClaimERC20_RevertsOnDoubleClaim() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        uint256 id = _endedCampaignWithRoot(root, amount);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(participant1);
        campaigns.claimERC20(id, amount, proof);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        campaigns.claimERC20(id, amount, proof);
    }

    function test_ClaimERC20_RevertsOnWrongAmount() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        uint256 id = _endedCampaignWithRoot(root, amount);
        bytes32[] memory proof = new bytes32[](0);

        // Claiming a different amount yields a leaf that isn't in the tree.
        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidMerkleProof.selector);
        campaigns.claimERC20(id, amount + 1, proof);
    }

    function test_ClaimERC20_RevertsForNonAllocatedAccount() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        uint256 id = _endedCampaignWithRoot(root, amount);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(stranger);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidMerkleProof.selector);
        campaigns.claimERC20(id, amount, proof);
    }

    function test_ClaimERC20_RevertsBeforeRootSet() public {
        // Build an ended campaign but do NOT set a root.
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

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__MerkleRootNotSet.selector);
        campaigns.claimERC20(id, 100 ether, proof);
    }

    function test_ClaimERC20_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.prank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.claimERC20(id, 100 ether, proof);
    }

    function test_ClaimERC20_RevertsOnInsufficientEscrow() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        // Root promises 100 but only 40 escrowed.
        uint256 id = _endedCampaignWithRoot(root, 40 ether);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InsufficientEscrow.selector);
        campaigns.claimERC20(id, amount, proof);
    }

    function test_ClaimERC20_RevertsWhenPaused() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        uint256 id = _endedCampaignWithRoot(root, amount);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(deployer);
        campaigns.emergencyPause();

        vm.prank(participant1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        campaigns.claimERC20(id, amount, proof);
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIG / FUNDING
    //////////////////////////////////////////////////////////////*/

    function test_FundCampaignERC20_RevertsIfNotConfigured() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        token.approve(address(campaigns), 100 ether);
        vm.expectRevert(CampaignStorage.Web3Campaigns__ERC20RewardNotConfigured.selector);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();
    }

    function test_FundCampaignERC20_IncreasesEscrow() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 300 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        campaigns.fundCampaignERC20(id, 200 ether); // top-up accumulates
        vm.stopPrank();

        (address t, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(t, address(token));
        assertEq(escrowed, 300 ether);
        assertEq(token.balanceOf(address(campaigns)), 300 ether);
    }

    function test_SetMerkleRoot_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        campaigns.configureERC20Reward(id, address(token));
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.setERC20MerkleRoot(id, bytes32(uint256(1)));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          UNCLAIMED SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUnclaimed_RevertsDuringGrace() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        uint256 id = _endedCampaignWithRoot(root, amount);

        vm.prank(host1);
        campaigns.closeCampaign(id);

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__GracePeriodActive.selector);
        campaigns.withdrawUnclaimedERC20(id);
    }

    function test_WithdrawUnclaimed_SuccessAfterGrace() public {
        uint256 amount = 100 ether;
        bytes32 root = _leaf(participant1, amount);
        // Escrow 150 but only 100 will ever be claimable; 50 should be sweepable.
        uint256 id = _endedCampaignWithRoot(root, 150 ether);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(participant1);
        campaigns.claimERC20(id, amount, proof);

        vm.prank(host1);
        campaigns.closeCampaign(id);

        vm.warp(block.timestamp + GRACE + 1);

        uint256 hostBalBefore = token.balanceOf(host1);
        vm.prank(host1);
        campaigns.withdrawUnclaimedERC20(id);

        assertEq(token.balanceOf(host1) - hostBalBefore, 50 ether);

        // Second sweep reverts.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadySwept.selector);
        campaigns.withdrawUnclaimedERC20(id);
    }
}
