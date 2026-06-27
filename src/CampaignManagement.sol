// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This contract manages campaign creation, task addition, reward setting,
// and campaign status updates. It also handles host role management.
contract CampaignManagement is CampaignStorage {
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
    ) public virtual onlyRole(HOST_ROLE) returns (uint256) {
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

    /**
     * @notice Add multiple tasks to a campaign in a single transaction
     * @param _campaignId The ID of the campaign
     * @param _taskTypes Array of task types
     * @param _descriptions Array of task descriptions
     * @param _verificationData Array of verification data
     * @param _isOptional Array of optional flags
     */
    function batchAddTasks(
        uint256 _campaignId,
        TaskType[] calldata _taskTypes,
        string[] calldata _descriptions,
        bytes[] calldata _verificationData,
        bool[] calldata _isOptional
    ) external onlyHost(_campaignId) {
        uint256 length = _taskTypes.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert Web3Campaigns__BatchTooLarge();
        }
        if (
            _descriptions.length != length ||
            _verificationData.length != length ||
            _isOptional.length != length
        ) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        require(campaign.tasks.length + length <= 20, "Too many tasks per campaign");

        for (uint256 i; i < length; ++i) {
            require(
                bytes(_descriptions[i]).length > 0 &&
                    bytes(_descriptions[i]).length <= 1000,
                "Invalid description length"
            );

            campaign.tasks.push(
                CampaignTask({
                    taskType: _taskTypes[i],
                    description: _descriptions[i],
                    verificationData: _verificationData[i],
                    isOptional: _isOptional[i]
                })
            );

            emit TaskAddedToCampaign(
                _campaignId,
                campaign.tasks.length - 1,
                _taskTypes[i],
                _descriptions[i]
            );
        }

        emit BatchTasksAdded(_campaignId, length);
    }

    // ============================================
    // FLEXIBLE REWARD CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Configure the ERC20 reward token for a campaign (Merkle settlement model).
     * @dev Distribution amounts (fixed / tiered / FCFS / sybil-filtered) are computed
     *      OFF-CHAIN after the campaign ends and committed as a Merkle root via
     *      setERC20MerkleRoot. This setter only records WHICH token will be paid; the
     *      host must escrow it with fundCampaignERC20 before opening the campaign.
     * @param _campaignId Campaign ID
     * @param _tokenAddress ERC20 token contract address
     */
    function configureERC20Reward(
        uint256 _campaignId,
        address _tokenAddress
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (_tokenAddress == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }

        _erc20RewardToken[_campaignId] = _tokenAddress;
        campaign.rewardConfig.rewardsConfigured = true;

        emit ERC20RewardConfigured2(_campaignId, _tokenAddress);
    }

    /**
     * @notice Escrow ERC20 reward tokens into the contract for a campaign.
     * @dev Pulls tokens from the caller (host) into the contract. Allowed in Draft, Open,
     *      or Ended (so the host can top up if the published allocation needs more than was
     *      initially escrowed). The host must approve this contract first.
     * @param _campaignId Campaign ID
     * @param _amount Amount of the configured reward token to escrow
     */
    function fundCampaignERC20(
        uint256 _campaignId,
        uint256 _amount
    ) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        address token = _erc20RewardToken[_campaignId];
        if (token == address(0)) {
            revert Web3Campaigns__ERC20RewardNotConfigured();
        }
        if (_amount == 0) {
            revert Web3Campaigns__InvalidAmount();
        }
        if (
            campaign.status != CampaignStatus.Draft &&
            campaign.status != CampaignStatus.Open &&
            campaign.status != CampaignStatus.Ended
        ) {
            revert Web3Campaigns__CampaignAlreadyEnded();
        }

        // Effects before interaction (escrow tracked on measured received amount would be
        // ideal for fee-on-transfer tokens; standard tokens are assumed here).
        _erc20Escrowed[_campaignId] += _amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);

        emit CampaignFundedERC20(_campaignId, msg.sender, _amount);
    }

    /**
     * @notice Publish (or update) the ERC20 reward Merkle root for settlement.
     * @dev Only after the campaign has Ended. The root commits to leaves of
     *      keccak256(bytes.concat(keccak256(abi.encode(account, amount)))) — the
     *      OpenZeppelin StandardMerkleTree format. Updatable while Ended (e.g. to fix an
     *      allocation); frozen once the campaign is Closed.
     * @param _campaignId Campaign ID
     * @param _merkleRoot The settlement Merkle root
     */
    function setERC20MerkleRoot(
        uint256 _campaignId,
        bytes32 _merkleRoot
    ) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        if (_erc20RewardToken[_campaignId] == address(0)) {
            revert Web3Campaigns__ERC20RewardNotConfigured();
        }
        if (_merkleRoot == bytes32(0)) {
            revert Web3Campaigns__MerkleRootNotSet();
        }

        _erc20MerkleRoot[_campaignId] = _merkleRoot;
        emit ERC20MerkleRootSet(_campaignId, _merkleRoot);
    }

    /**
     * @notice Reclaim ERC20 escrow that was never claimed, after the grace period.
     * @dev Callable by the host once the campaign is Closed and CLAIM_GRACE_PERIOD has
     *      elapsed since closing. Transfers the unclaimed remainder back to the host.
     * @param _campaignId Campaign ID
     */
    function withdrawUnclaimedERC20(
        uint256 _campaignId
    ) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Closed) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        if (block.timestamp < _campaignClosedAt[_campaignId] + CLAIM_GRACE_PERIOD) {
            revert Web3Campaigns__GracePeriodActive();
        }
        if (_erc20Swept[_campaignId]) {
            revert Web3Campaigns__AlreadySwept();
        }

        uint256 remaining = _erc20Escrowed[_campaignId] - _erc20Distributed[_campaignId];
        if (remaining == 0) {
            revert Web3Campaigns__NothingToSweep();
        }

        _erc20Swept[_campaignId] = true;

        IERC20(_erc20RewardToken[_campaignId]).safeTransfer(campaign.host, remaining);

        emit UnclaimedERC20Swept(_campaignId, campaign.host, remaining);
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

        // Effects: update state before external calls (CEI pattern)
        for (uint256 i; i < _tokenIds.length; ++i) {
            campaign.rewardConfig.nftReward.pool.tokenIds.push(_tokenIds[i]);
        }

        emit NFTsAddedToPool(_campaignId, _tokenIds.length);

        // Interactions: external transfers after all state changes
        IERC721 nft = IERC721(campaign.rewardConfig.nftReward.pool.tokenAddress);
        for (uint256 i; i < _tokenIds.length; ++i) {
            nft.transferFrom(msg.sender, address(this), _tokenIds[i]);
        }
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
        string memory _description,
        bytes memory _metadata
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
        // A campaign can only be ended at or after its scheduled endTime. Early
        // conclusion is intentionally NOT supported, so that participants always
        // have the full advertised window to complete tasks.
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
        _campaignClosedAt[_campaignId] = uint64(block.timestamp); // start of the unclaimed-sweep grace window
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Closed);
    }
}
