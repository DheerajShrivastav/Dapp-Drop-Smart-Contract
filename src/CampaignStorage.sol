// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// This contract defines all the shared data structures and state variables
// for the Web3Campaigns system. Other logic contracts will inherit from it.
abstract contract CampaignStorage is AccessControl {
    // --- Roles ---
    bytes32 public constant HOST_ROLE = keccak256("HOST_ROLE");

    // --- Custom Errors ---
    // Centralized error definitions for consistency and easier management
    error Web3Campaigns__CampaignNotFound();
    error Web3Campaigns__CallerIsNotHost();
    error Web3Campaigns__CampaignNotOpen();
    error Web3Campaigns__CampaignAlreadyStarted();
    error Web3Campaigns__CampaignAlreadyEnded();
    error Web3Campaigns__InvalidTaskType();
    error Web3Campaigns__AllTasksNotCompleted();
    error Web3Campaigns__AlreadyClaimed();
    error Web3Campaigns__TaskAlreadyCompleted();
    error Web3Campaigns__TaskNotVerifiableByHost();
    error Web3Campaigns__InvalidRewardType();
    error Web3Campaigns__InsufficientERC20Allowance();
    error Web3Campaigns__ERC20TransferFailed();
    error Web3Campaigns__ERC721TransferFailed();
    error Web3Campaigns__NoRewardSet();
    error Web3Campaigns__CampaignEnded();
    error Web3Campaigns__CampaignNotYetEnded();
    error Web3Campaigns__CampaignStartTimeNotYetStrated();
    error Web3Campaigns__RewardAlreadySet();
    error Web3Campaigns__InvalidRewardAmount();
    error Web3Campaigns__TransferFailed(); // For general Ether transfers
    error Web3Campaigns__TaskNotFound(); // For task index out of bounds
    error Web3Campaigns__PosterCannotAcceptOwnTask();
    error Web3Campaigns__InvalidVerificationData(); // For malformed verification data
    error Web3Campaigns__InsufficientERC20Balance(); // For ONCHAIN_HOLD_ERC20 task verification
    error Web3Campaigns__NotHoldingSpecificERC721(); // For ONCHAIN_HOLD_ERC721 task verification
    error Web3Campaigns__InvalidCampaignDuration(); // For _endTime <= _startTime in campaign creation

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
        ONCHAIN_TX, // Perform a specific on-chain transaction
        ONCHAIN_HOLD_ERC20, // Hold a minimum amount of an ERC-20 token
        ONCHAIN_HOLD_ERC721 // Hold a specific ERC-721 NFT
    }

    enum RewardType {
        NONE, // No on-chain reward (e.g., whitelist spot, off-chain prize)
        ERC20, // ERC-20 token reward
        ERC721_SINGLE, // Single ERC-721 token reward (transfer specific token)
        ERC721_BATCH // Batch ERC-721 token reward (mint/transfer multiple) - more complex
    }

    // --- Structs ---
    struct CampaignTask {
        TaskType taskType;
        string description;
        bytes verificationData; // Use bytes for robust encoding/decoding
        bool isOptional;
    }

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
        CampaignReward reward;
        uint224 createdAt; // Using uint224 for timestamps to potentially save gas/storage space
        uint256 totalParticipants;
    }

    // --- State Variables (Internal to be accessible by inheriting contracts) ---
    uint256 internal _campaignCounter;
    mapping(uint256 => Campaign) internal _campaigns;
    mapping(address => mapping(uint256 => mapping(uint256 => bool)))
        internal _participantTaskCompletion;
    mapping(address => mapping(uint256 => bool))
        internal _participantClaimedReward;
    mapping(address => uint256[]) internal _hostCampaigns;
    mapping(address => mapping(uint256 => bool)) internal _hasParticipated; // Tracks if a participant has started a campaign

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

    // --- Modifiers ---
    modifier onlyHost(uint256 _campaignId) virtual {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (_campaigns[_campaignId].host != msg.sender) {
            revert Web3Campaigns__CallerIsNotHost();
        }
        _;
    }
}
