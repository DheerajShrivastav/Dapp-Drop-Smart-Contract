// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// This contract defines all the shared data structures and state variables
// for the Web3Campaigns system. Other logic contracts will inherit from it.
abstract contract CampaignStorage is AccessControl {
    // --- Roles ---
    bytes32 public constant HOST_ROLE = keccak256("HOST_ROLE");
    // Emergency admin role
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");

    // --- Custom Errors (Enhanced with parameters for 0.8.31) ---
    /// @notice Campaign with given ID does not exist
    error Web3Campaigns__CampaignNotFound(uint256 campaignId);
    /// @notice Caller is not the host of the campaign
    error Web3Campaigns__CallerIsNotHost(uint256 campaignId, address caller, address expectedHost);
    /// @notice Campaign is not in Open status
    error Web3Campaigns__CampaignNotOpen(uint256 campaignId, CampaignStatus currentStatus);
    /// @notice Campaign has already been started/opened
    error Web3Campaigns__CampaignAlreadyStarted(uint256 campaignId);
    /// @notice Campaign has already ended
    error Web3Campaigns__CampaignAlreadyEnded(uint256 campaignId);
    /// @notice Invalid task type for the operation
    error Web3Campaigns__InvalidTaskType(uint256 taskType);
    /// @notice Participant hasn't completed all required tasks
    error Web3Campaigns__AllTasksNotCompleted(uint256 campaignId, address participant);
    /// @notice Reward has already been claimed
    error Web3Campaigns__AlreadyClaimed(uint256 campaignId, address participant);
    /// @notice Task has already been completed
    error Web3Campaigns__TaskAlreadyCompleted(uint256 campaignId, uint256 taskIndex, address participant);
    /// @notice Task cannot be verified by host (on-chain verification only)
    error Web3Campaigns__TaskNotVerifiableByHost(uint256 taskIndex);
    /// @notice Invalid reward type specified
    error Web3Campaigns__InvalidRewardType();
    /// @notice ERC20 allowance is insufficient for transfer
    error Web3Campaigns__InsufficientERC20Allowance(address token, uint256 required, uint256 available);
    /// @notice ERC20 transfer failed
    error Web3Campaigns__ERC20TransferFailed(address token, address from, address to, uint256 amount);
    /// @notice ERC721 transfer failed
    error Web3Campaigns__ERC721TransferFailed(address token, uint256 tokenId);
    /// @notice No reward has been configured for campaign
    error Web3Campaigns__NoRewardSet(uint256 campaignId);
    /// @notice Campaign has ended
    error Web3Campaigns__CampaignEnded(uint256 campaignId);
    /// @notice Campaign has not yet ended
    error Web3Campaigns__CampaignNotYetEnded(uint256 campaignId, uint256 endTime, uint256 currentTime);
    /// @notice Campaign start time has not been reached
    error Web3Campaigns__CampaignStartTimeNotYetStarted(uint256 campaignId, uint256 startTime);
    /// @notice Reward has already been configured
    error Web3Campaigns__RewardAlreadySet(uint256 campaignId);
    /// @notice Invalid reward amount (zero or invalid)
    error Web3Campaigns__InvalidRewardAmount(uint256 amount);
    /// @notice General transfer failed
    error Web3Campaigns__TransferFailed();
    /// @notice Task index is out of bounds
    error Web3Campaigns__TaskNotFound(uint256 campaignId, uint256 taskIndex, uint256 totalTasks);
    /// @notice Cannot accept own task
    error Web3Campaigns__PosterCannotAcceptOwnTask();
    /// @notice Verification data is malformed
    error Web3Campaigns__InvalidVerificationData(uint256 expectedLength, uint256 actualLength);
    /// @notice Participant doesn't hold required ERC20 balance
    error Web3Campaigns__InsufficientERC20Balance(address token, uint256 required, uint256 actual);
    /// @notice Participant doesn't hold the required ERC721
    error Web3Campaigns__NotHoldingSpecificERC721(address token, uint256 tokenId);
    /// @notice Invalid campaign duration
    error Web3Campaigns__InvalidCampaignDuration(uint256 startTime, uint256 endTime);
    
    // Flexible Reward System Errors (Enhanced)
    /// @notice NFT pool has been exhausted
    error Web3Campaigns__NFTPoolExhausted(uint256 campaignId, uint256 distributed, uint256 total);
    /// @notice ERC20 pool has been exhausted
    error Web3Campaigns__ERC20PoolExhausted(uint256 campaignId);
    /// @notice Tier configuration is invalid
    error Web3Campaigns__InvalidTierConfiguration(uint256 tierIndex);
    /// @notice Too many tiers specified
    error Web3Campaigns__TooManyTiers(uint256 count, uint256 max);
    /// @notice No NFTs have been added to pool
    error Web3Campaigns__NoNFTsInPool(uint256 campaignId);
    /// @notice Max NFTs per participant exceeded
    error Web3Campaigns__MaxNFTsPerParticipantExceeded(uint256 requested, uint256 max);
    /// @notice Token address is invalid (zero address)
    error Web3Campaigns__InvalidTokenAddress();
    /// @notice Reward has not been configured
    error Web3Campaigns__RewardNotConfigured(uint256 campaignId);
    /// @notice NFT reward is not enabled for this campaign
    error Web3Campaigns__NFTRewardNotEnabled(uint256 campaignId);
    /// @notice ERC20 reward is not enabled for this campaign
    error Web3Campaigns__ERC20RewardNotEnabled(uint256 campaignId);

    // Security constants
    uint256 public constant MIN_CAMPAIGN_DURATION = 1 hours;
    uint256 public constant MAX_CAMPAIGN_DURATION = 365 days;
    uint256 public constant MAX_PARTICIPANTS_LIMIT = 100000;
    uint256 public constant RATE_LIMIT_COOLDOWN = 5 minutes;
    uint256 public constant JOIN_COOLDOWN = 1 minutes;
    uint256 public constant MAX_SUSPICIOUS_SCORE = 100;
    // --- Enums ---
    enum CampaignStatus {
        Draft, // Campaign created, host is adding tasks
        Open, // Campaign active, participants can join and complete tasks
        Ended, // Campaign period over, participants can claim rewards
        Closed // Campaign fully concluded, no more claims
    }

    enum TaskType {
        SOCIAL_FOLLOW, // e.g., Follow Twitter, Instagram
        SOCIAL_LIKE, // e.g., Like a tweet, post
        SOCIAL_RETWEET, // e.g., Retweet a tweet
        SOCIAL_POST, // e.g., Make a post about the campaign
        DISCORD_JOIN, // e.g., Join a Discord server
        WALLET_CONNECT, // Simple wallet connection (often off-chain, or just a record)
        HUMANITY_VERIFICATION, // e.g., CAPTCHA or other human verification
        ONCHAIN_TX, // Perform a specific on-chain transaction
        ONCHAIN_HOLD_ERC20, // Hold a minimum amount of an ERC-20 token
        ONCHAIN_HOLD_ERC721 // Hold a specific ERC-721 NFT
    }

    enum RewardType {
        ERC20, // ERC-20 token reward
        ERC721_SINGLE, // Single ERC-721 token reward (transfer specific token)
        ERC721_BATCH, // Batch ERC-721 token reward (mint/transfer multiple) - more complex
        OTHER, // No on-chain reward (e.g., whitelist spot, off-chain prize)
        NONE // No reward
    }

    // Distribution modes for flexible reward allocation
    enum DistributionMode {
        FIXED,  // Same amount to all participants
        TIERED, // Different amounts based on claim rank
        FCFS    // First-come-first-served until pool exhausted
    }

    // --- Structs ---
    struct CampaignTask {
        TaskType taskType;
        string description;
        bytes verificationData; // Use bytes for robust encoding/decoding
        bool isOptional;
    }

    // Individual reward tier for tiered distribution
    struct RewardTier {
        uint256 startRank;  // First rank eligible (1-indexed)
        uint256 endRank;    // Last rank eligible (inclusive)
        uint256 amount;     // Amount per participant in this tier
    }

    // NFT Pool for bulk distribution
    struct NFTPool {
        address tokenAddress;
        uint256[] tokenIds;       // List of NFT token IDs to distribute
        uint256 distributedCount; // How many have been distributed
    }

    // ERC20 Reward Configuration
    struct ERC20Reward {
        bool enabled;
        address tokenAddress;
        DistributionMode distributionMode;
        uint256 fixedAmount;        // Used if distributionMode == FIXED
        uint256 totalPool;          // Total tokens available (for FCFS)
        uint256 distributedAmount;  // Track distributed tokens
    }

    // NFT Reward Configuration
    struct NFTReward {
        bool enabled;
        DistributionMode distributionMode;
        NFTPool pool;               // Pool of NFTs to distribute
        uint256 maxPerParticipant;  // Max NFTs per participant
    }

    // Off-chain Reward Configuration
    struct OffChainReward {
        bool enabled;
        string rewardDescription;   // Description of off-chain reward
        bytes rewardMetadata;       // Additional metadata (e.g., JSON)
    }

    // Complete Campaign Reward Configuration
    struct CampaignRewardConfig {
        ERC20Reward erc20Reward;
        NFTReward nftReward;
        OffChainReward offChainReward;
        bool rewardsConfigured;     // Flag to check if rewards are set
    }

    // Legacy struct kept for backward compatibility in events
    struct CampaignReward {
        RewardType rewardType;
        address tokenAddress;
        uint256 amountOrTokenId;
    }

    struct Campaign {
        uint256 id;
        string name;
        address host;
        uint256 startTime;
        uint256 endTime;
        CampaignStatus status;
        CampaignTask[] tasks;
        CampaignRewardConfig rewardConfig;
        uint224 createdAt;
        uint256 totalParticipants;
        uint256 claimCount;  // Track claim order for tiered distribution
    }

    // --- State Variables (Internal to be accessible by inheriting contracts) ---
    uint256 internal _campaignCounter;
    mapping(uint256 => Campaign) internal _campaigns;
    mapping(address => mapping(uint256 => mapping(uint256 => bool)))
        internal _participantTaskCompletion;
    mapping(address => mapping(uint256 => bool))
        internal _participantClaimedReward;
    mapping(address => uint256[]) internal _hostCampaigns;
    mapping(address => mapping(uint256 => bool)) internal _hasParticipated;

    // Security tracking mappings
    mapping(address => uint256) internal _lastActivityTime;
    mapping(address => uint256) internal _userCampaignCount;
    mapping(address => uint256) internal _suspiciousActivityScore;
    mapping(address => uint256) internal _lastJoinTime;

    // Reward system state variables
    mapping(uint256 => mapping(address => uint256)) internal _claimOrder; // campaignId => participant => claimRank
    mapping(uint256 => RewardTier[]) internal _rewardTiers; // campaignId => tiers array

    // Events (can be defined here or in the main contract)
    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed host,
        string name,
        uint256 startTime,
        uint256 endTime
    );
    event TaskAddedToCampaign(
        uint256 indexed campaignId,
        uint256 indexed taskId,
        TaskType taskType,
        string description
    );
    event CampaignStatusUpdated(
        uint256 indexed campaignId,
        CampaignStatus newStatus
    );
    event ParticipantTaskCompleted(
        uint256 indexed campaignId,
        address indexed participant,
        uint256 indexed taskId
    );
    event RewardClaimed(
        uint256 indexed campaignId,
        address indexed participant,
        RewardType rewardType,
        address tokenAddress,
        uint256 amountOrTokenId
    );
    event RewardSet(
        uint256 indexed campaignId,
        RewardType rewardType,
        address tokenAddress,
        uint256 amountOrTokenId
    );

    //Events for Security Purposes
    event EmergencyPause(address indexed admin, uint256 timestamp);
    event EmergencyUnpause(address indexed admin, uint256 timestamp);
    event SecurityViolationDetected(address indexed user, string reason);
    event SuspiciousActivity(address indexed user, string activity);
    event FundsReceived(address indexed sender, uint256 amount);

    // Flexible Reward System Events
    event ERC20RewardConfigured(
        uint256 indexed campaignId,
        address indexed tokenAddress,
        DistributionMode mode,
        uint256 amount
    );
    event NFTRewardConfigured(
        uint256 indexed campaignId,
        address indexed tokenAddress,
        uint256 maxPerParticipant
    );
    event OffChainRewardConfigured(
        uint256 indexed campaignId,
        string description
    );
    event NFTsAddedToPool(
        uint256 indexed campaignId,
        uint256 tokenCount
    );
    event TieredRewardConfigured(
        uint256 indexed campaignId,
        uint256 tierCount
    );

    // --- Modifiers ---
    modifier onlyHost(uint256 _campaignId) virtual {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound(_campaignId);
        }
        if (_campaigns[_campaignId].host != msg.sender) {
            revert Web3Campaigns__CallerIsNotHost(_campaignId, msg.sender, _campaigns[_campaignId].host);
        }
        _;
    }

    modifier campaignTimeValid(uint256 _campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        require(
            block.timestamp >= campaign.startTime &&
                block.timestamp <= campaign.endTime,
            "Campaign not in active period"
        );
        _;
    }

    /**
     * @notice Validate campaign parameters for security
     */
    function _validateCampaignParams(
        uint256 _startTime,
        uint256 _endTime
    ) internal view {
        if (_startTime <= block.timestamp) {
            revert Web3Campaigns__CampaignStartTimeNotYetStarted(0, _startTime);
        }
        if (_endTime <= _startTime) {
            revert Web3Campaigns__InvalidCampaignDuration(_startTime, _endTime);
        }
        if (_endTime - _startTime < MIN_CAMPAIGN_DURATION) {
            revert Web3Campaigns__InvalidCampaignDuration(_startTime, _endTime);
        }
        if (_endTime - _startTime > MAX_CAMPAIGN_DURATION) {
            revert Web3Campaigns__InvalidCampaignDuration(_startTime, _endTime);
        }
    }

    /**
     * @notice Rate limiting check
     */
    function _checkRateLimit(address _user) internal {
        require(
            block.timestamp - _lastActivityTime[_user] >= RATE_LIMIT_COOLDOWN,
            "Rate limit: too many actions"
        );
        _lastActivityTime[_user] = block.timestamp;
    }
}
