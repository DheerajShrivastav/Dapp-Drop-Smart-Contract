// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721} from "./NFTSettlement.t.sol";

/// @notice Covers the SETTLER_ROLE time-gated fallback settlement path for abandoned Merkle
/// campaigns: setERC20MerkleRoot / NFTSettlementModule.setNFTMerkleRoot / closeCampaign all accept
/// a SETTLER_ROLE caller once a campaign has been Ended for SETTLEMENT_FALLBACK_DELAY (14 days)
/// with no settlement ever committed -- a settler can only ever fill a vacuum, never override a
/// root the host already published, and the host retains full authority at all times (a republish
/// after a settler acted works exactly as before). See docs/SECURITY_FINDINGS.md.
contract SettlerFallbackTest is Test {
    Web3Campaigns public campaigns;
    NFTSettlementModule public nftModule;
    ERC20Mock public token;
    MockERC721 public nft721;

    address public deployer;
    address public host1;
    address public settler;
    address public attacker;
    address public participant1;
    address public participant2;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;
    // Mirrors CampaignStorage's internal SETTLEMENT_FALLBACK_DELAY -- not publicly readable
    // on-chain (internal, kept off the entrypoint's ABI purely for bytecode headroom), so tests
    // hardcode the same value. Keep in sync if that constant is ever tuned.
    uint256 constant SETTLEMENT_FALLBACK_DELAY = 14 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        settler = vm.addr(3);
        attacker = vm.addr(4);
        participant1 = vm.addr(5);
        participant2 = vm.addr(6);

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        campaigns.grantHostRole(host1);
        campaigns.grantRole(campaigns.SETTLER_ROLE(), settler);
        vm.stopPrank();

        nftModule = new NFTSettlementModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setNFTSettlementModule(address(nftModule));

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);

        nft721 = new MockERC721();
    }

    function _leaf(address acct, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, amt))));
    }

    function _nftLeaf(address acct, address token_, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(acct, uint8(CampaignStorage.NFTStandard.ERC721), token_, tokenId, uint256(1)))
            )
        );
    }

    /// @dev Create -> fund -> open -> end an ERC20 campaign. Returns id and endTime. Does NOT
    /// publish a root -- that's left to the individual tests below, simulating an abandoned
    /// campaign at the point endCampaign (permissionless) has already run.
    function _endedERC20Campaign(uint256 fundAmount) internal returns (uint256 id, uint256 endTime) {
        uint256 startTime = block.timestamp + START_OFFSET;
        endTime = startTime + CAMPAIGN_DURATION;

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
    }

    function _endedNFTCampaign(uint256 tokenId) internal returns (uint256 id, uint256 endTime) {
        uint256 startTime = block.timestamp + START_OFFSET;
        endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
        nft721.mint(host1, tokenId);
        nft721.approve(address(campaigns), tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        campaigns.depositERC721Rewards(id, address(nft721), ids);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC20 PATH -- setERC20MerkleRoot
    //////////////////////////////////////////////////////////////*/

    function test_SetERC20MerkleRoot_SettlerCanPublish_ExactlyUnderGate() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        bytes32 root = _leaf(participant1, 100 ether);
        vm.expectEmit(true, true, false, true, address(campaigns));
        emit CampaignStorage.ERC20MerkleRootSet(id, root);
        vm.expectEmit(true, true, false, false, address(campaigns));
        emit CampaignStorage.FallbackRootPublished(id, settler);

        vm.prank(settler);
        campaigns.setERC20MerkleRoot(id, root);

        (,,, bytes32 storedRoot,,) = campaigns.getERC20Settlement(id);
        assertEq(storedRoot, root);
    }

    function test_SetERC20MerkleRoot_Settler_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.prank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 1));
    }

    function test_SetERC20MerkleRoot_Settler_RevertsIfRootAlreadyPublishedByHost() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__RootAlreadyPublished.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant2, 100 ether));
    }

    function test_SetERC20MerkleRoot_Settler_RevertsIfRootAlreadyPublishedBySettler() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.prank(settler);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__RootAlreadyPublished.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant2, 100 ether));
    }

    function test_SetERC20MerkleRoot_Settler_RevertsIfDelayNotElapsed() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY - 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__FallbackDelayNotElapsed.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));
    }

    function test_SetERC20MerkleRoot_RevertsIfCallerLacksRole() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(attacker);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CallerIsNotHost.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));
    }

    /// @notice The host retains full authority at all times: after a settler fills the vacuum, the
    /// host can still republish (e.g. to correct an allocation), and a genuinely different root
    /// still restarts the dispute window exactly as it would with no settler ever involved.
    function test_SetERC20MerkleRoot_HostRepublishAfterSettler_Works_AndRestartsDisputeWindow() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        bytes32 settlerRoot = _leaf(participant1, 100 ether);
        vm.prank(settler);
        campaigns.setERC20MerkleRoot(id, settlerRoot);
        uint256 claimableAtAfterSettler = campaigns.getERC20ClaimableAt(id);

        vm.warp(block.timestamp + 1 hours);
        bytes32 hostRoot = _leaf(participant2, 100 ether);
        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, hostRoot);

        (,,, bytes32 storedRoot,,) = campaigns.getERC20Settlement(id);
        assertEq(storedRoot, hostRoot);
        assertGt(campaigns.getERC20ClaimableAt(id), claimableAtAfterSettler);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 PATH -- closeCampaign
    //////////////////////////////////////////////////////////////*/

    function test_CloseCampaign_SettlerCanClose_ExactlyUnderGate() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.expectEmit(true, false, false, true, address(campaigns));
        emit CampaignStorage.CampaignStatusUpdated(id, CampaignStorage.CampaignStatus.Closed);
        vm.expectEmit(true, true, false, false, address(campaigns));
        emit CampaignStorage.FallbackClosed(id, settler);

        vm.prank(settler);
        campaigns.closeCampaign(id);

        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    function test_CloseCampaign_Settler_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.prank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.closeCampaign(id);
    }

    function test_CloseCampaign_Settler_RevertsIfNoRootPublished() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementNotPublished.selector);
        campaigns.closeCampaign(id);
    }

    function test_CloseCampaign_Settler_RevertsIfDelayNotElapsed() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY - 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__FallbackDelayNotElapsed.selector);
        campaigns.closeCampaign(id);
    }

    function test_CloseCampaign_RevertsIfCallerLacksRole() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);

        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(attacker);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CallerIsNotHost.selector);
        campaigns.closeCampaign(id);
    }

    /// @notice A settler-published NFT root also satisfies closeCampaign's "some root exists"
    /// gate, even with zero ERC20 settlement on the campaign.
    function test_CloseCampaign_Settler_EligibleViaNFTRootAlone() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));

        vm.prank(settler);
        campaigns.closeCampaign(id);

        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    /*//////////////////////////////////////////////////////////////
        INTERACTION WITH cancelCampaign's SETTLEMENT-COMMITMENT GUARD
    //////////////////////////////////////////////////////////////*/

    /// @notice A settler-published ERC20 root must count as committed settlement, exactly like a
    /// host-published one -- a returning host cannot cancel out from under it. Composes with both
    /// recent cancelCampaign fixes (Ended-state acceptance + settlement-commitment guard).
    function test_CancelCampaign_RevertsAfterSettlerPublishesERC20Root() public {
        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.prank(settler);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);
    }

    /// @notice Same composition check on the NFT path.
    function test_CancelCampaign_RevertsAfterSettlerPublishesNFTRoot() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.prank(settler);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotCancellable.selector);
        campaigns.cancelCampaign(id);
    }

    /// @notice A genuinely abandoned, zero-settlement campaign (settler never acted either) is
    /// still cancellable by the host at any time before the fallback delay -- SETTLER_ROLE existing
    /// does not change the zero-participant/zero-settlement cancellation path at all.
    function test_CancelCampaign_StillWorks_WhenSettlerNeverActed() public {
        (uint256 id,) = _endedERC20Campaign(100 ether);

        vm.prank(host1);
        campaigns.cancelCampaign(id);

        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Cancelled));
    }

    /*//////////////////////////////////////////////////////////////
                    NFT PATH -- NFTSettlementModule.setNFTMerkleRoot
    //////////////////////////////////////////////////////////////*/

    function test_SetNFTMerkleRoot_SettlerCanPublish_ExactlyUnderGate() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        bytes32 root = _nftLeaf(participant1, address(nft721), 1);
        vm.expectEmit(true, false, false, true, address(nftModule));
        emit NFTSettlementModule.NFTMerkleRootSet(id, root);
        vm.expectEmit(true, true, false, false, address(nftModule));
        emit NFTSettlementModule.FallbackRootPublished(id, settler);

        vm.prank(settler);
        nftModule.setNFTMerkleRoot(id, root);

        assertEq(nftModule.getNFTMerkleRoot(id), root);
    }

    function test_SetNFTMerkleRoot_Settler_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft721.mint(host1, 2);
        nft721.approve(address(campaigns), 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        campaigns.depositERC721Rewards(id, address(nft721), ids);
        vm.stopPrank();

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 2));
    }

    function test_SetNFTMerkleRoot_Settler_RevertsIfRootAlreadyPublishedByHost() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);

        vm.prank(host1);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__RootAlreadyPublished.selector);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant2, address(nft721), 1));
    }

    function test_SetNFTMerkleRoot_Settler_RevertsIfDelayNotElapsed() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY - 1);
        vm.prank(settler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__FallbackDelayNotElapsed.selector);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));
    }

    function test_SetNFTMerkleRoot_RevertsIfCallerLacksRole() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);

        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);
        vm.prank(attacker);
        vm.expectRevert(NFTSettlementModule.NFTSettlementModule__NotCampaignHost.selector);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));
    }

    function test_SetNFTMerkleRoot_HostRepublishAfterSettler_Works() public {
        (uint256 id, uint256 endTime) = _endedNFTCampaign(1);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.prank(settler);
        nftModule.setNFTMerkleRoot(id, _nftLeaf(participant1, address(nft721), 1));

        bytes32 hostRoot = _nftLeaf(participant2, address(nft721), 1);
        vm.prank(host1);
        nftModule.setNFTMerkleRoot(id, hostRoot);

        assertEq(nftModule.getNFTMerkleRoot(id), hostRoot);
    }

    /*//////////////////////////////////////////////////////////////
                    ROLE MANAGEMENT (grant / revoke by admin)
    //////////////////////////////////////////////////////////////*/

    function test_SettlerRole_GrantAndRevoke_ByAdmin() public {
        bytes32 settlerRole = campaigns.SETTLER_ROLE();
        address newSettler = vm.addr(7);
        assertFalse(campaigns.hasRole(settlerRole, newSettler));

        vm.prank(deployer);
        campaigns.grantRole(settlerRole, newSettler);
        assertTrue(campaigns.hasRole(settlerRole, newSettler));

        (uint256 id, uint256 endTime) = _endedERC20Campaign(100 ether);
        vm.warp(endTime + SETTLEMENT_FALLBACK_DELAY + 1);

        vm.prank(deployer);
        campaigns.revokeRole(settlerRole, newSettler);
        assertFalse(campaigns.hasRole(settlerRole, newSettler));

        vm.prank(newSettler);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CallerIsNotHost.selector);
        campaigns.setERC20MerkleRoot(id, _leaf(participant1, 100 ether));
    }

    function test_SettlerRole_OnlyAdminCanGrant() public {
        bytes32 settlerRole = campaigns.SETTLER_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        campaigns.grantRole(settlerRole, attacker);
    }

    function test_DeployerHasSettlerRole_FromConstructor() public view {
        assertTrue(campaigns.hasRole(campaigns.SETTLER_ROLE(), deployer));
    }
}
