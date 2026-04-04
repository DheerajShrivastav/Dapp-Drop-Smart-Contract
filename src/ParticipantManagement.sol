// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This contract manages participant actions like completing tasks and claiming rewards.
contract ParticipantManagement is CampaignStorage {
    using SafeERC20 for IERC20;
    // --- Modifiers ---
    // Override the onlyHost modifier from CampaignStorage
    modifier onlyHost(uint256 _campaignId) virtual override {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (_campaigns[_campaignId].host != msg.sender) {
            revert Web3Campaigns__CallerIsNotHost();
        }
        _;
    }

    /**
     * @dev Allows a participant to mark a task as completed.
     * For off-chain tasks, this is a self-assertion that the host will later verify.
     * For on-chain tasks, this function performs direct on-chain verification.
     * @param _campaignId The ID of the campaign.
     * @param _taskIndex The index of the task within the campaign's tasks array.
     */
    function completeTask(
        uint256 _campaignId,
        uint256 _taskIndex
    ) public virtual campaignTimeValid(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        // Basic checks for campaign and task existence/status
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        if (_taskIndex >= campaign.tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        if (_participantTaskCompletion[msg.sender][_campaignId][_taskIndex]) {
            revert Web3Campaigns__TaskAlreadyCompleted();
        }

        // SECURITY CHECKS
        require(
            _suspiciousActivityScore[msg.sender] < MAX_SUSPICIOUS_SCORE,
            "Account flagged for suspicious activity"
        );

        // Anti-spam protection
        require(
            block.timestamp - _lastActivityTime[msg.sender] >= 30 seconds,
            "Too many rapid actions"
        );

        CampaignTask storage currentTask = campaign.tasks[_taskIndex];

        // --- On-chain verification for specific task types ---
        if (currentTask.taskType == TaskType.ONCHAIN_HOLD_ERC20) {
            // Expects verificationData to be abi.encodePacked(tokenAddress, requiredAmount)
            // Length check: address (20 bytes) + uint256 (32 bytes) = 52 bytes
            if (currentTask.verificationData.length != 52) {
                revert Web3Campaigns__InvalidVerificationData();
            }

            (address tokenAddress, uint256 requiredAmount) = abi.decode(
                currentTask.verificationData,
                (address, uint256)
            );

            // Perform the actual balance check
            if (IERC20(tokenAddress).balanceOf(msg.sender) < requiredAmount) {
                revert Web3Campaigns__InsufficientERC20Balance();
            }
        } else if (currentTask.taskType == TaskType.ONCHAIN_HOLD_ERC721) {
            // Expects verificationData to be abi.encodePacked(tokenAddress, tokenId)
            // Length check: address (20 bytes) + uint256 (32 bytes) = 52 bytes
            if (currentTask.verificationData.length != 52) {
                revert Web3Campaigns__InvalidVerificationData();
            }

            (address tokenAddress, uint256 tokenId) = abi.decode(
                currentTask.verificationData,
                (address, uint256)
            );

            // Perform the actual ownership check
            // ERC721's ownerOf will revert if tokenId doesn't exist, which is fine.
            if (IERC721(tokenAddress).ownerOf(tokenId) != msg.sender) {
                revert Web3Campaigns__NotHoldingSpecificERC721();
            }
        } else if (currentTask.taskType == TaskType.ONCHAIN_TX) {
            // This type of task typically requires an oracle or a more complex proof system
            // to verify a specific transaction. For a simple contract, this would remain
            // a placeholder or be removed if not supported.
            revert Web3Campaigns__InvalidTaskType(); // Indicate this type is not directly verifiable here
        }
        // For other social tasks, this remains a self-assertion, requiring host verification.

        // Mark task as completed for the participant
        _participantTaskCompletion[msg.sender][_campaignId][_taskIndex] = true;

        // Accurately track unique participants
        if (!_hasParticipated[msg.sender][_campaignId]) {
            _hasParticipated[msg.sender][_campaignId] = true;
            campaign.totalParticipants++; // Increment only for the first task completed by this participant in this campaign
        }

        emit ParticipantTaskCompleted(_campaignId, msg.sender, _taskIndex);

        // Update last activity time
        _lastActivityTime[msg.sender] = block.timestamp;
    }

    /**
     * @dev Allows the host to verify and mark an off-chain task as completed for a participant.
     * This is crucial for off-chain tasks like social media follows.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @param _taskIndex The index of the task within the campaign's tasks array.
     */
    function verifyTaskCompletion(
        uint256 _campaignId,
        address _participant,
        uint256 _taskIndex
    ) public onlyHost(_campaignId) {
        // Apply onlyHost modifier directly here
        Campaign storage campaign = _campaigns[_campaignId];

        // Ensure campaign status allows verification
        if (
            campaign.status != CampaignStatus.Open &&
            campaign.status != CampaignStatus.Ended
        ) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        // Ensure task exists
        if (_taskIndex >= campaign.tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        // Ensure it's not an on-chain task type that should be self-verified by participant or oracle-verified
        if (
            campaign.tasks[_taskIndex].taskType == TaskType.ONCHAIN_TX ||
            campaign.tasks[_taskIndex].taskType ==
            TaskType.ONCHAIN_HOLD_ERC20 ||
            campaign.tasks[_taskIndex].taskType == TaskType.ONCHAIN_HOLD_ERC721
        ) {
            revert Web3Campaigns__TaskNotVerifiableByHost();
        }
        // Ensure task hasn't been completed already
        if (_participantTaskCompletion[_participant][_campaignId][_taskIndex]) {
            revert Web3Campaigns__TaskAlreadyCompleted();
        }

        _participantTaskCompletion[_participant][_campaignId][
            _taskIndex
        ] = true;

        // Accurately track unique participants
        if (!_hasParticipated[_participant][_campaignId]) {
            _hasParticipated[_participant][_campaignId] = true;
            campaign.totalParticipants++; // Increment only for the first task completed by this participant in this campaign
        }

        emit ParticipantTaskCompleted(_campaignId, _participant, _taskIndex);
    }

    /**
     * @notice Verify task completion for multiple participants in a single transaction
     * @param _campaignId The ID of the campaign
     * @param _participants Array of participant addresses
     * @param _taskIndices Array of task indices to verify for each participant
     */
    function batchVerifyTaskCompletion(
        uint256 _campaignId,
        address[] calldata _participants,
        uint256[] calldata _taskIndices
    ) external onlyHost(_campaignId) {
        uint256 length = _participants.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert Web3Campaigns__BatchTooLarge();
        }
        if (_taskIndices.length != length) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        Campaign storage campaign = _campaigns[_campaignId];

        if (
            campaign.status != CampaignStatus.Open &&
            campaign.status != CampaignStatus.Ended
        ) {
            revert Web3Campaigns__CampaignNotOpen();
        }

        for (uint256 i; i < length; ++i) {
            uint256 taskIndex = _taskIndices[i];
            address participant = _participants[i];

            if (taskIndex >= campaign.tasks.length) {
                revert Web3Campaigns__TaskNotFound();
            }
            // Skip on-chain verifiable tasks
            TaskType tType = campaign.tasks[taskIndex].taskType;
            if (
                tType == TaskType.ONCHAIN_TX ||
                tType == TaskType.ONCHAIN_HOLD_ERC20 ||
                tType == TaskType.ONCHAIN_HOLD_ERC721
            ) {
                revert Web3Campaigns__TaskNotVerifiableByHost();
            }
            // Skip already completed
            if (_participantTaskCompletion[participant][_campaignId][taskIndex]) {
                continue;
            }

            _participantTaskCompletion[participant][_campaignId][taskIndex] = true;

            if (!_hasParticipated[participant][_campaignId]) {
                _hasParticipated[participant][_campaignId] = true;
                campaign.totalParticipants++;
            }

            emit ParticipantTaskCompleted(_campaignId, participant, taskIndex);
        }

        emit BatchTasksVerified(_campaignId, length);
    }

    /**
     * @dev Allows a participant to claim their reward after completing all required tasks.
     * Supports ERC20 (fixed/tiered), NFT (bulk from pool), and off-chain rewards.
     * @param _campaignId The ID of the campaign.
     */
    function claimReward(uint256 _campaignId) public virtual {
        Campaign storage campaign = _campaigns[_campaignId];

        // Basic validation
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        if (_participantClaimedReward[msg.sender][_campaignId]) {
            revert Web3Campaigns__AlreadyClaimed();
        }
        if (!campaign.rewardConfig.rewardsConfigured) {
            revert Web3Campaigns__NoRewardSet();
        }

        // Verify all required tasks are completed
        _verifyAllTasksCompleted(_campaignId);

        // Mark as claimed FIRST (Checks-Effects-Interactions pattern)
        _participantClaimedReward[msg.sender][_campaignId] = true;

        // Assign claim order for tiered distribution
        campaign.claimCount++;
        uint256 claimRank = campaign.claimCount;
        _claimOrder[_campaignId][msg.sender] = claimRank;

        uint256 erc20Amount = 0;
        uint256 nftCount = 0;

        // Process ERC20 rewards
        if (campaign.rewardConfig.erc20Reward.enabled) {
            erc20Amount = _processERC20Reward(_campaignId, claimRank);
        }

        // Process NFT rewards
        if (campaign.rewardConfig.nftReward.enabled) {
            nftCount = _processNFTReward(_campaignId);
        }

        // Emit appropriate event
        RewardType claimedType = RewardType.OTHER;
        address tokenAddr = address(0);
        uint256 amount = claimRank; // Use claimRank as identifier

        if (campaign.rewardConfig.erc20Reward.enabled) {
            claimedType = RewardType.ERC20;
            tokenAddr = campaign.rewardConfig.erc20Reward.tokenAddress;
            amount = erc20Amount;
        } else if (campaign.rewardConfig.nftReward.enabled) {
            claimedType = RewardType.ERC721_BATCH;
            tokenAddr = campaign.rewardConfig.nftReward.pool.tokenAddress;
            amount = nftCount;
        }

        emit RewardClaimed(
            _campaignId,
            msg.sender,
            claimedType,
            tokenAddr,
            amount
        );
    }

    /**
     * @dev Process ERC20 reward distribution based on distribution mode
     * @param _campaignId Campaign ID
     * @param _claimRank Participant's claim rank
     * @return amount The amount of tokens transferred
     */
    function _processERC20Reward(
        uint256 _campaignId,
        uint256 _claimRank
    ) internal returns (uint256 amount) {
        Campaign storage campaign = _campaigns[_campaignId];
        ERC20Reward storage reward = campaign.rewardConfig.erc20Reward;

        if (reward.distributionMode == DistributionMode.FIXED) {
            amount = reward.fixedAmount;
        } else if (reward.distributionMode == DistributionMode.TIERED) {
            // Find applicable tier based on claim rank
            RewardTier[] storage tiers = _rewardTiers[_campaignId];
            for (uint256 i = 0; i < tiers.length; i++) {
                if (_claimRank >= tiers[i].startRank && _claimRank <= tiers[i].endRank) {
                    amount = tiers[i].amount;
                    break;
                }
            }
        } else if (reward.distributionMode == DistributionMode.FCFS) {
            // Take from pool until exhausted
            if (reward.distributedAmount + reward.fixedAmount <= reward.totalPool) {
                amount = reward.fixedAmount;
            }
        }

        if (amount > 0) {
            // Update state before external call (CEI pattern)
            reward.distributedAmount += amount;

            // SafeERC20 handles allowance check and reverts on failure
            IERC20(reward.tokenAddress).safeTransferFrom(campaign.host, msg.sender, amount);
        }

        return amount;
    }

    /**
     * @dev Process NFT reward distribution from pool
     * @param _campaignId Campaign ID
     * @return nftCount Number of NFTs distributed
     */
    function _processNFTReward(uint256 _campaignId) internal returns (uint256 nftCount) {
        Campaign storage campaign = _campaigns[_campaignId];
        NFTReward storage reward = campaign.rewardConfig.nftReward;
        NFTPool storage pool = reward.pool;

        // Check if NFTs are available
        if (pool.distributedCount >= pool.tokenIds.length) {
            // No more NFTs, but don't revert - participant still gets other rewards
            return 0;
        }

        uint256 nftsToDistribute = reward.maxPerParticipant;
        uint256 available = pool.tokenIds.length - pool.distributedCount;
        if (nftsToDistribute > available) {
            nftsToDistribute = available;
        }

        IERC721 nft = IERC721(pool.tokenAddress);

        for (uint256 i = 0; i < nftsToDistribute; i++) {
            uint256 tokenId = pool.tokenIds[pool.distributedCount];
            nft.transferFrom(address(this), msg.sender, tokenId);
            pool.distributedCount++;
        }

        return nftsToDistribute;
    }

    /**
     * @dev Verify participant has completed all required tasks
     * @param _campaignId Campaign ID
     */
    function _verifyAllTasksCompleted(uint256 _campaignId) internal view {
        Campaign storage campaign = _campaigns[_campaignId];
        for (uint256 i = 0; i < campaign.tasks.length; i++) {
            if (
                !campaign.tasks[i].isOptional &&
                !_participantTaskCompletion[msg.sender][_campaignId][i]
            ) {
                revert Web3Campaigns__AllTasksNotCompleted();
            }
        }
    }
}

