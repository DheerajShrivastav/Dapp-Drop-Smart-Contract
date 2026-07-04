// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {MockERC721, MockERC1155} from "../NFTSettlement.t.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice Stateful-fuzz handler driving the multi-standard NFT escrow + Merkle settlement
///         lifecycle across many campaigns, to check inventory can never be over-claimed or
///         cross-campaign drained.
///
/// ERC721: each campaign gets one freshly-minted, unique tokenId (ownership itself is the ground
/// truth — a tokenId can only ever be escrowed under one campaign at a time, since depositing
/// requires the depositor to currently own it). ERC1155 uses a single shared assetId across ALL
/// campaigns specifically to fuzz the commingled-pool risk analogous to the ERC20 escrow bug: many
/// campaigns hold independent slices of the SAME (token, id) balance, so a late claim or double
/// sweep on one campaign must never be payable out of another campaign's slice.
contract NFTInventoryHandler is Test, ERC1155Holder {
    Web3Campaigns public campaigns;
    MockERC721 public nft721;
    MockERC1155 public nft1155;
    address public participant = address(0xBEEF);

    uint256 constant ASSET_ID = 1;
    uint256 internal nextTokenId = 1;

    uint256[] public erc721Campaigns;
    uint256[] public erc1155Campaigns;

    mapping(uint256 => uint256) public erc721TokenIdOf;
    mapping(uint256 => bool) public erc721Resolved; // claimed OR swept

    mapping(uint256 => uint256) public erc1155DepositedOf; // campaignId => amount deposited
    mapping(uint256 => uint256) public erc1155AllocOf; // campaignId => amount allocated to participant
    mapping(uint256 => bool) public erc1155ClaimResolved;
    mapping(uint256 => bool) public erc1155SweepResolved;

    uint256 public ghost_erc1155Deposited;
    uint256 public ghost_erc1155Claimed;
    uint256 public ghost_erc1155Swept;

    constructor(Web3Campaigns _campaigns, MockERC721 _nft721, MockERC1155 _nft1155) {
        campaigns = _campaigns;
        nft721 = _nft721;
        nft1155 = _nft1155;
    }

    function _leaf(uint8 std, address token, uint256 tokenId, uint256 amt) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(participant, std, token, tokenId, amt))));
    }

    function _newCampaign(uint256 durSeed) internal returns (uint256 id, uint256 startTime, uint256 endTime) {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        startTime = block.timestamp + 1;
        endTime = startTime + dur;
        id = campaigns.createCampaign("C", startTime, endTime);
    }

    // --- ERC721 actions ---

    function depositAndSettleERC721(uint256 durSeed) external {
        (uint256 id,, uint256 endTime) = _newCampaign(durSeed);

        uint256 tokenId = nextTokenId++;
        nft721.mint(address(this), tokenId);
        nft721.approve(address(campaigns), tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        campaigns.depositERC721Rewards(id, address(nft721), ids);

        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        bytes32 root = _leaf(uint8(CampaignStorage.NFTStandard.ERC721), address(nft721), tokenId, 1);
        campaigns.setNFTMerkleRoot(id, root);

        erc721TokenIdOf[id] = tokenId;
        erc721Campaigns.push(id);
    }

    function claimERC721(uint256 cSeed) external {
        if (erc721Campaigns.length == 0) return;
        uint256 id = erc721Campaigns[bound(cSeed, 0, erc721Campaigns.length - 1)];
        if (erc721Resolved[id]) return;
        uint256 tokenId = erc721TokenIdOf[id];
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(participant);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), tokenId, 1, proof);
        erc721Resolved[id] = true;
    }

    function sweepERC721(uint256 cSeed) external {
        if (erc721Campaigns.length == 0) return;
        uint256 id = erc721Campaigns[bound(cSeed, 0, erc721Campaigns.length - 1)];
        if (erc721Resolved[id]) return;
        uint256 tokenId = erc721TokenIdOf[id];

        campaigns.closeCampaign(id);
        vm.warp(block.timestamp + campaigns.CLAIM_GRACE_PERIOD() + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        campaigns.withdrawUnclaimedERC721(id, address(nft721), ids);
        erc721Resolved[id] = true;
    }

    // --- ERC1155 actions (shared ASSET_ID across all campaigns => commingled-pool risk) ---

    function depositAndSettleERC1155(uint256 durSeed, uint256 amountSeed, uint256 allocSeed) external {
        (uint256 id,, uint256 endTime) = _newCampaign(durSeed);

        uint256 amount = bound(amountSeed, 1, 1e24);
        nft1155.mint(address(this), ASSET_ID, amount);
        nft1155.setApprovalForAll(address(campaigns), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = ASSET_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        campaigns.depositERC1155Rewards(id, address(nft1155), ids, amounts);
        ghost_erc1155Deposited += amount;

        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        uint256 alloc = bound(allocSeed, 0, amount); // participant's slice <= this campaign's deposit
        bytes32 root = _leaf(uint8(CampaignStorage.NFTStandard.ERC1155), address(nft1155), ASSET_ID, alloc);
        campaigns.setNFTMerkleRoot(id, root);

        erc1155DepositedOf[id] = amount;
        erc1155AllocOf[id] = alloc;
        erc1155Campaigns.push(id);
    }

    function claimERC1155(uint256 cSeed) external {
        if (erc1155Campaigns.length == 0) return;
        uint256 id = erc1155Campaigns[bound(cSeed, 0, erc1155Campaigns.length - 1)];
        if (erc1155ClaimResolved[id]) return;
        uint256 alloc = erc1155AllocOf[id];
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(participant);
        campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC1155, address(nft1155), ASSET_ID, alloc, proof);
        erc1155ClaimResolved[id] = true;
        ghost_erc1155Claimed += alloc;
    }

    function sweepERC1155(uint256 cSeed) external {
        if (erc1155Campaigns.length == 0) return;
        uint256 id = erc1155Campaigns[bound(cSeed, 0, erc1155Campaigns.length - 1)];
        if (erc1155SweepResolved[id]) return;

        campaigns.closeCampaign(id);
        vm.warp(block.timestamp + campaigns.CLAIM_GRACE_PERIOD() + 1);

        uint256 remaining = erc1155DepositedOf[id] - (erc1155ClaimResolved[id] ? erc1155AllocOf[id] : 0);
        if (remaining == 0) return; // withdrawUnclaimedERC1155 reverts NFTNotEscrowed on a zero amount

        uint256[] memory ids = new uint256[](1);
        ids[0] = ASSET_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = remaining;
        campaigns.withdrawUnclaimedERC1155(id, address(nft1155), ids, amounts);
        erc1155SweepResolved[id] = true;
        ghost_erc1155Swept += remaining;
    }

    // --- views for the invariant contract ---
    function erc721CampaignCount() external view returns (uint256) {
        return erc721Campaigns.length;
    }

    function erc721CampaignAt(uint256 i) external view returns (uint256) {
        return erc721Campaigns[i];
    }

    function erc1155CampaignCount() external view returns (uint256) {
        return erc1155Campaigns.length;
    }

    function erc1155CampaignAt(uint256 i) external view returns (uint256) {
        return erc1155Campaigns[i];
    }
}
