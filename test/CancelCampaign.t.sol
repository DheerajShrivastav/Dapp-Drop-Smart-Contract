// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Covers cancelCampaign: allowed in Draft/Open/Ended while totalParticipants == 0 AND no
/// ERC20/NFT settlement has been committed (closing both the totalParticipants-only bait-and-switch
/// path and a more serious settlement-commitment rug-pull -- see the two Reverts...SettlementRoot...
/// regression tests), immediate ERC20 refund, and immediate NFT reclaim via
/// NFTSettlementModule.withdrawUnclaimedERC721/1155 (bypassing the grace period once Cancelled).
/// Ended is included so a keeper's permissionless endCampaign call can't strip a
/// zero-participant/zero-settlement campaign's host of their immediate refund.
contract CancelCampaignTest is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    NFTSettlementModule public nftModule;

    address public deployer;
    address public host1;
    address public participant1;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        participant1 = vm.addr(4);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);

        vm.prank(deployer);
        campaigns.grantHostRole(host1);

        nftModule = new NFTSettlementModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setNFTSettlementModule(address(nftModule));
    }

    function _createCampaign() internal returns (uint256 id, uint256 startTime, uint256 endTime) {
        startTime = block.timestamp + START_OFFSET;
        endTime = startTime + CAMPAIGN_DURATION;
        vm.prank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
    }

    function _leaf(address acct, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, amt))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice REGRESSION (PR #20 review): cancelCampaign's guard was totalParticipants == 0,
    /// which is decoupled from Merkle settlement -- claims never touch totalParticipants. A host
    /// could publish a root, let some participants legitimately claim, then cancel to instantly
    /// reclaim the remainder and permanently lock out everyone who hadn't claimed yet, bypassing
    /// both the dispute window and the 30-day grace period. Must revert.
    function test_CancelCampaign_RevertsIfSettlementRootPublished_EvenWithZeroParticipants() public {
        address participant2 = vm.addr(5);

        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));
        uint256 amt1 = 50 ether;
        uint256 amt2 = 50 ether;
        token.approve(address(campaigns), amt1 + amt2);
        campaigns.fundCampaignERC20(id, amt1 + amt2);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        // totalParticipants stays 0 the whole time -- this campaign settles purely from an
        // off-chain allowlist, nobody ever calls completeTask.
        bytes32 l1 = _leaf(participant1, amt1);
        bytes32 l2 = _leaf(participant2, amt2);
        bytes32 root = _hashPair(l1, l2);
        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, root);

        vm.warp(block.timestamp + campaigns.ROOT_DISPUTE_WINDOW() + 1);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = l2;
        vm.prank(participant1);
        campaigns.claimERC20(id, amt1, proof1);
        assertEq(token.balanceOf(participant1), amt1);

        // Host attempts to cancel and instantly reclaim participant2's still-unclaimed allocation.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);

        // participant2 must still be able to claim.
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = l1;
        vm.prank(participant2);
        campaigns.claimERC20(id, amt2, proof2);
        assertEq(token.balanceOf(participant2), amt2);
    }

    /// @notice Same regression as above, on the NFT settlement path via NFTSettlementModule.
    /// totalParticipants never touches NFT settlement either -- a published NFT root with an
    /// unclaimed leaf must also block cancelCampaign.
    function test_CancelCampaign_RevertsIfNFTSettlementRootPublished_EvenWithZeroParticipants() public {
        MockERC721Cancel nft = new MockERC721Cancel();
        nft.mint(host1, 1);

        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft.approve(address(campaigns), 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        campaigns.depositERC721Rewards(id, address(nft), ids);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        // totalParticipants stays 0 -- an allowlist-based NFT drop, nobody calls completeTask.
        bytes32 root = keccak256(
            bytes.concat(keccak256(abi.encode(participant1, uint8(0), address(nft), uint256(1), uint256(1))))
        );
        vm.prank(host1);
        nftModule.setNFTMerkleRoot(id, root);

        // Host attempts to cancel and instantly sweep the NFT out from under the published root.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
                        DRAFT CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_CancelCampaign_Draft_NoReward_Success() public {
        (uint256 id,,) = _createCampaign();

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(id);
        assertEq(uint8(campaign.status), uint8(CampaignStorage.CampaignStatus.Cancelled));
    }

    function test_CancelCampaign_Draft_RefundsEscrowedERC20() public {
        (uint256 id,,) = _createCampaign();

        vm.startPrank(host1);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 500 ether);
        campaigns.fundCampaignERC20(id, 500 ether);
        vm.stopPrank();

        uint256 hostBalBefore = token.balanceOf(host1);
        assertEq(token.balanceOf(address(campaigns)), 500 ether);

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        assertEq(token.balanceOf(host1) - hostBalBefore, 500 ether);
        assertEq(token.balanceOf(address(campaigns)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_CancelCampaign_Open_ZeroParticipants_Success() public {
        (uint256 id, uint256 startTime,) = _createCampaign();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(id);
        assertEq(uint8(campaign.status), uint8(CampaignStorage.CampaignStatus.Cancelled));
    }

    /*//////////////////////////////////////////////////////////////
                    THE ABUSE VECTOR THIS CLOSES
    //////////////////////////////////////////////////////////////*/

    function test_CancelCampaign_RevertsOnceAParticipantHasEngaged() public {
        (uint256 id, uint256 startTime,) = _createCampaign();

        vm.prank(host1);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        // participant1 does the (free) work in good faith.
        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        // Host can no longer bail out to dodge paying a reward -- must run the campaign to
        // completion (Ended -> Closed) instead.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignHasParticipants.selector);
        campaigns.cancelCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
                        STATUS GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_CancelCampaign_RevertsIfEndedWithParticipants() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _createCampaign();

        vm.prank(host1);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        // Ended alone no longer blocks cancellation -- but a real participant still does.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignHasParticipants.selector);
        campaigns.cancelCampaign(id);
    }

    function test_CancelCampaign_RevertsIfClosed() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _createCampaign();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        campaigns.closeCampaign(id);

        // Once closed, the host has chosen the grace-period path -- no cancel escape hatch left.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
        ZERO-PARTICIPANT ENDED CANCELLATION (permissionless endCampaign fix)
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone (a keeper, in practice) can call endCampaign once endTime passes. A
    /// zero-participant campaign has nothing to protect, so the host must retain their immediate
    /// refund option regardless of who triggered the Ended transition -- otherwise a keeper
    /// sweeping expired campaigns would force every unpopular campaign's host into a needless
    /// 30-day closeCampaign -> withdrawUnclaimedERC20 wait for a refund cancelCampaign would give
    /// immediately.
    function test_CancelCampaign_Ended_ZeroParticipants_AfterKeeperEndsIt_Success() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _createCampaign();

        vm.startPrank(host1);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 500 ether);
        campaigns.fundCampaignERC20(id, 500 ether);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);

        vm.warp(endTime + 1);
        // A non-host keeper ends the campaign -- permissionless per PR #20.
        vm.prank(participant1);
        campaigns.endCampaign(id);

        Web3Campaigns.Campaign memory ended = campaigns.getCampaign(id);
        assertEq(uint8(ended.status), uint8(CampaignStorage.CampaignStatus.Ended));

        uint256 hostBalBefore = token.balanceOf(host1);

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        Web3Campaigns.Campaign memory cancelled = campaigns.getCampaign(id);
        assertEq(uint8(cancelled.status), uint8(CampaignStorage.CampaignStatus.Cancelled));
        assertEq(token.balanceOf(host1) - hostBalBefore, 500 ether);
    }

    function test_CancelCampaign_RevertsIfAlreadyCancelled() public {
        (uint256 id,,) = _createCampaign();

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);
    }

    function test_CancelCampaign_RevertsIfNotHost() public {
        (uint256 id,,) = _createCampaign();

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CallerIsNotHost.selector);
        campaigns.cancelCampaign(id);
    }

    function test_CancelCampaign_RevertsWhenPaused() public {
        (uint256 id,,) = _createCampaign();

        vm.prank(deployer);
        campaigns.emergencyPause();

        vm.prank(host1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        campaigns.cancelCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
                    NFT RECLAIM AFTER CANCEL (no grace wait)
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUnclaimedERC721_ImmediatelyAfterCancel_NoGraceWait() public {
        (uint256 id,,) = _createCampaign();

        // Reuse the NFT mock defined in NFTSettlement.t.sol.
        MockERC721Cancel nft = new MockERC721Cancel();
        nft.mint(host1, 1);

        vm.startPrank(host1);
        nft.approve(address(campaigns), 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        campaigns.depositERC721Rewards(id, address(nft), ids);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), address(campaigns));

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        // No grace-period wait required -- immediately reclaimable once Cancelled.
        vm.prank(host1);
        nftModule.withdrawUnclaimedERC721(id, address(nft), ids);

        assertEq(nft.ownerOf(1), host1);
    }
}

// Minimal local mock (kept separate from NFTSettlement.t.sol's MockERC721 to avoid cross-file
// name collisions when both are imported/compiled in the same test run).
contract MockERC721Cancel is ERC721 {
    constructor() ERC721("MockCancel721", "MC721") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
