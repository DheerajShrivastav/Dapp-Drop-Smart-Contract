// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock721", "M721") {}
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("ipfs://mock/{id}") {}
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @notice Covers Stage B2: multi-standard NFT (ERC721 + ERC1155) escrow + Merkle settlement.
contract NFTSettlementTest is Test {
    Web3Campaigns public campaigns;
    MockERC721 public nft721;
    MockERC1155 public nft1155;

    address public deployer;
    address public host1;
    address public attacker;
    address public p1;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;
    uint256 constant GRACE = 30 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        attacker = vm.addr(3);
        p1 = vm.addr(4);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        nft721 = new MockERC721();
        nft1155 = new MockERC1155();

        nft721.mint(host1, 1);
        nft721.mint(host1, 2);
        nft1155.mint(host1, 1, 100);

        vm.startPrank(deployer);
        campaigns.grantHostRole(host1);
        campaigns.grantHostRole(attacker);
        vm.stopPrank();
    }

    // --- leaf / proof helpers (OZ StandardMerkleTree convention) ---

    function _nftLeaf(
        address acct,
        uint8 std,
        address token,
        uint256 tokenId,
        uint256 amount
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(acct, std, token, tokenId, amount))));
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // --- arrays helpers ---
    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    /// @dev create -> deposit ERC721 ids -> open -> end -> set root. host1 is the host.
    function _setup721(uint256[] memory tokenIds, bytes32 root) internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), tokenIds);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);
        vm.prank(host1);
        campaigns.setNFTMerkleRoot(id, root);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimERC721_Success() public {
        bytes32 root = _nftLeaf(p1, 0, address(nft721), 1, 1);
        uint256 id = _setup721(_ids(1), root);

        assertTrue(campaigns.isERC721Escrowed(id, address(nft721), 1));
        assertEq(nft721.ownerOf(1), address(campaigns));

        vm.prank(p1);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        assertEq(nft721.ownerOf(1), p1);
        assertFalse(campaigns.isERC721Escrowed(id, address(nft721), 1));
    }

    function test_ClaimERC721_RevertsOnDoubleClaim() public {
        bytes32 root = _nftLeaf(p1, 0, address(nft721), 1, 1);
        uint256 id = _setup721(_ids(1), root);

        vm.prank(p1);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    function test_ClaimERC721_RevertsOnBadProof() public {
        bytes32 root = _nftLeaf(p1, 0, address(nft721), 1, 1);
        uint256 id = _setup721(_ids(1), root);

        // Wrong tokenId in the claim -> leaf not in tree.
        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidMerkleProof.selector);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 2, 1, _emptyProof());
    }

    function test_ClaimERC721_RevertsBeforeRootSet() public {
        // Build ended campaign without setting a root.
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), _ids(1));
        vm.stopPrank();
        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__MerkleRootNotSet.selector);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    /// @dev A campaign cannot settle an NFT it never escrowed (cross-campaign drain guard).
    function test_ClaimNFT_CannotDrainNonEscrowedToken() public {
        // host1's campaign A escrows tokenId 1.
        _setup721(_ids(1), _nftLeaf(p1, 0, address(nft721), 1, 1));

        // attacker creates campaign B, escrows NOTHING, but publishes a root referencing tokenId 1.
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;
        vm.prank(attacker);
        uint256 idB = campaigns.createCampaign("B", startTime, endTime);
        vm.warp(startTime + 1);
        vm.prank(attacker);
        campaigns.openCampaign(idB);
        vm.warp(endTime + 1);
        vm.prank(attacker);
        campaigns.endCampaign(idB);
        bytes32 rootB = _nftLeaf(attacker, 0, address(nft721), 1, 1);
        vm.prank(attacker);
        campaigns.setNFTMerkleRoot(idB, rootB);

        // Valid proof for campaign B's tree, but the token isn't escrowed under B.
        vm.prank(attacker);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NFTNotEscrowed.selector);
        campaigns.claimNFT(idB, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());
    }

    /*//////////////////////////////////////////////////////////////
                              ERC1155 CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimERC1155_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft1155.setApprovalForAll(address(campaigns), true);
        uint256[] memory ids = _ids(1);
        uint256[] memory amts = _ids(100);
        campaigns.depositERC1155Rewards(id, address(nft1155), ids, amts);
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        bytes32 root = _nftLeaf(p1, 1, address(nft1155), 1, 30);
        vm.prank(host1);
        campaigns.setNFTMerkleRoot(id, root);

        assertEq(campaigns.getERC1155Escrowed(id, address(nft1155), 1), 100);

        vm.prank(p1);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC1155, address(nft1155), 1, 30, _emptyProof());

        assertEq(nft1155.balanceOf(p1, 1), 30);
        assertEq(nft1155.balanceOf(address(campaigns), 1), 70);
        assertEq(campaigns.getERC1155Escrowed(id, address(nft1155), 1), 70);
    }

    function test_ClaimERC1155_RevertsIfExceedsEscrow() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        nft1155.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC1155Rewards(id, address(nft1155), _ids(1), _ids(10)); // only 10 escrowed
        vm.stopPrank();

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);

        bytes32 root = _nftLeaf(p1, 1, address(nft1155), 1, 50); // tree over-allocates
        vm.prank(host1);
        campaigns.setNFTMerkleRoot(id, root);

        vm.prank(p1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NFTNotEscrowed.selector);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC1155, address(nft1155), 1, 50, _emptyProof());
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT / SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_DepositERC721_RecordsEscrowAndCustody() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.startPrank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        nft721.setApprovalForAll(address(campaigns), true);
        campaigns.depositERC721Rewards(id, address(nft721), _ids2(1, 2));
        vm.stopPrank();

        assertTrue(campaigns.isERC721Escrowed(id, address(nft721), 1));
        assertTrue(campaigns.isERC721Escrowed(id, address(nft721), 2));
        assertEq(nft721.ownerOf(1), address(campaigns));
        assertEq(nft721.ownerOf(2), address(campaigns));
    }

    function test_WithdrawUnclaimedERC721_AfterGrace() public {
        // Escrow 2 NFTs, allocate only tokenId 1; tokenId 2 should be sweepable.
        bytes32 root = _nftLeaf(p1, 0, address(nft721), 1, 1);
        uint256 id = _setup721(_ids2(1, 2), root);

        vm.prank(p1);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), 1, 1, _emptyProof());

        vm.prank(host1);
        campaigns.closeCampaign(id);

        // Before grace -> revert.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__GracePeriodActive.selector);
        campaigns.withdrawUnclaimedERC721(id, address(nft721), _ids(2));

        vm.warp(block.timestamp + GRACE + 1);
        vm.prank(host1);
        campaigns.withdrawUnclaimedERC721(id, address(nft721), _ids(2));

        assertEq(nft721.ownerOf(2), host1);
        // Claimed token can't be swept.
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NFTNotEscrowed.selector);
        campaigns.withdrawUnclaimedERC721(id, address(nft721), _ids(1));
    }

    function test_SetNFTMerkleRoot_RevertsIfNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.prank(host1);
        uint256 id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.setNFTMerkleRoot(id, bytes32(uint256(1)));
    }
}
