// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "./CampaignStorage.sol"; // Import the shared storage

// This contract manages campaign creation, task addition, reward setting,
// and campaign status updates. It also handles host role management.
contract CampaignManagement is CampaignStorage {
    // --- Modifiers ---
    // Override the onlyHost modifier from CampaignStorage
    modifier onlyHost(uint256 _campaignId) virtual override {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound(_campaignId);
        }
        if (_campaigns[_campaignId].host != msg.sender) {
            revert Web3Campaigns__CallerIsNotHost(_campaignId, msg.sender, _campaigns[_campaignId].host);
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

        // Initialize campaign with empty reward config
        Campaign storage newCampaign = _campaigns[campaignId];
        newCampaign.id = campaignId;
        newCampaign.name = _name;
        newCampaign.host = msg.sender;
        newCampaign.startTime = _startTime;
        newCampaign.endTime = _endTime;
        newCampaign.status = CampaignStatus.Draft;
        newCampaign.createdAt = uint224(block.timestamp);
        newCampaign.totalParticipants = 0;
        newCampaign.claimCount = 0;
        // rewardConfig is initialized with default values (all false/zero)

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

    // ============================================
    // FLEXIBLE REWARD CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Configure ERC20 token reward with fixed distribution
     * @dev All participants who complete tasks receive the same amount
     * @param _campaignId Campaign ID
     * @param _tokenAddress ERC20 token contract address
     * @param _amountPerParticipant Fixed amount each participant receives
     */
    function setERC20RewardFixed(
        uint256 _campaignId,
        address _tokenAddress,
        uint256 _amountPerParticipant
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        
        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (_tokenAddress == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        if (_amountPerParticipant == 0) {
            revert Web3Campaigns__InvalidRewardAmount();
        }

        campaign.rewardConfig.erc20Reward.enabled = true;
        campaign.rewardConfig.erc20Reward.tokenAddress = _tokenAddress;
        campaign.rewardConfig.erc20Reward.distributionMode = DistributionMode.FIXED;
        campaign.rewardConfig.erc20Reward.fixedAmount = _amountPerParticipant;
        campaign.rewardConfig.rewardsConfigured = true;

        emit ERC20RewardConfigured(
            _campaignId,
            _tokenAddress,
            DistributionMode.FIXED,
            _amountPerParticipant
        );
    }

    /**
     * @notice Configure ERC20 token reward with tiered distribution
     * @dev Different amounts based on claim rank (first N get X, next M get Y, etc.)
     * @param _campaignId Campaign ID
     * @param _tokenAddress ERC20 token contract address
     * @param _startRanks Array of starting ranks for each tier (1-indexed)
     * @param _endRanks Array of ending ranks for each tier (inclusive)
     * @param _amounts Amount per participant for each tier
     * 
     * Example: First 10 get 100 tokens, next 40 get 50 tokens, rest get 10
     * _startRanks = [1, 11, 51]
     * _endRanks = [10, 50, 1000]
     * _amounts = [100e18, 50e18, 10e18]
     */
    function setERC20RewardTiered(
        uint256 _campaignId,
        address _tokenAddress,
        uint256[] calldata _startRanks,
        uint256[] calldata _endRanks,
        uint256[] calldata _amounts
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        
        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (_tokenAddress == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        if (_startRanks.length != _endRanks.length || _startRanks.length != _amounts.length) {
            revert Web3Campaigns__InvalidTierConfiguration();
        }
        if (_startRanks.length == 0 || _startRanks.length > 10) {
            revert Web3Campaigns__TooManyTiers();
        }

        // Validate tier configuration
        for (uint256 i = 0; i < _startRanks.length; i++) {
            if (_startRanks[i] == 0 || _startRanks[i] > _endRanks[i]) {
                revert Web3Campaigns__InvalidTierConfiguration();
            }
            if (i > 0 && _startRanks[i] <= _endRanks[i - 1]) {
                revert Web3Campaigns__InvalidTierConfiguration();
            }
        }

        // Clear existing tiers for this campaign
        delete _rewardTiers[_campaignId];

        // Add new tiers
        for (uint256 i = 0; i < _startRanks.length; i++) {
            _rewardTiers[_campaignId].push(RewardTier({
                startRank: _startRanks[i],
                endRank: _endRanks[i],
                amount: _amounts[i]
            }));
        }

        campaign.rewardConfig.erc20Reward.enabled = true;
        campaign.rewardConfig.erc20Reward.tokenAddress = _tokenAddress;
        campaign.rewardConfig.erc20Reward.distributionMode = DistributionMode.TIERED;
        campaign.rewardConfig.rewardsConfigured = true;

        emit TieredRewardConfigured(_campaignId, _startRanks.length);
        emit ERC20RewardConfigured(
            _campaignId,
            _tokenAddress,
            DistributionMode.TIERED,
            0
        );
    }

    /**
     * @notice Configure NFT reward for bulk distribution
     * @dev NFTs are distributed FCFS from a pool
     * @param _campaignId Campaign ID
     * @param _tokenAddress ERC721 token contract address
     * @param _maxPerParticipant Maximum NFTs per participant (usually 1)
     */
    function setNFTReward(
        uint256 _campaignId,
        address _tokenAddress,
        uint256 _maxPerParticipant
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        
        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (_tokenAddress == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        if (_maxPerParticipant == 0) {
            revert Web3Campaigns__InvalidRewardAmount();
        }

        campaign.rewardConfig.nftReward.enabled = true;
        campaign.rewardConfig.nftReward.distributionMode = DistributionMode.FCFS;
        campaign.rewardConfig.nftReward.pool.tokenAddress = _tokenAddress;
        campaign.rewardConfig.nftReward.maxPerParticipant = _maxPerParticipant;
        campaign.rewardConfig.rewardsConfigured = true;

        emit NFTRewardConfigured(_campaignId, _tokenAddress, _maxPerParticipant);
    }

    /**
     * @notice Add NFTs to the campaign's NFT pool for distribution
     * @dev Host must approve contract for NFT transfers before calling
     * @param _campaignId Campaign ID
     * @param _tokenIds Array of token IDs to add to pool
     */
    function addNFTsToPool(
        uint256 _campaignId,
        uint256[] calldata _tokenIds
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        
        if (campaign.status != CampaignStatus.Draft && 
            campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignAlreadyEnded();
        }
        if (!campaign.rewardConfig.nftReward.enabled) {
            revert Web3Campaigns__NFTRewardNotEnabled();
        }
        if (_tokenIds.length == 0) {
            revert Web3Campaigns__NoNFTsInPool();
        }
        require(_tokenIds.length <= 100, "Too many NFTs at once (max 100)");

        IERC721 nft = IERC721(campaign.rewardConfig.nftReward.pool.tokenAddress);
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            // Transfer NFT from host to contract
            nft.transferFrom(msg.sender, address(this), _tokenIds[i]);
            campaign.rewardConfig.nftReward.pool.tokenIds.push(_tokenIds[i]);
        }

        emit NFTsAddedToPool(_campaignId, _tokenIds.length);
    }

    /**
     * @notice Configure off-chain/other reward
     * @dev Used for whitelist spots, physical prizes, etc.
     * @param _campaignId Campaign ID
     * @param _description Description of the reward
     * @param _metadata Additional metadata (can be JSON encoded)
     */
    function setOffChainReward(
        uint256 _campaignId,
        string calldata _description,
        bytes calldata _metadata
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        
        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        require(bytes(_description).length > 0, "Description required");
        require(bytes(_description).length <= 500, "Description too long");

        campaign.rewardConfig.offChainReward.enabled = true;
        campaign.rewardConfig.offChainReward.rewardDescription = _description;
        campaign.rewardConfig.offChainReward.rewardMetadata = _metadata;
        campaign.rewardConfig.rewardsConfigured = true;

        emit OffChainRewardConfigured(_campaignId, _description);
    }

    /**
     * @dev Legacy function for backward compatibility - sets ERC20 fixed reward
     * @deprecated Use setERC20RewardFixed, setERC20RewardTiered, setNFTReward instead
     */
    function setCampaignReward(
        uint256 _campaignId,
        RewardType _rewardType,
        address _tokenAddress,
        uint256 _amountOrTokenId
    ) public onlyHost(_campaignId) {
        if (_rewardType == RewardType.ERC20) {
            setERC20RewardFixed(_campaignId, _tokenAddress, _amountOrTokenId);
        } else if (_rewardType == RewardType.ERC721_SINGLE || _rewardType == RewardType.ERC721_BATCH) {
            setNFTReward(_campaignId, _tokenAddress, 1);
        } else if (_rewardType == RewardType.OTHER) {
            setOffChainReward(_campaignId, "Legacy off-chain reward", "");
        }
        // For NONE, do nothing
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
