// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {OnChainRewardModule} from "../src/OnChainRewardModule.sol";
import {MockERC721} from "./NFTSettlement.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Covers the sponsored (gasless) claim entrypoints: claimERC20For, claimNFTFor, and
/// claimRewardFor. Anyone -- in practice the project backend, which pays the gas -- can submit a
/// claim ON BEHALF OF an allocated account; the reward is ALWAYS delivered to that account, never
/// the caller. Each sponsored path shares its full body (checks/effects/payout) with the
/// self-claim path, so these tests focus on the delivery/authorization semantics plus spot-checks
/// that the shared guards (double-claim, proof, dispute window, pause) fire identically.
contract SponsoredClaimsTest is Test {
    Web3Campaigns public campaigns;
    NFTSettlementModule public nftModule;
    OnChainRewardModule public rewardModule;
    ERC20Mock public token;
    MockERC721 public nft721;

    address public deployer;
    address public host1;
    address public p1;
    address public sponsor; // the gas-paying backend wallet

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        p1 = vm.addr(4);
        sponsor = vm.addr(9);

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        nftModule = new NFTSettlementModule(address(campaigns));
        campaigns.setNFTSettlementModule(address(nftModule));
        rewardModule = new OnChainRewardModule(address(campaigns));
        campaigns.setOnChainRewardModule(address(rewardModule));
        campaigns.grantHostRole(host1);
        vm.stopPrank();

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);
        nft721 = new MockERC721();
        nft721.mint(host1, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            SETUP HELPERS
    //////////////////////////////////////////////////////////////*/

    function _erc20Leaf(address acct, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, amt))));
    }

    function _nftLeaf(address acct, uint8 std, address tok, uint256 tokenId, uint256 amt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, std, tok, tokenId, amt))));
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /// @dev ERC20 Merkle campaign settled with a single-leaf root allocating `amount` to p1.
    /// Ends past the dispute window unless `skipWindowWait` is false.
    function _settledERC20Campaign(uint256 amount, bool waitOutWindow) internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), amount);
        campaigns.fundCampaignERC20(id, amount);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, _erc20Leaf(p1, amount));

        if (waitOutWindow) {
            vm.warp(block.timestamp + campaigns.ROOT_DISPUTE_WINDOW() + 1);
        }
    }

    /// @dev NFT campaign settled with a single-leaf root allocating tokenId 1 to p1, past window.
    function _settledNFTCampaign() internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
        nft721.setApprovalForAll(address(campaigns), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        campaigns.depositERC721Rewards(id, address(nft721), ids);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(host1);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(p1, 0, address(nft721), 1, 1));

        vm.warp(block.timestamp + campaigns.ROOT_DISPUTE_WINDOW() + 1);
    }

    /// @dev RANK_TIERED campaign where p1 completed the task (rank 1, top tier = 100 ether), ended.
    function _endedRankTieredCampaign() internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
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
    }

    /*//////////////////////////////////////////////////////////////
                            claimERC20For
    //////////////////////////////////////////////////////////////*/

    function test_ClaimERC20For_PaysAllocatedAccountNotCaller() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        vm.prank(sponsor);
        campaigns.claimERC20For(id, p1, 100 ether, _emptyProof());

        assertEq(token.balanceOf(p1), 100 ether);
        assertEq(token.balanceOf(sponsor), 0);
        assertTrue(campaigns.hasClaimedERC20(id, p1));
    }

    function test_ClaimERC20For_SponsoredClaimBlocksLaterSelfClaim() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        vm.prank(sponsor);
        campaigns.claimERC20For(id, p1, 100 ether, _emptyProof());

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        campaigns.claimERC20(id, 100 ether, _emptyProof());
    }

    function test_ClaimERC20For_SelfClaimBlocksLaterSponsoredClaim() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        vm.prank(p1);
        campaigns.claimERC20(id, 100 ether, _emptyProof());

        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        campaigns.claimERC20For(id, p1, 100 ether, _emptyProof());
    }

    function test_ClaimERC20For_RevertsForNonAllocatedAccount() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        // The root commits to p1; claiming "for" the sponsor itself must fail proof verification.
        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidMerkleProof.selector);
        campaigns.claimERC20For(id, sponsor, 100 ether, _emptyProof());
    }

    function test_ClaimERC20For_RevertsOnZeroAccount() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__ZeroAddress.selector);
        campaigns.claimERC20For(id, address(0), 100 ether, _emptyProof());
    }

    function test_ClaimERC20For_RespectsDisputeWindow() public {
        uint256 id = _settledERC20Campaign(100 ether, false); // window still active

        uint256 claimableAt = campaigns.getERC20ClaimableAt(id);
        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(CampaignStorage.Web3Campaigns__RootDisputeWindowActive.selector, id, claimableAt)
        );
        campaigns.claimERC20For(id, p1, 100 ether, _emptyProof());
    }

    function test_ClaimERC20For_RevertsWhenPaused() public {
        uint256 id = _settledERC20Campaign(100 ether, true);

        vm.prank(deployer);
        campaigns.emergencyPause();

        vm.prank(sponsor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        campaigns.claimERC20For(id, p1, 100 ether, _emptyProof());
    }

    /*//////////////////////////////////////////////////////////////
                             claimNFTFor
    //////////////////////////////////////////////////////////////*/

    function test_ClaimNFTFor_DeliversToAllocatedAccountNotCaller() public {
        uint256 id = _settledNFTCampaign();

        vm.prank(sponsor);
        nftModule.claimNFTFor(id, p1, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        assertEq(nft721.ownerOf(1), p1);
        assertFalse(nftModule.isERC721Escrowed(id, address(nft721), 1));
    }

    function test_ClaimNFTFor_SponsoredClaimBlocksLaterSelfClaim() public {
        uint256 id = _settledNFTCampaign();

        vm.prank(sponsor);
        nftModule.claimNFTFor(id, p1, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        nftModule.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    function test_ClaimNFTFor_RevertsForNonAllocatedAccount() public {
        uint256 id = _settledNFTCampaign();

        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidMerkleProof.selector);
        nftModule.claimNFTFor(id, sponsor, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    function test_ClaimNFTFor_RevertsOnZeroAccount() public {
        uint256 id = _settledNFTCampaign();

        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__ZeroAddress.selector);
        nftModule.claimNFTFor(id, address(0), CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    function test_ClaimNFTFor_RevertsWhenPaused() public {
        uint256 id = _settledNFTCampaign();

        vm.prank(deployer);
        campaigns.emergencyPause();

        // Pause coverage flows through the downstream executeNFTTransferOut, same as claimNFT
        // (see the PR #11 pause tests) -- confirm the sponsored path inherits it.
        vm.prank(sponsor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nftModule.claimNFTFor(id, p1, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        assertTrue(nftModule.isERC721Escrowed(id, address(nft721), 1));
    }

    /*//////////////////////////////////////////////////////////////
                            claimRewardFor
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRewardFor_PaysParticipantNotCaller() public {
        uint256 id = _endedRankTieredCampaign();

        vm.prank(sponsor);
        rewardModule.claimRewardFor(id, p1);

        assertEq(token.balanceOf(p1), 100 ether);
        assertEq(token.balanceOf(sponsor), 0);
    }

    function test_ClaimRewardFor_SponsoredClaimBlocksLaterSelfClaim() public {
        uint256 id = _endedRankTieredCampaign();

        vm.prank(sponsor);
        rewardModule.claimRewardFor(id, p1);

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        rewardModule.claimReward(id);
    }

    function test_ClaimRewardFor_RevertsForUnqualifiedParticipant() public {
        uint256 id = _endedRankTieredCampaign();

        // The sponsor itself never completed the task -- a sponsored claim cannot conjure a
        // reward for a non-participant (RANK_TIERED requires current qualification).
        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotFullyCompleted.selector);
        rewardModule.claimRewardFor(id, sponsor);
    }

    function test_ClaimRewardFor_RevertsOnZeroAccount() public {
        uint256 id = _endedRankTieredCampaign();

        vm.prank(sponsor);
        vm.expectRevert(CampaignStorage.Web3Campaigns__ZeroAddress.selector);
        rewardModule.claimRewardFor(id, address(0));
    }
}
