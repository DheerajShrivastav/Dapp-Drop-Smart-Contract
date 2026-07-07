// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";

/// @notice The slice of Web3Campaigns' surface the OnChainRewardModule needs to call into. The
/// module holds none of the campaign's funds or core state (host, status, task list) itself --
/// Web3Campaigns retains all of that -- so every read or mutation the module needs crosses this
/// interface rather than being duplicated locally.
interface IWeb3CampaignsForModule {
    /// @notice A campaign's host and current status, for the module's own authorization/status
    /// checks (config functions require Draft + caller == host; claims require Ended/Closed).
    function getCampaignHostAndStatus(uint256 campaignId) external view returns (address host, CampaignStorage.CampaignStatus status);

    /// @notice Task count for a campaign, used to validate task indices in setTaskPoints.
    function getCampaignTaskCount(uint256 campaignId) external view returns (uint256);

    /// @notice The module instance pinned as authoritative for a campaign (address(0) if none). The
    /// module reads this to independently confirm it is still the campaign's authoritative module
    /// before paying anyone out, rather than trusting only its own local state.
    function getCampaignRewardModule(uint256 campaignId) external view returns (address);

    /// @notice Trusted callback the module uses to commit a campaign to RANK_TIERED or
    /// SCORE_TIERED settlement. Web3Campaigns enforces the actual mutual-exclusion rule (a
    /// campaign already committed to a different mode reverts), so a malicious or buggy module
    /// can never silently switch a campaign's settlement path.
    function setSettlementMode(uint256 campaignId, CampaignStorage.ERC20SettlementMode mode) external;

    /// @notice Trusted callback the module uses to actually pay out a reward it has computed.
    /// Web3Campaigns re-checks its own escrow/sweep accounting before transferring -- the module
    /// only decides WHO gets paid HOW MUCH, never moves funds itself.
    function payOnChainReward(uint256 campaignId, address participant, uint256 amount, uint256 rankOrScore) external;
}
