// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {NFTSettlementModule} from "../../src/NFTSettlementModule.sol";
import {MockERC721, MockERC1155} from "../NFTSettlement.t.sol";
import {NFTInventoryHandler} from "./NFTInventoryHandler.sol";

/// @notice Invariant suite for multi-standard NFT escrow + Merkle settlement inventory safety.
/// ERC721 correctness follows from unique-token ownership; ERC1155 uses a single shared asset id
/// across many campaigns specifically to fuzz the commingled-pool risk that turned out to be real
/// for ERC20 escrow (see EscrowSolvency.invariant.t.sol) — here to confirm the per-campaign
/// inventory map design does NOT have the same gap.
contract NFTInventoryInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    NFTSettlementModule public nftModule;
    MockERC721 public nft721;
    MockERC1155 public nft1155;
    NFTInventoryHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        nftModule = new NFTSettlementModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setNFTSettlementModule(address(nftModule));

        nft721 = new MockERC721();
        nft1155 = new MockERC1155();
        handler = new NFTInventoryHandler(campaigns, nftModule, nft721, nft1155);

        vm.prank(deployer);
        campaigns.grantHostRole(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = NFTInventoryHandler.depositAndSettleERC721.selector;
        selectors[1] = NFTInventoryHandler.claimERC721.selector;
        selectors[2] = NFTInventoryHandler.sweepERC721.selector;
        selectors[3] = NFTInventoryHandler.depositAndSettleERC1155.selector;
        selectors[4] = NFTInventoryHandler.claimERC1155.selector;
        selectors[5] = NFTInventoryHandler.sweepERC1155.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every escrowed ERC721 tokenId is either still held by the contract with its escrow
    /// flag set (unresolved), or has been paid out (claimed/swept) with the flag cleared and the
    /// contract no longer owning it. No tokenId can be double-counted or stuck inconsistent.
    function invariant_erc721OwnershipMatchesEscrowFlag() public view {
        uint256 n = handler.erc721CampaignCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.erc721CampaignAt(i);
            uint256 tokenId = handler.erc721TokenIdOf(id);
            bool resolved = handler.erc721Resolved(id);
            bool escrowed = nftModule.isERC721Escrowed(id, address(nft721), tokenId);

            if (resolved) {
                assertFalse(escrowed, "resolved ERC721 still marked escrowed");
                assertTrue(nft721.ownerOf(tokenId) != address(campaigns), "resolved ERC721 still held by contract");
            } else {
                assertTrue(escrowed, "unresolved ERC721 not marked escrowed");
                assertEq(nft721.ownerOf(tokenId), address(campaigns), "unresolved ERC721 not held by contract");
            }
        }
    }

    /// @notice Global ERC1155 solvency: the contract's actual balance of the shared asset id exactly
    /// matches total deposited minus total claimed minus total swept across ALL campaigns sharing it.
    function invariant_erc1155GlobalSolvency() public view {
        assertEq(
            nft1155.balanceOf(address(campaigns), 1),
            handler.ghost_erc1155Deposited() - handler.ghost_erc1155Claimed() - handler.ghost_erc1155Swept(),
            "ERC1155 global solvency diverged"
        );
    }

    /// @notice Once a campaign's ERC1155 slice has been swept, its per-campaign escrow entry must be
    /// fully drained to zero — no residue left claimable, and nothing left for a later claim to pull
    /// from another campaign's slice of the same shared asset id.
    function invariant_erc1155NoResidueAfterSweep() public view {
        uint256 n = handler.erc1155CampaignCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.erc1155CampaignAt(i);
            if (!handler.erc1155SweepResolved(id)) continue;
            assertEq(
                nftModule.getERC1155Escrowed(id, address(nft1155), 1), 0, "residue left in swept ERC1155 campaign slice"
            );
        }
    }

    /// @notice Sum of all campaigns' remaining ERC1155 escrow entries must never exceed the contract's
    /// actual balance of that asset id — the per-campaign backing check for the commingled pool.
    function invariant_erc1155PerCampaignBacked() public view {
        uint256 owed;
        uint256 n = handler.erc1155CampaignCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.erc1155CampaignAt(i);
            owed += nftModule.getERC1155Escrowed(id, address(nft1155), 1);
        }
        assertGe(nft1155.balanceOf(address(campaigns), 1), owed, "ERC1155 per-campaign backing underwater");
    }
}
