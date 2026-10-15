// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test, stdError} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {NFTSettlementModule} from "../src/NFTSettlementModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721, MockERC1155} from "./NFTSettlement.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev An admin-registered NFT module that accepts deposits like a real one, but whose owner can
/// ask Web3Campaigns to move ANY escrowed token out "for" the campaign pinned to it.
contract RogueNFTModule {
    function recordERC721Deposit(uint256, address, uint256[] calldata, uint256) external {}

    function recordERC1155Deposit(uint256, address, uint256[] calldata, uint256[] calldata, uint256) external {}

    function getNFTMerkleRoot(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function steal(
        Web3Campaigns w3c,
        uint256 ownCampaignId,
        CampaignStorage.NFTStandard std,
        address token,
        uint256 tokenId,
        uint256 amount,
        address to
    ) external {
        w3c.executeNFTTransferOut(ownCampaignId, std, token, tokenId, amount, to);
    }
}

/// @notice Pre-production fixes (2026-10):
///  1. NFT custody: Web3Campaigns keeps its own per-campaign NFT ledger, so a module pinned to one
///     campaign can never move NFTs escrowed under another (parity with the ERC20 escrow ledger).
///  2. Host close: a host can't close a campaign that still owes a Merkle settlement (escrowed
///     ERC20 with no settlement mode committed, or deposited NFTs with no NFT root), which would
///     otherwise block every claim and the settler fallback, then let the host sweep 100% after
///     the grace period.
contract PreProdFixesTest is Test {
    Web3Campaigns public campaigns;
    NFTSettlementModule public nftModule;
    RogueNFTModule public rogue;
    ERC20Mock public token;
    MockERC721 public nft721;
    MockERC1155 public nft1155;

    address public deployer;
    address public victimHost;
    address public attacker;
    address public participant;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);
        deployer = makeAddr("deployer");
        victimHost = makeAddr("victimHost");
        attacker = makeAddr("attacker");
        participant = makeAddr("participant");

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        nftModule = new NFTSettlementModule(address(campaigns));
        campaigns.setNFTSettlementModule(address(nftModule));
        campaigns.grantHostRole(victimHost);
        campaigns.grantHostRole(attacker);
        vm.stopPrank();

        rogue = new RogueNFTModule();
        token = new ERC20Mock();
        nft721 = new MockERC721();
        nft1155 = new MockERC1155();

        token.mint(victimHost, 1_000 ether);
        nft721.mint(victimHost, 1);
        nft721.mint(attacker, 99);
        nft1155.mint(victimHost, 7, 100);
        nft1155.mint(attacker, 7, 1);
    }

    function _create(address host) internal returns (uint256 id, uint256 startTime, uint256 endTime) {
        startTime = block.timestamp + START_OFFSET;
        endTime = startTime + DURATION;
        vm.prank(host);
        id = campaigns.createCampaign("C", startTime, endTime);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _openAndEnd(address host, uint256 id, uint256 startTime, uint256 endTime) internal {
        vm.warp(startTime + 1);
        vm.prank(host);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);
    }

    /// Victim campaign A escrows NFTs under the legit module; the admin then registers a rogue
    /// module, and the attacker pins it to a fresh campaign B by depositing a token of their own.
    function _victimAndRogueCampaigns() internal returns (uint256 a, uint256 b) {
        (a,,) = _create(victimHost);
        vm.startPrank(victimHost);
        nft721.setApprovalForAll(address(campaigns), true);
        nft1155.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(a, address(nft721), _one(1));
        campaigns.depositERC1155Rewards(a, address(nft1155), _one(7), _one(100));
        vm.stopPrank();

        vm.prank(deployer);
        campaigns.setNFTSettlementModule(address(rogue));

        (b,,) = _create(attacker);
        vm.startPrank(attacker);
        nft721.setApprovalForAll(address(campaigns), true);
        nft1155.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(b, address(nft721), _one(99));
        campaigns.depositERC1155Rewards(b, address(nft1155), _one(7), _one(1));
        vm.stopPrank();
        assertEq(campaigns.getCampaignNFTModule(b), address(rogue));
        assertEq(campaigns.getCampaignNFTModule(a), address(nftModule));
    }

    /*//////////////////////////////////////////////////////////////
                         1. NFT CUSTODY ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_NFTCustody_RogueModuleCannotMoveAnotherCampaignsERC721() public {
        (, uint256 b) = _victimAndRogueCampaigns();

        vm.expectRevert(stdError.arithmeticError);
        rogue.steal(campaigns, b, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, attacker);
        assertEq(nft721.ownerOf(1), address(campaigns));
    }

    function test_NFTCustody_RogueModuleCannotMoveMoreERC1155ThanItsCampaignEscrowed() public {
        (, uint256 b) = _victimAndRogueCampaigns();

        // B escrowed 1 unit of id 7; A escrowed 100 of the same id. B can't take A's 100.
        vm.expectRevert(stdError.arithmeticError);
        rogue.steal(campaigns, b, CampaignStorage.NFTStandard.ERC1155, address(nft1155), 7, 2, attacker);
        assertEq(nft1155.balanceOf(address(campaigns), 7), 101);
    }

    function test_NFTCustody_RogueModuleCanOnlyMoveItsOwnCampaignsTokens() public {
        (, uint256 b) = _victimAndRogueCampaigns();

        // The rogue module still controls what was deposited under ITS campaign -- that's the
        // pin's documented trust boundary -- but nothing more.
        rogue.steal(campaigns, b, CampaignStorage.NFTStandard.ERC721, address(nft721), 99, 1, attacker);
        rogue.steal(campaigns, b, CampaignStorage.NFTStandard.ERC1155, address(nft1155), 7, 1, attacker);
        assertEq(nft721.ownerOf(99), attacker);
        assertEq(nft1155.balanceOf(attacker, 7), 1);

        vm.expectRevert(stdError.arithmeticError);
        rogue.steal(campaigns, b, CampaignStorage.NFTStandard.ERC721, address(nft721), 99, 1, attacker);
    }

    /*//////////////////////////////////////////////////////////////
                    2. HOST CLOSE REQUIRES SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function _endedFundedERC20(uint256 amount) internal returns (uint256 id) {
        uint256 s;
        uint256 e;
        (id, s, e) = _create(victimHost);
        vm.startPrank(victimHost);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), amount);
        campaigns.fundCampaignERC20(id, amount);
        vm.stopPrank();
        _openAndEnd(victimHost, id, s, e);
    }

    function _endedWithNFT() internal returns (uint256 id) {
        uint256 s;
        uint256 e;
        (id, s, e) = _create(victimHost);
        vm.startPrank(victimHost);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), _one(1));
        vm.stopPrank();
        _openAndEnd(victimHost, id, s, e);
    }

    function test_HostClose_RevertsWithEscrowedERC20AndNoRoot() public {
        uint256 id = _endedFundedERC20(100 ether);

        vm.prank(victimHost);
        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementNotPublished.selector);
        campaigns.closeCampaign(id);
    }

    function test_HostClose_RevertsWithDepositedNFTAndNoRoot() public {
        uint256 id = _endedWithNFT();

        vm.prank(victimHost);
        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementNotPublished.selector);
        campaigns.closeCampaign(id);
    }

    function test_HostClose_WorksOnceERC20RootPublished() public {
        uint256 id = _endedFundedERC20(100 ether);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(participant, uint256(100 ether)))));

        vm.startPrank(victimHost);
        campaigns.setERC20MerkleRoot(id, leaf);
        campaigns.closeCampaign(id);
        vm.stopPrank();
        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    function test_HostClose_WorksOnceNFTRootPublished() public {
        uint256 id = _endedWithNFT();
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(participant, uint8(CampaignStorage.NFTStandard.ERC721), address(nft721), 1, uint256(1))
                )
            )
        );

        vm.startPrank(victimHost);
        nftModule.setNFTMerkleRoot(id, leaf);
        campaigns.closeCampaign(id);
        vm.stopPrank();
        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    function test_HostClose_StillWorksWithNoOnChainRewards() public {
        (uint256 id, uint256 s, uint256 e) = _create(victimHost);
        _openAndEnd(victimHost, id, s, e);

        vm.prank(victimHost);
        campaigns.closeCampaign(id);
        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    function test_HostClose_MixedRewardsNeedBothRoots() public {
        uint256 s;
        uint256 e;
        uint256 id;
        (id, s, e) = _create(victimHost);
        vm.startPrank(victimHost);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), _one(1));
        vm.stopPrank();
        _openAndEnd(victimHost, id, s, e);

        vm.startPrank(victimHost);
        campaigns.setERC20MerkleRoot(id, keccak256("erc20 list"));
        // The NFT winners are still owed a list.
        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementNotPublished.selector);
        campaigns.closeCampaign(id);

        nftModule.setNFTMerkleRoot(id, keccak256("nft list"));
        campaigns.closeCampaign(id);
        vm.stopPrank();
    }

    function test_SettlerClose_AlsoNeedsEveryOwedRoot() public {
        address settler = makeAddr("settler");
        bytes32 settlerRole = campaigns.SETTLER_ROLE();
        vm.prank(deployer);
        campaigns.grantRole(settlerRole, settler);

        uint256 s;
        uint256 e;
        uint256 id;
        (id, s, e) = _create(victimHost);
        vm.startPrank(victimHost);
        campaigns.configureERC20Reward(id, address(token));
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), _one(1));
        vm.stopPrank();
        _openAndEnd(victimHost, id, s, e);

        vm.warp(e + 14 days + 1);
        vm.startPrank(settler);
        campaigns.setERC20MerkleRoot(id, keccak256("erc20 list"));
        // Before this fix one published root was enough for a settler close, stranding NFT winners.
        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementNotPublished.selector);
        campaigns.closeCampaign(id);

        nftModule.setNFTMerkleRoot(id, keccak256("nft list"));
        campaigns.closeCampaign(id);
        vm.stopPrank();
        assertEq(uint8(campaigns.getCampaign(id).status), uint8(CampaignStorage.CampaignStatus.Closed));
    }

    function test_HostClose_IdleFundedCampaignUsesCancelInstead() public {
        // A zero-participant, never-settled campaign isn't trapped: cancel refunds it at once.
        uint256 id = _endedFundedERC20(100 ether);
        uint256 before = token.balanceOf(victimHost);

        vm.prank(victimHost);
        campaigns.cancelCampaign(id);
        assertEq(token.balanceOf(victimHost), before + 100 ether);
    }
}

