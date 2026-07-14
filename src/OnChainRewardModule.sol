// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {OnChainRewardLib} from "./OnChainRewardLib.sol";
import {IOnChainRewardModule} from "./IOnChainRewardModule.sol";
import {IWeb3CampaignsForModule} from "./IWeb3CampaignsForModule.sol";

/// @notice Standalone rules/computation engine for RANK_TIERED and SCORE_TIERED ERC20 reward
/// settlement -- a dispute-free alternative to the Merkle-proof claim path where the payout amount
/// is derived purely from on-chain completion state (completion rank or task-point score), so
/// there is nothing for a host to misrepresent off-chain and nothing to dispute.
///
/// This logic originally lived directly inside Web3Campaigns, but the finished feature pushed that
/// contract's deployed bytecode past the EIP-170 24,576-byte limit even after extensive extraction
/// of other logic into libraries. Rather than cut functionality to fit, it was split out into this
/// genuinely separate contract, which gets its own independent 24.576KB budget. Web3Campaigns
/// retains ALL fund custody and all core campaign state (host, status, task list); this module
/// holds none of it -- every fact it needs about a campaign is read across the
/// IWeb3CampaignsForModule interface, and every payout is executed by calling back into
/// Web3Campaigns' trusted payOnChainReward, never by this contract moving funds directly.
///
/// Trust boundary: Web3Campaigns only accepts setSettlementMode/payOnChainReward calls from the
/// single address registered as its _onChainRewardModule (admin-rotatable). Symmetrically, this
/// module only accepts notifyTaskCompletion calls from the one Web3Campaigns address it was
/// deployed with (immutable) -- see docs/REWARD_SYSTEM.md for the full architecture writeup.
contract OnChainRewardModule is IOnChainRewardModule {
    address public immutable WEB3_CAMPAIGNS;

    error OnChainRewardModule__NotWeb3Campaigns();
    error OnChainRewardModule__NotCampaignHost();
    error OnChainRewardModule__CampaignAlreadyStarted();
    error OnChainRewardModule__NotAuthoritativeModule();

    // Local authoritative copy of each campaign's chosen mode -- kept alongside the mutual-exclusion
    // guard on Web3Campaigns' side (which is what actually enforces "one mode per campaign"; a
    // config call here that would switch modes reverts via the setSettlementMode callback, and that
    // revert unwinds every storage write in this contract from the same call too).
    mapping(uint256 => CampaignStorage.ERC20SettlementMode) internal _mode;
    mapping(uint256 => mapping(uint256 => uint256)) internal _taskPoints; // campaignId => taskIndex => points
    mapping(uint256 => mapping(address => uint256)) internal _participantScore; // campaignId => participant => score
    mapping(uint256 => mapping(address => uint256)) internal _completionRank; // campaignId => participant => rank (0 = unranked)
    mapping(uint256 => uint256) internal _campaignCompletionCount; // campaignId => participants fully completed so far
    mapping(uint256 => CampaignStorage.RankTier[]) internal _rankTiers;
    mapping(uint256 => CampaignStorage.ScoreTier[]) internal _scoreTiers;
    mapping(uint256 => mapping(address => bool)) internal _onChainRewardClaimed;
    // Participant currently satisfies every required task, live (not historical). A completion
    // rank, once assigned, is never un-assigned -- but a signer's later revocation of any required
    // task immediately disqualifies further claims until the participant is re-verified in full,
    // taking precedence over the historical rank. See notifyTaskCompletion.
    mapping(uint256 => mapping(address => bool)) internal _currentlyQualified;

    event TaskPointsSet(uint256 indexed campaignId, uint256 count);
    event RankTiersConfigured(uint256 indexed campaignId, uint256 tierCount);
    event ScoreTiersConfigured(uint256 indexed campaignId, uint256 tierCount);

    constructor(address _web3Campaigns) {
        if (_web3Campaigns == address(0)) {
            revert OnChainRewardModule__NotWeb3Campaigns();
        }
        WEB3_CAMPAIGNS = _web3Campaigns;
    }

    modifier onlyWeb3Campaigns() {
        if (msg.sender != WEB3_CAMPAIGNS) {
            revert OnChainRewardModule__NotWeb3Campaigns();
        }
        _;
    }

    /// @dev Verifies the caller is the campaign's host and the campaign is still Draft (tier/point
    /// configuration, like Web3Campaigns' own configureERC20Reward, is only allowed before a
    /// campaign opens).
    function _requireHostAndDraft(uint256 _campaignId) internal view {
        (address host, CampaignStorage.CampaignStatus status) =
            IWeb3CampaignsForModule(WEB3_CAMPAIGNS).getCampaignHostAndStatus(_campaignId);
        if (msg.sender != host) {
            revert OnChainRewardModule__NotCampaignHost();
        }
        if (status != CampaignStorage.CampaignStatus.Draft) {
            revert OnChainRewardModule__CampaignAlreadyStarted();
        }
    }

    /**
     * @notice Configure a campaign's per-task point values, used for SCORE_TIERED scoring.
     * @dev Host-only, Draft-only. Does not itself commit the campaign to SCORE_TIERED mode --
     *      call setScoreTiers to do that -- so points can be staged before or after tiers.
     */
    function setTaskPoints(uint256 _campaignId, uint256[] calldata _taskIndices, uint256[] calldata _points) external {
        _requireHostAndDraft(_campaignId);
        uint256 taskCount = IWeb3CampaignsForModule(WEB3_CAMPAIGNS).getCampaignTaskCount(_campaignId);
        OnChainRewardLib.validateAndStoreTaskPoints(_taskPoints[_campaignId], taskCount, _taskIndices, _points);
        emit TaskPointsSet(_campaignId, _taskIndices.length);
    }

    /**
     * @notice Configure a campaign's rank-based reward tiers and commit it to RANK_TIERED
     *         settlement.
     * @dev Host-only, Draft-only. Commits the mode on Web3Campaigns FIRST (cheap check that
     *      reverts early if the campaign already committed to a different mode) before writing
     *      the (potentially large) tier array here.
     */
    function setRankTiers(
        uint256 _campaignId,
        uint256[] calldata _startRanks,
        uint256[] calldata _endRanks,
        uint256[] calldata _amounts
    ) external {
        _requireHostAndDraft(_campaignId);
        IWeb3CampaignsForModule(WEB3_CAMPAIGNS)
            .setSettlementMode(_campaignId, CampaignStorage.ERC20SettlementMode.RANK_TIERED);
        _mode[_campaignId] = CampaignStorage.ERC20SettlementMode.RANK_TIERED;
        OnChainRewardLib.validateAndStoreRankTiers(_rankTiers[_campaignId], _startRanks, _endRanks, _amounts);
        emit RankTiersConfigured(_campaignId, _startRanks.length);
    }

    /**
     * @notice Configure a campaign's score-threshold reward tiers and commit it to SCORE_TIERED
     *         settlement.
     * @dev Host-only, Draft-only. Same mode-first-then-tiers ordering as setRankTiers.
     */
    function setScoreTiers(uint256 _campaignId, uint256[] calldata _minScores, uint256[] calldata _amounts) external {
        _requireHostAndDraft(_campaignId);
        IWeb3CampaignsForModule(WEB3_CAMPAIGNS)
            .setSettlementMode(_campaignId, CampaignStorage.ERC20SettlementMode.SCORE_TIERED);
        _mode[_campaignId] = CampaignStorage.ERC20SettlementMode.SCORE_TIERED;
        OnChainRewardLib.validateAndStoreScoreTiers(_scoreTiers[_campaignId], _minScores, _amounts);
        emit ScoreTiersConfigured(_campaignId, _minScores.length);
    }

    /// @inheritdoc IOnChainRewardModule
    /// @dev Applies score/rank bookkeeping for a task-completion state transition reported by
    ///      Web3Campaigns. On a newly-true, fully-qualifying transition: adds the task's point
    ///      value to the participant's running score and, if not already ranked, assigns the next
    ///      completion rank (a historical, immutable "you were Nth to finish" marker -- rank is
    ///      never un-assigned). On a newly-false transition (a signer's correction): subtracts the
    ///      score and immediately marks the participant as not currently qualified, so a since-
    ///      revoked completion blocks payout at claim time even though their historical rank stands.
    function notifyTaskCompletion(
        uint256 campaignId,
        address participant,
        uint256 taskIndex,
        bool nowCompleted,
        bool hasAllRequired
    ) external onlyWeb3Campaigns {
        // Score credit/debit. The revoke branch's `-=` is checked arithmetic (^0.8) and can never
        // underflow: per-task points are written only by setTaskPoints, which is Draft-only, while
        // every completion transition that reaches here occurs only once the campaign is Open/Ended
        // (completeTask / verifyTaskCompletionWithSignature). The lifecycle is strictly forward and
        // status is set to Draft exactly once at creation, so points[taskIndex] is frozen before any
        // credit is applied and reads the SAME value at revoke time. A debit can only follow a prior
        // credit for that same task (a true->false transition requires it was true), and Web3Campaigns
        // suppresses no-op notifications, so each `+= points` is matched by at most one `-=` of the
        // identical amount -- the running score can never be driven below zero. See
        // test_SetTaskPoints_RevertsOnceCampaignLeavesDraft (the immutability invariant that makes
        // this safe) and test_ScoreTiered_RevokeRestoresScoreExactly (the round-trip).
        uint256 points = _taskPoints[campaignId][taskIndex];
        if (points > 0) {
            if (nowCompleted) {
                _participantScore[campaignId][participant] += points;
            } else {
                _participantScore[campaignId][participant] -= points;
            }
        }

        if (nowCompleted) {
            if (hasAllRequired) {
                _currentlyQualified[campaignId][participant] = true;
                if (_completionRank[campaignId][participant] == 0) {
                    uint256 nextRank = _campaignCompletionCount[campaignId] + 1;
                    _campaignCompletionCount[campaignId] = nextRank;
                    _completionRank[campaignId][participant] = nextRank;
                }
            }
        } else {
            if (!hasAllRequired) {
                _currentlyQualified[campaignId][participant] = false;
            }
        }
    }

    /**
     * @notice Claim an on-chain (dispute-free) ERC20 reward for a RANK_TIERED or SCORE_TIERED
     *         campaign. No Merkle proof needed -- the amount is computed purely from this
     *         contract's own on-chain-tracked completion rank or task-point score.
     * @dev For RANK_TIERED, requires the caller is CURRENTLY qualified (see notifyTaskCompletion) --
     *      a signer may have revoked a required task after the historical rank was assigned; rank
     *      itself is immutable, but current disqualification still blocks payout. For SCORE_TIERED,
     *      the running score is always live-accurate, so no separate qualification check is needed.
     *      A rank/score matching no configured tier reverts NoTierMatched rather than silently
     *      paying zero and burning the claim, consistent with Web3Campaigns' Merkle claim path.
     * @param _campaignId Campaign ID
     */
    function claimReward(uint256 _campaignId) external {
        _claimReward(_campaignId, msg.sender);
    }

    /**
     * @notice Submit an on-chain-reward claim ON BEHALF OF a participant (sponsored / gasless
     *         claim). Payment ALWAYS goes to `_participant` -- never to the caller.
     * @dev Deliberately permissionless, mirroring Web3Campaigns.claimERC20For: the payout amount is
     *      computed purely from `_participant`'s own on-chain rank/score state, and payOnChainReward
     *      pays `_participant` directly, so a third-party caller can only deliver a participant's
     *      own reward to the participant's own wallet. Lets the project backend pay gas for users
     *      with no meta-transaction framework.
     */
    function claimRewardFor(uint256 _campaignId, address _participant) external {
        if (_participant == address(0)) {
            revert CampaignStorage.Web3Campaigns__ZeroAddress();
        }
        _claimReward(_campaignId, _participant);
    }

    /// @dev Shared claim body for claimReward (participant = msg.sender) and claimRewardFor
    /// (sponsored). All checks/effects/payout run against `_participant`.
    function _claimReward(uint256 _campaignId, address _participant) internal {
        if (_onChainRewardClaimed[_campaignId][_participant]) {
            revert CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement();
        }

        // Independently confirm this contract is still the campaign's authoritative module before
        // touching any rank/score/tier state -- don't trust local storage alone. Web3Campaigns pins
        // the module per campaign at adoption and enforces that pin in payOnChainReward; checking it
        // here too means a superseded module fails fast and cannot even begin computing a payout.
        if (IWeb3CampaignsForModule(WEB3_CAMPAIGNS).getCampaignRewardModule(_campaignId) != address(this)) {
            revert OnChainRewardModule__NotAuthoritativeModule();
        }

        (, CampaignStorage.CampaignStatus status) =
            IWeb3CampaignsForModule(WEB3_CAMPAIGNS).getCampaignHostAndStatus(_campaignId);
        if (status != CampaignStorage.CampaignStatus.Ended && status != CampaignStorage.CampaignStatus.Closed) {
            revert CampaignStorage.Web3Campaigns__CampaignNotYetEnded();
        }

        CampaignStorage.ERC20SettlementMode mode = _mode[_campaignId];
        if (
            mode != CampaignStorage.ERC20SettlementMode.RANK_TIERED
                && mode != CampaignStorage.ERC20SettlementMode.SCORE_TIERED
        ) {
            revert CampaignStorage.Web3Campaigns__WrongSettlementMode();
        }

        uint256 amount;
        uint256 rankOrScore;
        if (mode == CampaignStorage.ERC20SettlementMode.RANK_TIERED) {
            if (!_currentlyQualified[_campaignId][_participant]) {
                revert CampaignStorage.Web3Campaigns__NotFullyCompleted();
            }
            rankOrScore = _completionRank[_campaignId][_participant];
            amount = OnChainRewardLib.matchRankTier(_rankTiers[_campaignId], rankOrScore);
        } else {
            rankOrScore = _participantScore[_campaignId][_participant];
            amount = OnChainRewardLib.matchScoreTier(_scoreTiers[_campaignId], rankOrScore);
        }

        if (amount == 0) {
            revert CampaignStorage.Web3Campaigns__NoTierMatched();
        }

        // Effects (CEI) before the cross-contract interaction that actually moves funds.
        _onChainRewardClaimed[_campaignId][_participant] = true;

        IWeb3CampaignsForModule(WEB3_CAMPAIGNS).payOnChainReward(_campaignId, _participant, amount, rankOrScore);
    }

    /// @notice A participant's full on-chain-reward status for a campaign in one call: the
    /// campaign's settlement mode, this participant's completion rank (0 if not yet fully
    /// completed), their running score, whether they're currently qualified (RANK_TIERED only),
    /// and whether they've already claimed.
    function getOnChainRewardStatus(uint256 _campaignId, address _participant)
        external
        view
        returns (CampaignStorage.ERC20SettlementMode mode, uint256 rank, uint256 score, bool qualified, bool claimed)
    {
        mode = _mode[_campaignId];
        rank = _completionRank[_campaignId][_participant];
        score = _participantScore[_campaignId][_participant];
        qualified = _currentlyQualified[_campaignId][_participant];
        claimed = _onChainRewardClaimed[_campaignId][_participant];
    }

    /// @notice All configured tiers for a campaign, in a mode-agnostic shape (works for either
    /// RANK_TIERED or SCORE_TIERED; empty array if UNSET/MERKLE). For RANK_TIERED, `threshold` is
    /// startRank and `thresholdEnd` is endRank; for SCORE_TIERED, `threshold` is minScore and
    /// `thresholdEnd` is unused (0). Check getOnChainRewardStatus's mode to know which applies.
    function getTiers(uint256 _campaignId) external view returns (OnChainRewardLib.RewardTierView[] memory) {
        return OnChainRewardLib.copyTiers(_mode[_campaignId], _rankTiers[_campaignId], _scoreTiers[_campaignId]);
    }
}
