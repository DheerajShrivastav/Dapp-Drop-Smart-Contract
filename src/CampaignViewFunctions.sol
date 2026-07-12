// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";

// This contract provides all the view (read-only) functions for the system.
contract CampaignViewFunctions is CampaignStorage {
    /**
     * @dev Retrieves campaign details.
     * @param _campaignId The ID of the campaign.
     * @return Campaign struct.
     */
    function getCampaign(uint256 _campaignId) public view returns (Campaign memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _campaigns[_campaignId];
    }

    /**
     * @dev Retrieves a specific task within a campaign.
     * @param _campaignId The ID of the campaign.
     * @param _taskIndex The index of the task.
     * @return CampaignTask struct.
     */
    function getCampaignTask(uint256 _campaignId, uint256 _taskIndex) public view returns (CampaignTask memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (_taskIndex >= _campaigns[_campaignId].tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        return _campaigns[_campaignId].tasks[_taskIndex];
    }

    /**
     * @dev Checks if a participant has completed a specific task in a campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @param _taskIndex The index of the task.
     * @return True if completed, false otherwise.
     */
    function hasCompletedTask(uint256 _campaignId, address _participant, uint256 _taskIndex)
        public
        view
        returns (bool)
    {
        return _participantTaskCompletion[_participant][_campaignId][_taskIndex];
    }

    /**
     * @dev Checks if a participant has claimed the reward for a specific campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if claimed, false otherwise.
     */
    function hasClaimedReward(uint256 _campaignId, address _participant) public view returns (bool) {
        return _participantClaimedReward[_participant][_campaignId];
    }

    /**
     * @notice Get the current signed-attestation version for a participant's task.
     * @dev A signer's next attestation for this (participant, campaign, task) must target
     *      version + 1. Off-chain signing services should read this before constructing a
     *      new TaskAttestation to sign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address the attestation is about.
     * @param _taskIndex The index of the task.
     * @return The current version (0 if no attestation has ever been applied).
     */
    function getTaskAttestationVersion(uint256 _campaignId, address _participant, uint256 _taskIndex)
        external
        view
        returns (uint256)
    {
        return _taskAttestationVersion[_participant][_campaignId][_taskIndex];
    }

    /**
     * @dev Returns the total number of campaigns created.
     * @return The current value of _campaignCounter.
     */
    function getCampaignCount() public view returns (uint256) {
        return _campaignCounter;
    }

    /**
     * @dev Returns an array of campaign IDs created by a specific host.
     * @param _host The address of the host.
     * @return An array of uint256 representing campaign IDs.
     */
    function getCampaignsByHost(address _host) public view returns (uint256[] memory) {
        return _hostCampaigns[_host];
    }

    /**
     * @dev Returns whether a participant has started participating in a campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if the participant has started, false otherwise.
     */
    function hasParticipated(uint256 _campaignId, address _participant) public view returns (bool) {
        return _hasParticipated[_participant][_campaignId];
    }

    // ============================================
    // REWARD VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the off-chain reward configuration for a campaign.
     * @param _campaignId Campaign ID
     * @return OffChainReward struct (enabled, description, metadata)
     */
    function getOffChainReward(uint256 _campaignId) external view returns (OffChainReward memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _offChainReward[_campaignId];
    }

    // ============================================
    // MERKLE SETTLEMENT VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the ERC20 Merkle settlement state for a campaign.
     * @param _campaignId Campaign ID
     * @return token The configured ERC20 reward token (address(0) if unconfigured)
     * @return escrowed Total tokens escrowed
     * @return distributed Total tokens claimed so far
     * @return merkleRoot The published settlement root (bytes32(0) if not yet set)
     * @return closedAt Timestamp the campaign was Closed (0 if not closed)
     * @return swept Whether the host has reclaimed the unclaimed remainder
     */
    function getERC20Settlement(uint256 _campaignId)
        external
        view
        returns (address token, uint256 escrowed, uint256 distributed, bytes32 merkleRoot, uint64 closedAt, bool swept)
    {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        token = _erc20RewardToken[_campaignId];
        escrowed = _erc20Escrowed[_campaignId];
        distributed = _erc20Distributed[_campaignId];
        merkleRoot = _erc20MerkleRoot[_campaignId];
        closedAt = _campaignClosedAt[_campaignId];
        swept = _erc20Swept[_campaignId];
    }

    /**
     * @notice Whether an account has claimed its ERC20 settlement allocation.
     * @param _campaignId Campaign ID
     * @param _account The account to check
     * @return True if the account has already claimed via claimERC20
     */
    function hasClaimedERC20(uint256 _campaignId, address _account) external view returns (bool) {
        return _erc20SettlementClaimed[_campaignId][_account];
    }

    /**
     * @notice When claimERC20 will start accepting claims against the currently-published ERC20
     *         root, per ROOT_DISPUTE_WINDOW.
     * @dev Returns 0 if no root has ever been published for this campaign. A nonzero value in the
     *      past means the window has already elapsed and claims are open now.
     * @param _campaignId Campaign ID
     */
    function getERC20ClaimableAt(uint256 _campaignId) external view returns (uint256) {
        uint64 setAt = _erc20RootSetAt[_campaignId];
        if (setAt == 0) {
            return 0;
        }
        return setAt + ROOT_DISPUTE_WINDOW;
    }

    /**
     * @notice The OnChainRewardModule instance pinned as authoritative for a campaign.
     * @dev address(0) until the campaign first adopts an on-chain (RANK_TIERED / SCORE_TIERED)
     *      settlement mode, at which point it is pinned to the then-current module and never
     *      reassigned. The pinned module reads this to verify it is still the campaign's
     *      authoritative module before paying out.
     * @param _campaignId Campaign ID
     * @return The pinned module address, or address(0) if the campaign has no pinned module
     */
    function getCampaignRewardModule(uint256 _campaignId) external view returns (address) {
        return _campaignRewardModule[_campaignId];
    }

    /**
     * @notice The currently-registered protocol-fee module (address(0) if fees are disabled).
     * @dev Global, not per-campaign -- unlike the reward module, fee computation has no persistent
     *      per-campaign state, so there is nothing to pin. See IFeeModule.sol.
     */
    function getFeeModule() external view returns (address) {
        return _feeModule;
    }

    // getNFTMerkleRoot / getNFTClaimableAt / isNFTLeafClaimed / isERC721Escrowed /
    // getERC1155Escrowed now live on NFTSettlementModule -- query the module directly (via
    // getCampaignNFTModule below). Web3Campaigns no longer holds this state itself.

    /**
     * @notice The NFTSettlementModule instance pinned as authoritative for a campaign.
     * @dev address(0) until the campaign's first NFT deposit (either standard), at which point it
     *      is pinned to the then-current global default and never reassigned -- see
     *      CampaignManagement._pinNFTModule.
     * @param _campaignId Campaign ID
     * @return The pinned module address, or address(0) if the campaign has never received an NFT deposit
     */
    function getCampaignNFTModule(uint256 _campaignId) external view returns (address) {
        return _campaignNFTModule[_campaignId];
    }

    /**
     * @notice Timestamp a campaign was Closed (0 if not yet Closed). Consumed by
     *         NFTSettlementModule to check CLAIM_GRACE_PERIOD has elapsed before a sweep.
     * @param _campaignId Campaign ID
     */
    function getCampaignClosedAt(uint256 _campaignId) external view returns (uint64) {
        return _campaignClosedAt[_campaignId];
    }

    // ============================================
    // ON-CHAIN REWARD MODULE SUPPORT
    // ============================================
    // Rank/score/tier state for RANK_TIERED and SCORE_TIERED campaigns lives in the separately
    // deployed OnChainRewardModule (its own EIP-170 budget), not here -- query the module directly
    // for that data. This view exists purely so the module can cheaply verify "is caller the
    // campaign host" and "is the campaign in the right status" without paying for the full
    // getCampaign() struct return (which includes the CampaignTask[] array).

    /// @notice A campaign's host and current status, for the OnChainRewardModule's own
    /// authorization/status checks.
    function getCampaignHostAndStatus(uint256 _campaignId) external view returns (address host, CampaignStatus status) {
        Campaign storage campaign = _campaigns[_campaignId];
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        host = campaign.host;
        status = campaign.status;
    }

    /// @notice A campaign's task count, for the OnChainRewardModule's setTaskPoints index
    /// validation (cheaper than returning the full CampaignTask[] array via getCampaign).
    function getCampaignTaskCount(uint256 _campaignId) external view returns (uint256) {
        Campaign storage campaign = _campaigns[_campaignId];
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return campaign.tasks.length;
    }
}

