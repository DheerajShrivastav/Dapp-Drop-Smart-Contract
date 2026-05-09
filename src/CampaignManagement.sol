// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CampaignStorage.sol"; // Import the shared storage

// This contract manages campaign creation, task addition, reward setting,
// and campaign status updates. It also handles host role management.
contract CampaignManagement is CampaignStorage {
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

    // --- Constructor ---
    constructor() {
        // Grant the deployer (msg.sender) the DEFAULT_ADMIN_ROLE and HOST_ROLE
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HOST_ROLE, msg.sender);
    }

    /**
     * @dev Grants the HOST_ROLE to an address, allowing them to create campaigns.
     * @param _account The address to grant the HOST_ROLE to.
     */
    function grantHostRole(address _account) public {
        _grantRole(HOST_ROLE, _account);
    }

    /**
     * @dev Revokes the HOST_ROLE from an address, preventing them from creating new campaigns.
     * Only callable by an account with DEFAULT_ADMIN_ROLE.
     * @param _account The address to revoke the HOST_ROLE from.
     */
    function revokeHostRole(
        address _account
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(HOST_ROLE, _account);
    }

    // --- Campaign Management ---

    /**
     * @dev Creates a new campaign in Draft status. Only accounts with HOST_ROLE can create campaigns.
     * @param _name The name of the campaign.
     * @param _startTime The timestamp when the campaign officially starts.
     * @param _endTime The timestamp when the campaign officially ends.
     * @return The ID of the newly created campaign.
     */
    function createCampaign(
        string memory _name,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyRole(HOST_ROLE) returns (uint256) {
        require(
            bytes(_name).length > 0 && bytes(_name).length <= 200,
            "Invalid name length"
        );

        // Rate Limiting
        _checkRateLimit(msg.sender);

        // Parameter Validation using security helper
        _validateCampaignParams(_startTime, _endTime);

        _campaignCounter++;
        uint256 campaignId = _campaignCounter;

        _campaigns[campaignId] = Campaign({
            id: campaignId,
            name: _name,
            host: msg.sender,
            startTime: _startTime,
            endTime: _endTime,
            status: CampaignStatus.Draft,
            tasks: new CampaignTask[](0),
            reward: CampaignReward(RewardType.NONE, address(0), 0),
            createdAt: uint224(block.timestamp), // Cast to uint224
            totalParticipants: 0
        });

        _hostCampaigns[msg.sender].push(campaignId);
        _userCampaignCount[msg.sender]++;

        emit CampaignCreated(
            campaignId,
            msg.sender,
            _name,
            _startTime,
            _endTime
        );
        return campaignId;
    }

    /**
     * @dev Adds a task to an existing campaign. Can only be called by the campaign host in Draft status.
     * @param _campaignId The ID of the campaign.
     * @param _taskType The type of task (e.g., SOCIAL_FOLLOW).
     * @param _description A user-friendly description of the task.
     * @param _verificationData Data needed for verification (e.g., Twitter handle, encoded token data).
     * @param _isOptional If true, this task is not mandatory for claiming.
     */
    function addTaskToCampaign(
        uint256 _campaignId,
        TaskType _taskType,
        string memory _description,
        bytes memory _verificationData, // Parameter type matches struct
        bool _isOptional
    ) public onlyHost(_campaignId) {
        // Add security validation
        require(
            bytes(_description).length > 0 &&
                bytes(_description).length <= 1000,
            "Invalid description length"
        );

        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        // Limit tasks per campaign for security
        require(campaign.tasks.length < 20, "Too many tasks per campaign");

        campaign.tasks.push(
            CampaignTask({
                taskType: _taskType,
                description: _description,
                verificationData: _verificationData,
                isOptional: _isOptional
            })
        );

        emit TaskAddedToCampaign(
            _campaignId,
            campaign.tasks.length - 1,
            _taskType,
            _description
        );
    }

    /**
     * @dev Sets the reward for a campaign. Can only be called by the campaign host in Draft status.
     * For ERC20/ERC721, the host must approve/transfer tokens to this contract beforehand.
     * @param _campaignId The ID of the campaign.
     * @param _rewardType The type of reward.
     * @param _tokenAddress The address of the ERC20/ERC721 token (if applicable).
     * @param _amountOrTokenId The amount for ERC20, or specific token ID for ERC721_SINGLE.
     */
    function setCampaignReward(
        uint256 _campaignId,
        RewardType _rewardType,
        address _tokenAddress,
        uint256 _amountOrTokenId
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (campaign.reward.rewardType != RewardType.NONE) {
            revert Web3Campaigns__RewardAlreadySet();
        }
        if(_rewardType == RewardType.ERC20 || _rewardType == RewardType.ERC721_SINGLE || _rewardType == RewardType.ERC721_BATCH){
            require(_tokenAddress != address(0), "Invalid token address");
            require(_tokenAddress.code.length > 0, "Token address has no code");
        }
        if (_rewardType == RewardType.NONE && _amountOrTokenId != 0) {
            revert Web3Campaigns__InvalidRewardAmount();
        }

        campaign.reward = CampaignReward({
            rewardType: _rewardType,
            tokenAddress: _tokenAddress,
            amountOrTokenId: _amountOrTokenId
        });

        emit RewardSet(
            _campaignId,
            _rewardType,
            _tokenAddress,
            _amountOrTokenId
        );
    }

    /**
     * @dev Sets the campaign status to Open. Can only be called by the host.
     * @param _campaignId The ID of the campaign.
     */
    function openCampaign(
        uint256 _campaignId
    ) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }

        campaign.status = CampaignStatus.Open;
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Open);
    }

    /**
     * @dev Sets the campaign status to Ended. Can only be called by the host.
     * This allows claims to begin.
     * @param _campaignId The ID of the campaign.
     */
    function endCampaign(
        uint256 _campaignId
    ) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        // Allow ending before endTime if host decides to conclude early
        if (block.timestamp < campaign.endTime) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }

        campaign.status = CampaignStatus.Ended;
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Ended);
    }

    /**
     * @dev Closes the campaign, preventing further claims. Only callable by the host.
     * @param _campaignId The ID of the campaign.
     */
    function closeCampaign(
        uint256 _campaignId
    ) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }

        campaign.status = CampaignStatus.Closed;
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Closed);
    }
}
