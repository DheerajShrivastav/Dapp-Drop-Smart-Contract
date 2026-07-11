// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice The slice of a fee-computation module's surface Web3Campaigns needs. A satellite
/// contract analogous to OnChainRewardModule -- Web3Campaigns retains ALL fund custody and does the
/// actual token movement; the module only decides HOW MUCH fee is owed and WHERE it goes.
///
/// Unlike OnChainRewardModule, no per-campaign pinning is needed here: computeFee is a pure
/// function of (amount, the module's current global config) evaluated and settled atomically within
/// a single fundCampaignERC20 call. There is no persistent per-campaign state inside the module that
/// could desync across an admin rotation of the global _feeModule pointer -- a rotation only ever
/// affects fee calculations for FUNDING CALLS MADE AFTER the rotation, which is the intended
/// behavior, not a hazard. See docs/SECURITY_FINDINGS.md for the contrast with the reward-module
/// pinning rationale.
interface IFeeModule {
    /// @notice Compute the protocol fee owed on a funding amount, and where to send it.
    /// @dev View-only: Web3Campaigns invokes this via a STATICCALL (enforced by the `view` keyword
    /// at the interface level), so a malicious or buggy module cannot reenter with a state-changing
    /// call from within computeFee. campaignId is currently unused by the reference FeeModule
    /// implementation (a flat global rate) but is kept in the signature so a future per-campaign fee
    /// tier can be added without changing any call site in Web3Campaigns.
    /// @param campaignId Campaign ID the funding call is for
    /// @param amount The gross amount the host is funding
    /// @return feeAmount The fee to skim from `amount` (0 disables the fee for this call)
    /// @return treasury Where to send `feeAmount` (ignored by the caller if feeAmount == 0)
    function computeFee(uint256 campaignId, uint256 amount) external view returns (uint256 feeAmount, address treasury);
}
