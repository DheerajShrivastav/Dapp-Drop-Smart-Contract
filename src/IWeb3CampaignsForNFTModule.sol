// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";

/// @notice The slice of Web3Campaigns' surface the NFTSettlementModule needs. Web3Campaigns retains
/// ALL NFT custody (it alone implements ERC721Holder/ERC1155Holder) and all core campaign state; the
/// module holds only the settlement logic (Merkle roots, leaf-claimed tracking, per-campaign escrow
/// bookkeeping) and calls back here for the actual token movement.
interface IWeb3CampaignsForNFTModule {
    /// @notice A campaign's host and current status, for the module's own authorization/status
    /// checks (setNFTMerkleRoot requires Ended + caller == host; claims require Ended/Closed).
    function getCampaignHostAndStatus(uint256 campaignId)
        external
        view
        returns (address host, CampaignStorage.CampaignStatus status);

    /// @notice Timestamp a campaign was Closed (0 if not yet). Used by withdrawUnclaimed* to check
    /// CLAIM_GRACE_PERIOD has elapsed, mirroring the ERC20 sweep path's own grace check.
    function getCampaignClosedAt(uint256 campaignId) external view returns (uint64);

    /// @notice The auto-generated getters for CampaignStorage's public constants. Public constants
    /// are not accessible via a bare type-name reference without inheritance, so the module reads
    /// them via cross-contract call, matching how every other cross-contract fact here (host,
    /// status, closedAt) already flows.
    function CLAIM_GRACE_PERIOD() external view returns (uint256);
    function ROOT_DISPUTE_WINDOW() external view returns (uint256);

    /// @notice The module instance pinned as authoritative for a campaign (address(0) if none). The
    /// module reads this to independently confirm it is still the campaign's authoritative module
    /// before acting on its own escrow bookkeeping -- the pin is set by Web3Campaigns at first
    /// deposit (not at first root-set, since escrow bookkeeping starts accumulating at deposit time,
    /// which can precede any root ever being published).
    function getCampaignNFTModule(uint256 campaignId) external view returns (address);

    /// @notice Trusted callback the module uses to actually move an NFT out of Web3Campaigns'
    /// custody -- for a participant claim or a host sweep. Web3Campaigns only accepts this from the
    /// campaign's PINNED module; the module has already done all validation (proof, escrow,
    /// dispute-window, sweepability) before calling this, so this function performs the transfer
    /// only, no further checks.
    function executeNFTTransferOut(
        uint256 campaignId,
        CampaignStorage.NFTStandard standard,
        address token,
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external;

    /// @notice Standard AccessControl role check -- already public on Web3Campaigns (inherited from
    /// OZ AccessControl, used throughout for its own onlyRole checks), declared here purely so the
    /// module can check SETTLER_ROLE membership for its settler-fallback branch of setNFTMerkleRoot
    /// without Web3Campaigns needing any new function or bytecode.
    function hasRole(bytes32 role, address account) external view returns (bool);
}
