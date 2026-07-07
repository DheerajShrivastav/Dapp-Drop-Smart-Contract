// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";

/// @notice Externally-linked library (DELEGATECALL'd, not inlined) holding the tier validation,
/// storage, and lookup logic for on-chain (dispute-free) ERC20 reward settlement. Extracted purely
/// to keep Web3Campaigns' own deployed bytecode under the EIP-170 24,576-byte limit -- this is pure,
/// storage-parameterized logic with no dependency on the rest of the contract's state, making it a
/// low-risk, self-contained extraction (unlike the already-hardened, invariant-tested Phase 2
/// signature-verification logic, which is deliberately left untouched here).
///
/// Public library functions operating on storage references get compiled into their OWN deployed
/// bytecode and linked at build/deploy time, rather than copied into every caller -- verified via
/// `forge build --sizes` after wiring this in (see docs/NEXT_STEPS.md / TEST_AND_BUILD.md for the
/// exact before/after numbers).
library OnChainRewardLib {
    /// @dev Validates and (re)writes a campaign's rank tiers: non-empty, capped at 10, ascending,
    /// non-overlapping ranges (startRank > previous endRank). Reverts using CampaignStorage's own
    /// custom errors so callers see identical error selectors whether this logic is inlined or not.
    function validateAndStoreRankTiers(
        CampaignStorage.RankTier[] storage _tiers,
        uint256[] calldata _startRanks,
        uint256[] calldata _endRanks,
        uint256[] calldata _amounts
    ) public {
        uint256 len = _startRanks.length;
        if (len == 0 || len > 10) {
            revert CampaignStorage.Web3Campaigns__TooManyTiers();
        }
        if (_endRanks.length != len || _amounts.length != len) {
            revert CampaignStorage.Web3Campaigns__InvalidTierConfiguration();
        }

        for (uint256 i; i < len; ++i) {
            if (_startRanks[i] == 0 || _startRanks[i] > _endRanks[i]) {
                revert CampaignStorage.Web3Campaigns__InvalidTierConfiguration();
            }
            if (i > 0 && _startRanks[i] <= _endRanks[i - 1]) {
                revert CampaignStorage.Web3Campaigns__InvalidTierConfiguration();
            }
        }

        _clearRankTiers(_tiers);
        for (uint256 i; i < len; ++i) {
            _tiers.push(
                CampaignStorage.RankTier({startRank: _startRanks[i], endRank: _endRanks[i], amount: _amounts[i]})
            );
        }
    }

    /// @dev `delete` on a whole dynamic storage array isn't permitted when accessed via a
    /// cross-contract qualified storage-reference parameter; pop-to-empty achieves the same effect.
    function _clearRankTiers(CampaignStorage.RankTier[] storage _tiers) private {
        uint256 len = _tiers.length;
        for (uint256 i; i < len; ++i) {
            _tiers.pop();
        }
    }

    /// @dev Validates and (re)writes a campaign's score tiers: non-empty, capped at 10, strictly
    /// descending minScore (the staircase invariant needed for a well-defined, gas-safe lookup).
    function validateAndStoreScoreTiers(
        CampaignStorage.ScoreTier[] storage _tiers,
        uint256[] calldata _minScores,
        uint256[] calldata _amounts
    ) public {
        uint256 len = _minScores.length;
        if (len == 0 || len > 10) {
            revert CampaignStorage.Web3Campaigns__TooManyTiers();
        }
        if (_amounts.length != len) {
            revert CampaignStorage.Web3Campaigns__InvalidTierConfiguration();
        }

        for (uint256 i = 1; i < len; ++i) {
            if (_minScores[i] >= _minScores[i - 1]) {
                revert CampaignStorage.Web3Campaigns__InvalidTierConfiguration();
            }
        }

        _clearScoreTiers(_tiers);
        for (uint256 i; i < len; ++i) {
            _tiers.push(CampaignStorage.ScoreTier({minScore: _minScores[i], amount: _amounts[i]}));
        }
    }

    /// @dev See _clearRankTiers.
    function _clearScoreTiers(CampaignStorage.ScoreTier[] storage _tiers) private {
        uint256 len = _tiers.length;
        for (uint256 i; i < len; ++i) {
            _tiers.pop();
        }
    }

    /// @dev Returns the reward amount for the tier whose [startRank, endRank] contains `_rank`, or
    /// 0 if no tier matches (caller is responsible for treating 0 as NoTierMatched).
    function matchRankTier(CampaignStorage.RankTier[] storage _tiers, uint256 _rank)
        public
        view
        returns (uint256 amount)
    {
        uint256 len = _tiers.length;
        for (uint256 i; i < len; ++i) {
            if (_rank >= _tiers[i].startRank && _rank <= _tiers[i].endRank) {
                return _tiers[i].amount;
            }
        }
        return 0;
    }

    /// @dev Returns the reward amount for the highest-threshold tier `_score` qualifies for
    /// (tiers are stored strictly descending by minScore), or 0 if no tier matches.
    function matchScoreTier(CampaignStorage.ScoreTier[] storage _tiers, uint256 _score)
        public
        view
        returns (uint256 amount)
    {
        uint256 len = _tiers.length;
        for (uint256 i; i < len; ++i) {
            if (_score >= _tiers[i].minScore) {
                return _tiers[i].amount;
            }
        }
        return 0;
    }

    /// @dev Consolidates the RANK_TIERED/SCORE_TIERED branch + tier lookup + escrow-accounting
    /// check for claimERC20OnChain into one library call (fewer call-site boundaries than
    /// separately branching in the caller and calling matchRankTier/matchScoreTier individually).
    /// Reverts NoTierMatched / InsufficientEscrow directly so the caller only needs to apply the
    /// effects (mark claimed, write distributed, transfer) after this returns.
    /// @param _mode RANK_TIERED or SCORE_TIERED (caller has already excluded MERKLE/UNSET)
    /// @param _rank Caller's completion rank (only meaningful for RANK_TIERED)
    /// @param _score Caller's participant score (only meaningful for SCORE_TIERED)
    /// @param _escrowed Campaign's total escrowed amount
    /// @param _distributed Campaign's total distributed-so-far amount
    /// @return amount The tier-matched reward amount
    /// @return rankOrScore Whichever of rank/score was actually used (for the claim event)
    /// @return newDistributed `_distributed + amount`, already validated against `_escrowed`
    function resolveOnChainClaim(
        CampaignStorage.ERC20SettlementMode _mode,
        CampaignStorage.RankTier[] storage _rankTiers,
        CampaignStorage.ScoreTier[] storage _scoreTiers,
        uint256 _rank,
        uint256 _score,
        uint256 _escrowed,
        uint256 _distributed
    ) public view returns (uint256 amount, uint256 rankOrScore, uint256 newDistributed) {
        if (_mode == CampaignStorage.ERC20SettlementMode.RANK_TIERED) {
            rankOrScore = _rank;
            amount = matchRankTier(_rankTiers, _rank);
        } else {
            rankOrScore = _score;
            amount = matchScoreTier(_scoreTiers, _score);
        }

        if (amount == 0) {
            revert CampaignStorage.Web3Campaigns__NoTierMatched();
        }

        newDistributed = _distributed + amount;
        if (newDistributed > _escrowed) {
            revert CampaignStorage.Web3Campaigns__InsufficientEscrow();
        }
    }

    /// @dev Validates and writes per-task point values for SCORE_TIERED scoring. `_taskCount` is
    /// passed by VALUE (campaign.tasks.length, a plain uint256), not by storage reference -- this
    /// avoids ever touching the Campaign struct's CampaignTask[] itself (whose dynamic string/bytes
    /// fields are expensive to marshal across a library call boundary; see the top of this file).
    function validateAndStoreTaskPoints(
        mapping(uint256 => uint256) storage _taskPointsMap,
        uint256 _taskCount,
        uint256[] calldata _taskIndices,
        uint256[] calldata _points
    ) public {
        uint256 len = _taskIndices.length;
        // Mirrors CampaignStorage.MAX_BATCH_SIZE (a `public constant` state variable can't be
        // referenced via cross-contract qualification the way custom errors can).
        if (len == 0 || len > 50) {
            revert CampaignStorage.Web3Campaigns__BatchTooLarge();
        }
        if (_points.length != len) {
            revert CampaignStorage.Web3Campaigns__ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            if (_taskIndices[i] >= _taskCount) {
                revert CampaignStorage.Web3Campaigns__TaskNotFound();
            }
            _taskPointsMap[_taskIndices[i]] = _points[i];
        }
    }

    /// @notice Mode-agnostic view shape for a single tier, used by getTiers so Web3Campaigns only
    /// needs ONE array-returning view function instead of two (the dynamic array-of-struct ABI
    /// encoding path is the single most expensive part of exposing tier data as a view -- costing
    /// roughly the same per function regardless of the struct's own field count -- so merging two
    /// such functions into one is a meaningful, real saving, not a cosmetic one).
    /// For RANK_TIERED: threshold = startRank, thresholdEnd = endRank.
    /// For SCORE_TIERED: threshold = minScore, thresholdEnd = 0 (unused).
    struct RewardTierView {
        uint256 threshold;
        uint256 thresholdEnd;
        uint256 amount;
    }

    /// @dev Builds the mode-agnostic tier view for whichever mode the campaign is actually using
    /// (the caller is expected to have already read the campaign's ERC20SettlementMode and pass the
    /// matching storage array; the OTHER array should be an empty/unused one for that campaign).
    function copyTiers(
        CampaignStorage.ERC20SettlementMode _mode,
        CampaignStorage.RankTier[] storage _rankTiers,
        CampaignStorage.ScoreTier[] storage _scoreTiers
    ) public view returns (RewardTierView[] memory result) {
        if (_mode == CampaignStorage.ERC20SettlementMode.RANK_TIERED) {
            uint256 len = _rankTiers.length;
            result = new RewardTierView[](len);
            for (uint256 i; i < len; ++i) {
                result[i] =
                    RewardTierView({threshold: _rankTiers[i].startRank, thresholdEnd: _rankTiers[i].endRank, amount: _rankTiers[i].amount});
            }
        } else if (_mode == CampaignStorage.ERC20SettlementMode.SCORE_TIERED) {
            uint256 len = _scoreTiers.length;
            result = new RewardTierView[](len);
            for (uint256 i; i < len; ++i) {
                result[i] = RewardTierView({threshold: _scoreTiers[i].minScore, thresholdEnd: 0, amount: _scoreTiers[i].amount});
            }
        }
    }
}
