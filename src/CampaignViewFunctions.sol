// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CampaignStorage.sol"; // Import the shared storage

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
}
