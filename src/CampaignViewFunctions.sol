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
    function getCampaign(
        uint256 _campaignId
    ) public view returns (Campaign memory) {
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
    function getCampaignTask(
        uint256 _campaignId,
        uint256 _taskIndex
    ) public view returns (CampaignTask memory) {
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
    function hasCompletedTask(
        uint256 _campaignId,
        address _participant,
        uint256 _taskIndex
    ) public view returns (bool) {
        return
            _participantTaskCompletion[_participant][_campaignId][_taskIndex];
    }

    /**
     * @dev Checks if a participant has claimed the reward for a specific campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if claimed, false otherwise.
     */
    function hasClaimedReward(
        uint256 _campaignId,
        address _participant
    ) public view returns (bool) {
        return _participantClaimedReward[_participant][_campaignId];
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
    function getCampaignsByHost(
        address _host
    ) public view returns (uint256[] memory) {
        return _hostCampaigns[_host];
    }

    /**
     * @dev Returns whether a participant has started participating in a campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if the participant has started, false otherwise.
     */
    function hasParticipated(
        uint256 _campaignId,
        address _participant
    ) public view returns (bool) {
        return _hasParticipated[_participant][_campaignId];
    }

    // ============================================
    // FLEXIBLE REWARD VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get ERC20 reward configuration for a campaign
     * @param _campaignId Campaign ID
     * @return ERC20Reward struct with configuration details
     */
    function getERC20RewardConfig(
        uint256 _campaignId
    ) external view returns (ERC20Reward memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _campaigns[_campaignId].rewardConfig.erc20Reward;
    }

    /**
     * @notice Get NFT reward configuration for a campaign
     * @param _campaignId Campaign ID
     * @return NFTReward struct with configuration details
     */
    function getNFTRewardConfig(
        uint256 _campaignId
    ) external view returns (NFTReward memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _campaigns[_campaignId].rewardConfig.nftReward;
    }

    /**
     * @notice Get off-chain reward configuration for a campaign
     * @param _campaignId Campaign ID
     * @return OffChainReward struct with configuration details
     */
    function getOffChainRewardConfig(
        uint256 _campaignId
    ) external view returns (OffChainReward memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _campaigns[_campaignId].rewardConfig.offChainReward;
    }

    /**
     * @notice Get participant's claim rank for a campaign
     * @param _campaignId Campaign ID
     * @param _participant Participant address
     * @return Claim rank (0 if not claimed)
     */
    function getClaimRank(
        uint256 _campaignId,
        address _participant
    ) external view returns (uint256) {
        return _claimOrder[_campaignId][_participant];
    }

    /**
     * @notice Get all reward tiers for a tiered distribution campaign
     * @param _campaignId Campaign ID
     * @return Array of RewardTier structs
     */
    function getRewardTiers(
        uint256 _campaignId
    ) external view returns (RewardTier[] memory) {
        return _rewardTiers[_campaignId];
    }

    /**
     * @notice Calculate potential reward for a participant at current claim count
     * @param _campaignId Campaign ID
     * @return erc20Amount Expected ERC20 tokens
     * @return nftCount Expected NFT count
     */
    function calculatePotentialReward(
        uint256 _campaignId
    ) external view returns (uint256 erc20Amount, uint256 nftCount) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        
        Campaign storage campaign = _campaigns[_campaignId];
        uint256 nextRank = campaign.claimCount + 1;

        // Calculate ERC20
        if (campaign.rewardConfig.erc20Reward.enabled) {
            ERC20Reward storage reward = campaign.rewardConfig.erc20Reward;
            if (reward.distributionMode == DistributionMode.FIXED) {
                erc20Amount = reward.fixedAmount;
            } else if (reward.distributionMode == DistributionMode.TIERED) {
                RewardTier[] storage tiers = _rewardTiers[_campaignId];
                for (uint256 i = 0; i < tiers.length; i++) {
                    if (nextRank >= tiers[i].startRank && nextRank <= tiers[i].endRank) {
                        erc20Amount = tiers[i].amount;
                        break;
                    }
                }
            } else if (reward.distributionMode == DistributionMode.FCFS) {
                if (reward.distributedAmount + reward.fixedAmount <= reward.totalPool) {
                    erc20Amount = reward.fixedAmount;
                }
            }
        }

        // Calculate NFT
        if (campaign.rewardConfig.nftReward.enabled) {
            NFTPool storage pool = campaign.rewardConfig.nftReward.pool;
            uint256 available = pool.tokenIds.length - pool.distributedCount;
            uint256 maxPer = campaign.rewardConfig.nftReward.maxPerParticipant;
            nftCount = available >= maxPer ? maxPer : available;
        }
    }

    /**
     * @notice Get current claim count for a campaign
     * @param _campaignId Campaign ID
     * @return Number of rewards claimed
     */
    function getClaimCount(uint256 _campaignId) external view returns (uint256) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _campaigns[_campaignId].claimCount;
    }

    /**
     * @notice Get NFT pool status for a campaign
     * @param _campaignId Campaign ID
     * @return totalNFTs Total NFTs in pool
     * @return distributedNFTs NFTs already distributed
     * @return remainingNFTs NFTs remaining
     */
    function getNFTPoolStatus(
        uint256 _campaignId
    ) external view returns (uint256 totalNFTs, uint256 distributedNFTs, uint256 remainingNFTs) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        NFTPool storage pool = _campaigns[_campaignId].rewardConfig.nftReward.pool;
        totalNFTs = pool.tokenIds.length;
        distributedNFTs = pool.distributedCount;
        remainingNFTs = totalNFTs - distributedNFTs;
    }
}