/// @notice The string-revert → custom-error conversion that paid for the fixes above
/// (-654 B of Web3Campaigns runtime). Behaviour is unchanged; only the revert data differs.
contract CustomErrorConversionTest is Test {
    Web3Campaigns public campaigns;
    address public deployer = makeAddr("deployer");
    address public host = makeAddr("host");

    function setUp() public {
        vm.warp(1_000_000);
        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        campaigns.grantHostRole(host);
        vm.stopPrank();
    }

    function _campaign() internal returns (uint256) {
        vm.prank(host);
        return campaigns.createCampaign("C", block.timestamp + 1 days, block.timestamp + 8 days);
    }

    function test_CreateCampaign_EmptyName_InvalidTextLength() public {
        vm.prank(host);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidTextLength.selector);
        campaigns.createCampaign("", block.timestamp + 1 days, block.timestamp + 8 days);
    }

    function test_AddTask_EmptyDescription_InvalidTextLength() public {
        uint256 id = _campaign();
        vm.prank(host);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidTextLength.selector);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "", "", false);
    }

    function test_AddTask_TwentyFirst_TooManyTasks() public {
        uint256 id = _campaign();
        vm.startPrank(host);
        for (uint256 i; i < 20; ++i) {
            campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "t", "", false);
        }
        vm.expectRevert(CampaignStorage.Web3Campaigns__TooManyTasks.selector);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "t", "", false);
        vm.stopPrank();
    }

    function test_HostOnlyCall_WhilePaused_EnforcedPause() public {
        uint256 id = _campaign();
        vm.prank(deployer);
        campaigns.emergencyPause();
        vm.prank(host);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "t", "", false);
    }

    function test_CompleteTask_AfterEndTime_NotInActivePeriod() public {
        uint256 id = _campaign();
        vm.prank(host);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "t", "", false);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(host);
        campaigns.openCampaign(id);
        vm.warp(block.timestamp + 8 days);

        vm.prank(makeAddr("participant"));
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotInActivePeriod.selector);
        campaigns.completeTask(id, 0);
    }

    function test_UnknownSelector_Reverts() public {
        (bool ok, bytes memory data) = address(campaigns).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        assertEq(data.length, 0);
        (ok,) = address(campaigns).call{value: 1}(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }

    function test_Receive_ZeroValue_InvalidAmount() public {
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidAmount.selector);
        (bool ok,) = address(campaigns).call{value: 0}("");
        ok;
    }
}
