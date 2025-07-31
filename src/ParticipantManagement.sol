// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CampaignStorage.sol"; // Import the shared storage

// This contract manages participant actions like completing tasks and claiming rewards.
contract ParticipantManagement is CampaignStorage {
    // --- Modifiers ---
    // Override the onlyHost modifier from CampaignStorage
    modifier onlyHost(uint256 _campaignId) override {
        super.onlyHost(_campaignId); // Call the base implementation
    }

    /**
     * @dev Allows a participant to mark a task as completed.
     * For off-chain tasks, this is a self-assertion that the host will later verify.
     * For on-chain tasks, this function performs direct on-chain verification.
     * @param _campaignId The ID of the campaign.
     * @param _taskIndex The index of the task within the campaign's tasks array.
     */
    function completeTask(uint256 _campaignId, uint256 _taskIndex) public {
        Campaign storage campaign = _campaigns[_campaignId];

        // Basic checks for campaign and task existence/status
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        if (block.timestamp > campaign.endTime) {
            revert Web3Campaigns__CampaignEnded();
        }
        if (_taskIndex >= campaign.tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        if (_participantTaskCompletion[msg.sender][_campaignId][_taskIndex]) {
            revert Web3Campaigns__TaskAlreadyCompleted();
        }

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
     * @dev Allows a participant to claim their reward after completing all required tasks.
     * @param _campaignId The ID of the campaign.
     */
    function claimReward(uint256 _campaignId) public {
        Campaign storage campaign = _campaigns[_campaignId];

        // Basic checks for campaign existence and claimability
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded(); // Only claimable after campaign has ended
        }
        if (_participantClaimedReward[msg.sender][_campaignId]) {
            revert Web3Campaigns__AlreadyClaimed();
        }
        if (campaign.reward.rewardType == RewardType.NONE) {
            revert Web3Campaigns__NoRewardSet();
        }

        // Verify all required tasks are completed
        for (uint256 i = 0; i < campaign.tasks.length; i++) {
            if (
                !campaign.tasks[i].isOptional &&
                !_participantTaskCompletion[msg.sender][_campaignId][i]
            ) {
                revert Web3Campaigns__AllTasksNotCompleted();
            }
        }

        // Mark as claimed BEFORE transferring reward (Checks-Effects-Interactions)
        _participantClaimedReward[msg.sender][_campaignId] = true;

        // --- Reward Distribution Logic ---
        if (campaign.reward.rewardType == RewardType.ERC20) {
            IERC20 token = IERC20(campaign.reward.tokenAddress);
            // Check if this contract has enough allowance from the host
            if (
                token.allowance(campaign.host, address(this)) <
                campaign.reward.amountOrTokenId
            ) {
                revert Web3Campaigns__InsufficientERC20Allowance();
            }
            // Pull tokens from host's approved allowance
            bool success = token.transferFrom(
                campaign.host,
                msg.sender,
                campaign.reward.amountOrTokenId
            );
            if (!success) {
                revert Web3Campaigns__ERC20TransferFailed();
            }
        } else if (campaign.reward.rewardType == RewardType.ERC721_SINGLE) {
            IERC721 token = IERC721(campaign.reward.tokenAddress);
            // This contract must own the specific NFT to transfer it
            // Ensure the contract actually holds the NFT
            if (
                token.ownerOf(campaign.reward.amountOrTokenId) != address(this)
            ) {
                revert Web3Campaigns__ERC721TransferFailed(); // Contract doesn't own the NFT
            }
            token.transferFrom(
                address(this),
                msg.sender,
                campaign.reward.amountOrTokenId
            );
            // ERC721 transferFrom reverts on failure, no explicit success check needed here.
        }
        // Add more reward types (e.g., Ether, custom NFT minting) as needed

        emit RewardClaimed(
            _campaignId,
            msg.sender,
            campaign.reward.rewardType,
            campaign.reward.tokenAddress,
            campaign.reward.amountOrTokenId
        );
    }
}
