// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "./CampaignManagement.sol";
import "./ParticipantManagement.sol";
import "./CampaignViewFunctions.sol";

contract Web3Campaigns is
    CampaignManagement,
    ParticipantManagement,
    CampaignViewFunctions,
    ReentrancyGuard,
    Pausable
{
    // Version for tracking contract upgrades
    string public constant VERSION = "0.0.4";

    constructor() {
        // Grant emergency admin role to deployer
        _grantRole(EMERGENCY_ADMIN, msg.sender);
    }

    /**
     * @notice Emergency pause function
     */
    function emergencyPause() external onlyRole(EMERGENCY_ADMIN) {
        _pause();
        emit EmergencyPause(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause the contract
     */
    function emergencyUnpause() external onlyRole(EMERGENCY_ADMIN) {
        _unpause();
        emit EmergencyUnpause(msg.sender, block.timestamp);
    }

    /**
     * @notice Enhanced modifier with security checks
     */
    modifier onlyHost(uint256 _campaignId)
        override(CampaignManagement, ParticipantManagement, CampaignStorage) {
        require(!paused(), "Contract is paused");
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (_campaigns[_campaignId].host != msg.sender) {
            revert Web3Campaigns__CallerIsNotHost();
        }
        _;
    }

    /**
     * @notice Security wrapper for campaign operations
     */
    modifier whenActiveAndValid(uint256 _campaignId) {
        require(!paused(), "Contract is paused");
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        require(
            _campaigns[_campaignId].status == CampaignStatus.Open,
            "Campaign not active"
        );
        _;
    }

    // Enhanced receive function with security
    receive() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Invalid ETH amount");
        emit FundsReceived(msg.sender, msg.value);
    }

    // Enhanced fallback
    fallback() external payable whenNotPaused {
        revert("Function does not exist");
    }

    // Secure wrapper for CampaignManagement.openCampaign
    function openCampaign(uint256 _campaignId) public override whenNotPaused {
        super.openCampaign(_campaignId);
    }

    // Secure wrapper for CampaignManagement.endCampaign
    function endCampaign(uint256 _campaignId) public override whenNotPaused {
        super.endCampaign(_campaignId);
    }

    // Secure wrapper for CampaignManagement.closeCampaign
    function closeCampaign(uint256 _campaignId) public override whenNotPaused {
        super.closeCampaign(_campaignId);
    }

    // Secure wrapper for CampaignManagement.createCampaignWithTasksAndReward
    function createCampaignWithTasksAndReward(
        string memory _name,
        uint256 _startTime,
        uint256 _endTime,
        TaskType[] calldata _taskTypes,
        string[] calldata _descriptions,
        bytes[] calldata _verificationData,
        bool[] calldata _isOptional,
        RewardType _rewardType,
        address _tokenAddress,
        uint256 _amountOrTokenId
    ) public override whenNotPaused nonReentrant returns (uint256) {
        return
            super.createCampaignWithTasksAndReward(
                _name,
                _startTime,
                _endTime,
                _taskTypes,
                _descriptions,
                _verificationData,
                _isOptional,
                _rewardType,
                _tokenAddress,
                _amountOrTokenId
            );
    }

    // Secure wrapper for ParticipantManagement.completeTask
    function completeTask(
        uint256 _campaignId,
        uint256 _taskIndex
    ) public override whenNotPaused nonReentrant {
        super.completeTask(_campaignId, _taskIndex);
    }

    // Secure wrapper for ParticipantManagement.claimReward
    function claimReward(
        uint256 _campaignId
    ) public override whenNotPaused nonReentrant {
        super.claimReward(_campaignId);
    }
}
