// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

// This contract defines all the shared data structures and state variables
// for the Web3Campaigns system. Other logic contracts will inherit from it.
abstract contract CampaignStorage is AccessControl, EIP712 {
    constructor() EIP712("Web3Campaigns", "1") {}

    // --- Roles ---
    bytes32 public constant HOST_ROLE = keccak256("HOST_ROLE");
    // Emergency admin role
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");
    // Moderator role: can flag accounts for suspicious activity
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    // Signer role: backend keys authorized to sign off-chain task-completion attestations
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // --- Custom Errors ---
    error Web3Campaigns__CampaignNotFound();
    error Web3Campaigns__CallerIsNotHost();
    error Web3Campaigns__CampaignNotOpen();
    error Web3Campaigns__CampaignAlreadyStarted();
    error Web3Campaigns__CampaignAlreadyEnded();
    error Web3Campaigns__TaskAlreadyCompleted();
    error Web3Campaigns__TaskNotVerifiableByHost();
    error Web3Campaigns__CampaignNotYetEnded();
    error Web3Campaigns__CampaignStartTimeNotYetStarted();
    error Web3Campaigns__TransferFailed();
    error Web3Campaigns__TaskNotFound();
    error Web3Campaigns__InvalidVerificationData();
    error Web3Campaigns__NotSelfVerifiable();
    error Web3Campaigns__InsufficientERC20Balance();
    error Web3Campaigns__NotHoldingSpecificERC721();
    error Web3Campaigns__InvalidCampaignDuration();
    error Web3Campaigns__InvalidTokenAddress();
    // Batch Operation Errors
    error Web3Campaigns__ArrayLengthMismatch();
    error Web3Campaigns__BatchTooLarge();
    // Merkle Settlement Errors
    error Web3Campaigns__ERC20RewardNotConfigured();
    error Web3Campaigns__InsufficientEscrow();
    error Web3Campaigns__MerkleRootNotSet();
    error Web3Campaigns__InvalidMerkleProof();
    error Web3Campaigns__AlreadyClaimedSettlement();
    error Web3Campaigns__GracePeriodActive();
    error Web3Campaigns__AlreadySwept();
    error Web3Campaigns__NothingToSweep();
    error Web3Campaigns__InvalidAmount();
    error Web3Campaigns__NFTNotEscrowed();
    // Signature Verification Errors
    error Web3Campaigns__SignatureExpired();
    error Web3Campaigns__InvalidSigner();
    error Web3Campaigns__TaskManagedBySignature();
    error Web3Campaigns__ZeroAddress();

    // Security constants
    uint256 public constant MIN_CAMPAIGN_DURATION = 1 hours;
    uint256 public constant MAX_CAMPAIGN_DURATION = 365 days;
    uint256 public constant MAX_PARTICIPANTS_LIMIT = 100_000;
    uint256 public constant RATE_LIMIT_COOLDOWN = 5 minutes;
    uint256 public constant JOIN_COOLDOWN = 1 minutes;
    uint256 public constant MAX_SUSPICIOUS_SCORE = 100;
    uint256 public constant MAX_BATCH_SIZE = 50;
    // Grace window after a campaign is Closed before the host may sweep unclaimed escrow
    uint256 public constant CLAIM_GRACE_PERIOD = 30 days;

    // EIP-712 typehash for a signed task-completion attestation. `version` is the per
    // (participant, campaign, task) attestation counter — it doubles as the leaf's replay
    // guard (a used signature's version can never be reused) AND lets a signer issue a fresh
    // attestation later to update/reverify a completion (e.g. flip completed back to false,
    // or re-affirm it), since each new attestation just targets the next version.
    bytes32 public constant TASK_ATTESTATION_TYPEHASH = keccak256(
        "TaskAttestation(uint256 campaignId,address participant,uint256 taskIndex,bool completed,uint256 version,uint256 deadline)"
    );
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

    // Supported NFT standards for Merkle-settled NFT rewards
    enum NFTStandard {
        ERC721, // tokenId is a specific NFT; amount is implicitly 1
        ERC1155 // tokenId is an id; amount is the quantity
    }

    // --- Structs ---
    struct CampaignTask {
        TaskType taskType;
        string description;
        bytes verificationData; // Use bytes for robust encoding/decoding
        bool isOptional;
    }

    // Off-chain / "other" reward (whitelist spot, physical prize, etc.). Informational only —
    // there is no on-chain payout; fulfillment is the host's responsibility off-chain.
    struct OffChainReward {
        bool enabled;
        string rewardDescription; // Description of off-chain reward
        bytes rewardMetadata; // Additional metadata (e.g., JSON)
    }

    struct Campaign {
        uint256 id;
        string name;
        address host;
        uint256 startTime;
        uint256 endTime;
        CampaignStatus status;
        CampaignTask[] tasks;
        uint224 createdAt;
        uint256 totalParticipants;
    }

    // --- State Variables (Internal to be accessible by inheriting contracts) ---
    uint256 internal _campaignCounter;
    mapping(uint256 => Campaign) internal _campaigns;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _participantTaskCompletion;
    mapping(address => mapping(uint256 => bool)) internal _participantClaimedReward;
    mapping(address => uint256[]) internal _hostCampaigns;
    mapping(address => mapping(uint256 => bool)) internal _hasParticipated;

    // Security tracking mappings
    mapping(address => uint256) internal _lastActivityTime;
    mapping(address => uint256) internal _userCampaignCount;
    mapping(address => uint256) internal _suspiciousActivityScore;

    // Off-chain reward config (informational; no on-chain payout)
    mapping(uint256 => OffChainReward) internal _offChainReward;

    // Signed task-completion attestation state: participant => campaignId => taskIndex => version.
    // 0 means no attestation has ever been applied; each accepted signature bumps this by 1.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _taskAttestationVersion;

    // --- Merkle settlement state (post-campaign ERC20 reward distribution) ---
    // Rewards are escrowed in the contract; after the campaign ends, the host publishes a
    // Merkle root of (account => amount) allocations computed off-chain, and participants
    // claim against it. This removes the live-claim front-running/silent-zero/host-pull risks.
    mapping(uint256 => address) internal _erc20RewardToken; // campaignId => ERC20 reward token (0 = none)
    mapping(uint256 => uint256) internal _erc20Escrowed; // campaignId => total ERC20 escrowed
    mapping(uint256 => uint256) internal _erc20Distributed; // campaignId => total ERC20 claimed
    mapping(uint256 => bytes32) internal _erc20MerkleRoot; // campaignId => settlement root
    mapping(uint256 => mapping(address => bool)) internal _erc20SettlementClaimed; // campaignId => account => claimed
    mapping(uint256 => uint64) internal _campaignClosedAt; // campaignId => close timestamp (grace start)
    mapping(uint256 => bool) internal _erc20Swept; // campaignId => unclaimed funds reclaimed by host

    // --- Multi-standard NFT (ERC721 + ERC1155) Merkle settlement state ---
    // NFTs are escrowed per-campaign (the ownership maps below prevent one campaign's
    // settlement from draining another's escrow), and distributed by Merkle proof after end.
    mapping(uint256 => bytes32) internal _nftMerkleRoot; // campaignId => NFT settlement root
    mapping(uint256 => mapping(bytes32 => bool)) internal _nftLeafClaimed; // campaignId => leaf => claimed
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) internal _escrowedERC721; // id => token => tokenId => held
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _escrowedERC1155; // id => token => tokenId => amount held

    // Events (can be defined here or in the main contract)
    event CampaignCreated(
        uint256 indexed campaignId, address indexed host, string name, uint256 startTime, uint256 endTime
    );
    event TaskAddedToCampaign(
        uint256 indexed campaignId, uint256 indexed taskId, TaskType taskType, string description
    );
    event CampaignStatusUpdated(uint256 indexed campaignId, CampaignStatus newStatus);
    event ParticipantTaskCompleted(uint256 indexed campaignId, address indexed participant, uint256 indexed taskId);

    //Events for Security Purposes
    event EmergencyPause(address indexed admin, uint256 timestamp);
    event EmergencyUnpause(address indexed admin, uint256 timestamp);
    event SecurityViolationDetected(address indexed user, string reason);
    event SuspiciousActivity(address indexed user, string activity);
    event AccountFlagged(address indexed user, uint256 score, address indexed moderator);
    event FundsReceived(address indexed sender, uint256 amount);
    event EtherWithdrawn(address indexed to, uint256 amount);

    event OffChainRewardConfigured(uint256 indexed campaignId, string description);
    event BatchTasksVerified(uint256 indexed campaignId, uint256 count);
    event BatchTasksAdded(uint256 indexed campaignId, uint256 count);
    event TaskVerifiedWithSignature(
        uint256 indexed campaignId,
        address indexed participant,
        uint256 indexed taskIndex,
        bool completed,
        uint256 version,
        address signer
    );

    // Merkle Settlement Events
    event ERC20RewardConfigured(uint256 indexed campaignId, address indexed token);
    event CampaignFundedERC20(uint256 indexed campaignId, address indexed funder, uint256 amount);
    event ERC20MerkleRootSet(uint256 indexed campaignId, bytes32 merkleRoot);
    event ERC20RewardClaimed(uint256 indexed campaignId, address indexed account, uint256 amount);
    event UnclaimedERC20Swept(uint256 indexed campaignId, address indexed to, uint256 amount);
    event NFTRewardsDeposited(uint256 indexed campaignId, address indexed token, NFTStandard standard, uint256 count);
    event NFTMerkleRootSet(uint256 indexed campaignId, bytes32 merkleRoot);
    event NFTRewardClaimed(
        uint256 indexed campaignId,
        address indexed account,
        NFTStandard standard,
        address token,
        uint256 tokenId,
        uint256 amount
    );
    event UnclaimedNFTsWithdrawn(
        uint256 indexed campaignId, address indexed token, NFTStandard standard, uint256 count
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

    modifier campaignTimeValid(uint256 _campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];
        require(
            block.timestamp >= campaign.startTime && block.timestamp <= campaign.endTime,
            "Campaign not in active period"
        );
        _;
    }

    /**
     * @notice Validate campaign parameters for security
     */
    function _validateCampaignParams(uint256 _startTime, uint256 _endTime) internal view {
        if (_startTime <= block.timestamp) {
            revert Web3Campaigns__CampaignStartTimeNotYetStarted();
        }
        if (_endTime <= _startTime) {
            revert Web3Campaigns__InvalidCampaignDuration();
        }
        if (_endTime - _startTime < MIN_CAMPAIGN_DURATION) {
            revert Web3Campaigns__InvalidCampaignDuration();
        }
        if (_endTime - _startTime > MAX_CAMPAIGN_DURATION) {
            revert Web3Campaigns__InvalidCampaignDuration();
        }
    }

    /**
     * @notice Rate limiting check
     */
    function _checkRateLimit(address _user) internal {
        require(block.timestamp - _lastActivityTime[_user] >= RATE_LIMIT_COOLDOWN, "Rate limit: too many actions");
        _lastActivityTime[_user] = block.timestamp;
    }
}
