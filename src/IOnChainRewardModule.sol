// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Interface Web3Campaigns uses to notify the registered OnChainRewardModule of a
/// task-completion state transition. Only called when the campaign has actually committed to
/// RANK_TIERED or SCORE_TIERED mode, and only on a genuine transition (nowCompleted != previous
/// state) -- Web3Campaigns filters both conditions before calling, so the module can treat every
/// call as "apply this transition" without re-deriving whether it should have fired.
interface IOnChainRewardModule {
    /// @param campaignId The campaign this transition applies to
    /// @param participant The participant whose task state changed
    /// @param taskIndex The task that changed
    /// @param nowCompleted The task's new completion state (true = just completed, false = revoked)
    /// @param hasAllRequired Whether the participant now satisfies every required task for the
    /// campaign (only meaningful/true when nowCompleted is also true; used to decide rank
    /// assignment). Computed by Web3Campaigns using its own on-chain task-completion state, since
    /// that state lives there, not in the module.
    function notifyTaskCompletion(
        uint256 campaignId,
        address participant,
        uint256 taskIndex,
        bool nowCompleted,
        bool hasAllRequired
    ) external;
}
