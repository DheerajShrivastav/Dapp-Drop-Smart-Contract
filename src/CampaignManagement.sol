// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeModule} from "./IFeeModule.sol";

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
    function revokeHostRole(address _account) public onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function createCampaign(string memory _name, uint256 _startTime, uint256 _endTime)
        public
        virtual
        onlyRole(HOST_ROLE)
        returns (uint256)
    {
        require(bytes(_name).length > 0 && bytes(_name).length <= 200, "Invalid name length");

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

        _hostCampaigns[msg.sender].push(campaignId);
        _userCampaignCount[msg.sender]++;

        emit CampaignCreated(campaignId, msg.sender, _name, _startTime, _endTime);
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
        require(bytes(_description).length > 0 && bytes(_description).length <= 1000, "Invalid description length");

        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        // Limit tasks per campaign for security
        require(campaign.tasks.length < 20, "Too many tasks per campaign");

        campaign.tasks
            .push(
                CampaignTask({
                    taskType: _taskType,
                    description: _description,
                    verificationData: _verificationData,
                    isOptional: _isOptional
                })
            );

        emit TaskAddedToCampaign(_campaignId, campaign.tasks.length - 1, _taskType, _description);
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
        if (_descriptions.length != length || _verificationData.length != length || _isOptional.length != length) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        require(campaign.tasks.length + length <= 20, "Too many tasks per campaign");

        for (uint256 i; i < length; ++i) {
            require(
                bytes(_descriptions[i]).length > 0 && bytes(_descriptions[i]).length <= 1000,
                "Invalid description length"
            );

            campaign.tasks
                .push(
                    CampaignTask({
                        taskType: _taskTypes[i],
                        description: _descriptions[i],
                        verificationData: _verificationData[i],
                        isOptional: _isOptional[i]
                    })
                );

            emit TaskAddedToCampaign(_campaignId, campaign.tasks.length - 1, _taskTypes[i], _descriptions[i]);
        }

        emit BatchTasksAdded(_campaignId, length);
    }

    // ============================================
    // FLEXIBLE REWARD CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Configure the ERC20 reward token for a campaign.
     * @dev This setter only records WHICH token will be paid; the host must escrow it with
     *      fundCampaignERC20 before opening the campaign. It deliberately does NOT commit the
     *      campaign to a settlement mode -- token configuration is common to ALL three ERC20
     *      settlement paths (MERKLE, RANK_TIERED, SCORE_TIERED), so committing MERKLE here would
     *      wrongly foreclose the on-chain-tiered paths. The mode is committed later by the action
     *      specific to each path: setERC20MerkleRoot for MERKLE, or the module's
     *      setRankTiers/setScoreTiers (via the setSettlementMode callback) for the tiered paths.
     * @param _campaignId Campaign ID
     * @param _tokenAddress ERC20 token contract address
     */
    function configureERC20Reward(uint256 _campaignId, address _tokenAddress) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        if (_tokenAddress == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }

        _erc20RewardToken[_campaignId] = _tokenAddress;

        emit ERC20RewardConfigured(_campaignId, _tokenAddress);
    }

    /// @dev Commits a campaign to an ERC20 settlement mode (MERKLE / RANK_TIERED / SCORE_TIERED).
    /// A campaign may only ever commit to one mode: the first configuration call after
    /// creation sets it from UNSET, and re-configuring the SAME mode while still Draft is allowed
    /// (e.g. re-publishing tiers), but switching to a DIFFERENT mode once one has been chosen is
    /// rejected -- this is what makes the three settlement paths mutually exclusive per campaign.
    function _lockSettlementMode(uint256 _campaignId, ERC20SettlementMode _mode) internal {
        ERC20SettlementMode current = _erc20SettlementMode[_campaignId];
        if (current != ERC20SettlementMode.UNSET && current != _mode) {
            revert Web3Campaigns__SettlementModeAlreadySet();
        }
        _erc20SettlementMode[_campaignId] = _mode;
    }

    /**
     * @notice Escrow ERC20 reward tokens into the contract for a campaign.
     * @dev Pulls tokens from the caller (host) into the contract. Allowed in Draft, Open,
     *      or Ended (so the host can top up if the published allocation needs more than was
     *      initially escrowed). The host must approve this contract first.
     * @param _campaignId Campaign ID
     * @param _amount Amount of the configured reward token to escrow
     */
    function fundCampaignERC20(uint256 _campaignId, uint256 _amount) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        address token = _erc20RewardToken[_campaignId];
        if (token == address(0)) {
            revert Web3Campaigns__ERC20RewardNotConfigured();
        }
        if (_amount == 0) {
            revert Web3Campaigns__InvalidAmount();
        }
        if (
            campaign.status != CampaignStatus.Draft && campaign.status != CampaignStatus.Open
                && campaign.status != CampaignStatus.Ended
        ) {
            revert Web3Campaigns__CampaignAlreadyEnded();
        }

        // Optional protocol-fee skim: the host still transfers the full _amount from their wallet;
        // this contract splits it between campaign escrow and the fee module's treasury. No fee
        // module registered (the default) means feeAmount is always 0 and behavior is unchanged.
        // computeFee is a `view` call -- Solidity emits a STATICCALL for it, so a malicious module
        // cannot reenter with a state-changing call from inside this computation.
        uint256 feeAmount;
        address treasury;
        if (_feeModule != address(0)) {
            (feeAmount, treasury) = IFeeModule(_feeModule).computeFee(_campaignId, _amount);
            if (feeAmount > _amount) {
                revert Web3Campaigns__FeeExceedsAmount();
            }
        }
        uint256 escrowAmount = _amount - feeAmount;

        // Effects before interaction (escrow tracked on measured received amount would be
        // ideal for fee-on-transfer tokens; standard tokens are assumed here).
        _erc20Escrowed[_campaignId] += escrowAmount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(treasury, feeAmount);
            emit ProtocolFeeCollected(_campaignId, treasury, feeAmount);
        }

        emit CampaignFundedERC20(_campaignId, msg.sender, escrowAmount);
    }

    /**
     * @notice Publish (or update) the ERC20 reward Merkle root for settlement.
     * @dev Only after the campaign has Ended. The root commits to leaves of
     *      keccak256(bytes.concat(keccak256(abi.encode(account, amount)))) — the
     *      OpenZeppelin StandardMerkleTree format. Updatable while Ended (e.g. to fix an
     *      allocation); frozen once the campaign is Closed. Publishing a NEW root value rearms
     *      ROOT_DISPUTE_WINDOW (claimERC20 rejects claims against it until the window elapses); a
     *      no-op republish of the byte-identical root does not rearm, since there is nothing new
     *      for participants to review.
     * @param _campaignId Campaign ID
     * @param _merkleRoot The settlement Merkle root
     */
    function setERC20MerkleRoot(uint256 _campaignId, bytes32 _merkleRoot) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        // Publishing a Merkle root is the MERKLE-path-specific action, so it is what commits the
        // campaign to MERKLE settlement (from UNSET) -- or, if the campaign already committed to a
        // tiered mode via the module, reverts SettlementModeAlreadySet, keeping the Merkle and
        // on-chain-tiered paths mutually exclusive on any single campaign.
        _lockSettlementMode(_campaignId, ERC20SettlementMode.MERKLE);
        if (_erc20RewardToken[_campaignId] == address(0)) {
            revert Web3Campaigns__ERC20RewardNotConfigured();
        }
        if (_merkleRoot == bytes32(0)) {
            revert Web3Campaigns__MerkleRootNotSet();
        }

        // Only rearm the dispute window if the root is actually changing -- a no-op republish of
        // the byte-identical root gives participants nothing new to review, so it must not let a
        // host indefinitely push out claimableAt while a real root sits published.
        if (_erc20MerkleRoot[_campaignId] != _merkleRoot) {
            _erc20RootSetAt[_campaignId] = uint64(block.timestamp);
        }
        _erc20MerkleRoot[_campaignId] = _merkleRoot;
        emit ERC20MerkleRootSet(_campaignId, _merkleRoot);
    }

    /**
     * @notice Trusted callback: the registered OnChainRewardModule reports that a campaign has
     *         committed to a settlement mode (RANK_TIERED or SCORE_TIERED), so Web3Campaigns can
     *         cheaply gate claimERC20's Merkle-path check locally without a cross-contract call.
     * @dev Restricted to msg.sender == the registered module. Reuses the same mutual-exclusion guard
     *      (_lockSettlementMode) as setERC20MerkleRoot's MERKLE commitment, so a campaign already
     *      committed to one mode can never be silently switched to another from either side.
     * @param _campaignId Campaign ID
     * @param _mode The mode the module has committed this campaign to
     */
    function setSettlementMode(uint256 _campaignId, ERC20SettlementMode _mode) external {
        if (msg.sender != _onChainRewardModule) {
            revert Web3Campaigns__NotOnChainRewardModule();
        }
        _lockSettlementMode(_campaignId, _mode);

        // Pin the authoritative module for this campaign the first time it adopts an on-chain
        // (tiered) settlement mode. Pinning is idempotent: the same-mode re-config that legitimately
        // re-invokes this callback (e.g. a host re-publishing tiers while Draft) leaves an existing
        // pin untouched and does not re-emit. Because the pin is captured once, a later rotation of
        // the global _onChainRewardModule cannot retroactively reassign an already-adopted campaign.
        if (_mode == ERC20SettlementMode.RANK_TIERED || _mode == ERC20SettlementMode.SCORE_TIERED) {
            if (_campaignRewardModule[_campaignId] == address(0)) {
                _campaignRewardModule[_campaignId] = _onChainRewardModule;
                emit RewardModulePinned(_campaignId, _onChainRewardModule);
            }
        }
    }

    /**
     * @notice Reclaim ERC20 escrow that was never claimed, after the grace period.
     * @dev Callable by the host once the campaign is Closed and CLAIM_GRACE_PERIOD has
     *      elapsed since closing. Transfers the unclaimed remainder back to the host.
     * @param _campaignId Campaign ID
     */
    function withdrawUnclaimedERC20(uint256 _campaignId) public virtual onlyHost(_campaignId) {
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
     * @notice Escrow ERC721 NFTs into the campaign for later Merkle-settled distribution.
     * @dev Pulls each tokenId from the host into the contract via safeTransferFrom and records
     *      per-campaign ownership (so one campaign's settlement cannot drain another's escrow).
     *      Allowed in Draft/Open/Ended. The host must approve this contract first.
     * @param _campaignId Campaign ID
     * @param _token ERC721 contract address
     * @param _tokenIds Token IDs to escrow (max 100 per call)
     */
    function depositERC721Rewards(uint256 _campaignId, address _token, uint256[] calldata _tokenIds)
        public
        virtual
        onlyHost(_campaignId)
    {
        _requireFundingStatus(_campaignId);
        if (_token == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        uint256 len = _tokenIds.length;
        if (len == 0 || len > 100) {
            revert Web3Campaigns__BatchTooLarge();
        }

        for (uint256 i; i < len; ++i) {
            _escrowedERC721[_campaignId][_token][_tokenIds[i]] = true;
        }

        emit NFTRewardsDeposited(_campaignId, _token, NFTStandard.ERC721, len);

        // Interactions after effects (CEI)
        for (uint256 i; i < len; ++i) {
            IERC721(_token).safeTransferFrom(msg.sender, address(this), _tokenIds[i]);
        }
    }

    /**
     * @notice Escrow ERC1155 tokens into the campaign for later Merkle-settled distribution.
     * @param _campaignId Campaign ID
     * @param _token ERC1155 contract address
     * @param _ids Token ids
     * @param _amounts Amounts per id (parallel array)
     */
    function depositERC1155Rewards(
        uint256 _campaignId,
        address _token,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) public virtual onlyHost(_campaignId) {
        _requireFundingStatus(_campaignId);
        if (_token == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        uint256 len = _ids.length;
        if (len == 0 || len > 100) {
            revert Web3Campaigns__BatchTooLarge();
        }
        if (_amounts.length != len) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            if (_amounts[i] == 0) {
                revert Web3Campaigns__InvalidAmount();
            }
            _escrowedERC1155[_campaignId][_token][_ids[i]] += _amounts[i];
        }

        emit NFTRewardsDeposited(_campaignId, _token, NFTStandard.ERC1155, len);

        IERC1155(_token).safeBatchTransferFrom(msg.sender, address(this), _ids, _amounts, "");
    }

    /**
     * @notice Publish (or update) the NFT reward Merkle root for settlement.
     * @dev Only after the campaign has Ended. Leaf format:
     *      keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount)))).
     *      Updatable while Ended, frozen at Closed. Publishing a NEW root value rearms
     *      ROOT_DISPUTE_WINDOW (claimNFT rejects claims against it until the window elapses); a
     *      no-op republish of the byte-identical root does not rearm.
     * @param _campaignId Campaign ID
     * @param _merkleRoot The settlement Merkle root
     */
    function setNFTMerkleRoot(uint256 _campaignId, bytes32 _merkleRoot) public onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        if (_merkleRoot == bytes32(0)) {
            revert Web3Campaigns__MerkleRootNotSet();
        }

        // Only rearm the dispute window if the root is actually changing -- see the identical
        // comment in setERC20MerkleRoot.
        if (_nftMerkleRoot[_campaignId] != _merkleRoot) {
            _nftRootSetAt[_campaignId] = uint64(block.timestamp);
        }
        _nftMerkleRoot[_campaignId] = _merkleRoot;
        emit NFTMerkleRootSet(_campaignId, _merkleRoot);
    }

    /**
     * @notice Reclaim still-escrowed ERC721 NFTs after the grace period (unclaimed by winners).
     * @dev Campaign must be Closed and CLAIM_GRACE_PERIOD elapsed. Only tokenIds still escrowed
     *      (not claimed, not from another campaign) can be reclaimed.
     */
    function withdrawUnclaimedERC721(uint256 _campaignId, address _token, uint256[] calldata _tokenIds)
        public
        virtual
        onlyHost(_campaignId)
    {
        _requireSweepable(_campaignId);
        uint256 len = _tokenIds.length;
        if (len == 0 || len > 100) {
            revert Web3Campaigns__BatchTooLarge();
        }

        for (uint256 i; i < len; ++i) {
            if (!_escrowedERC721[_campaignId][_token][_tokenIds[i]]) {
                revert Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC721[_campaignId][_token][_tokenIds[i]] = false;
        }

        emit UnclaimedNFTsWithdrawn(_campaignId, _token, NFTStandard.ERC721, len);

        address host = _campaigns[_campaignId].host;
        for (uint256 i; i < len; ++i) {
            IERC721(_token).safeTransferFrom(address(this), host, _tokenIds[i]);
        }
    }

    /**
     * @notice Reclaim still-escrowed ERC1155 balances after the grace period.
     */
    function withdrawUnclaimedERC1155(
        uint256 _campaignId,
        address _token,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) public virtual onlyHost(_campaignId) {
        _requireSweepable(_campaignId);
        uint256 len = _ids.length;
        if (len == 0 || len > 100) {
            revert Web3Campaigns__BatchTooLarge();
        }
        if (_amounts.length != len) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            uint256 held = _escrowedERC1155[_campaignId][_token][_ids[i]];
            if (_amounts[i] == 0 || _amounts[i] > held) {
                revert Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC1155[_campaignId][_token][_ids[i]] = held - _amounts[i];
        }

        emit UnclaimedNFTsWithdrawn(_campaignId, _token, NFTStandard.ERC1155, len);

        IERC1155(_token).safeBatchTransferFrom(address(this), _campaigns[_campaignId].host, _ids, _amounts, "");
    }

    /// @dev Shared status guard for reward deposits (Draft/Open/Ended top-up).
    function _requireFundingStatus(uint256 _campaignId) internal view {
        CampaignStatus s = _campaigns[_campaignId].status;
        if (s != CampaignStatus.Draft && s != CampaignStatus.Open && s != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignAlreadyEnded();
        }
    }

    /// @dev Shared guard for unclaimed sweeps: Closed + grace elapsed, OR Cancelled (immediate --
    /// cancellation is only possible while totalParticipants == 0, so no Merkle root could ever have
    /// been published and no claim could ever have been made; there is no race to protect against).
    function _requireSweepable(uint256 _campaignId) internal view {
        CampaignStatus s = _campaigns[_campaignId].status;
        if (s == CampaignStatus.Cancelled) {
            return;
        }
        if (s != CampaignStatus.Closed) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }
        if (block.timestamp < _campaignClosedAt[_campaignId] + CLAIM_GRACE_PERIOD) {
            revert Web3Campaigns__GracePeriodActive();
        }
    }

    /**
     * @notice Cancel a campaign before anyone has participated, refunding escrowed ERC20 rewards.
     * @dev Only allowed while status is Draft or Open AND totalParticipants == 0 -- the moment a
     *      single participant has genuinely engaged, the campaign is locked in and must run its
     *      normal course (Ended -> Closed -> claims/unclaimed sweep). This closes off a
     *      bait-and-switch griefing path where a host could otherwise let participants do free
     *      work and then cancel right before Ended to dodge paying out.
     *      Escrowed NFTs (if any) are NOT auto-refunded here since there is no on-chain enumerable
     *      inventory list per campaign -- call withdrawUnclaimedERC721/withdrawUnclaimedERC1155
     *      afterward (they become immediately callable once Cancelled, no grace period, for the
     *      same reason described on _requireSweepable).
     * @param _campaignId Campaign ID
     */
    function cancelCampaign(uint256 _campaignId) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Draft && campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignNotCancellable();
        }
        if (campaign.totalParticipants != 0) {
            revert Web3Campaigns__CampaignHasParticipants();
        }

        campaign.status = CampaignStatus.Cancelled;
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Cancelled);

        uint256 refunded = _refundERC20IfAny(_campaignId);
        emit CampaignCancelled(_campaignId, campaign.host, refunded);
    }

    /// @dev Silently refunds any escrowed-but-undistributed ERC20 to the host and marks the
    /// campaign swept, without reverting if there's nothing configured/escrowed to refund (unlike
    /// the explicit withdrawUnclaimedERC20, which is meant to be called standalone and should be
    /// noisy about a no-op). Distributed is guaranteed 0 here since claims require Ended status,
    /// which cancelCampaign's own guard never allows.
    function _refundERC20IfAny(uint256 _campaignId) internal returns (uint256 refunded) {
        if (_erc20Swept[_campaignId]) {
            return 0;
        }
        _erc20Swept[_campaignId] = true;
        address token = _erc20RewardToken[_campaignId];
        if (token == address(0)) {
            return 0;
        }
        refunded = _erc20Escrowed[_campaignId] - _erc20Distributed[_campaignId];
        if (refunded == 0) {
            return 0;
        }

        address host = _campaigns[_campaignId].host;
        IERC20(token).safeTransfer(host, refunded);
    }

    /**
     * @notice Configure off-chain/other reward
     * @dev Used for whitelist spots, physical prizes, etc.
     * @param _campaignId Campaign ID
     * @param _description Description of the reward
     * @param _metadata Additional metadata (can be JSON encoded)
     */
    function setOffChainReward(uint256 _campaignId, string memory _description, bytes memory _metadata)
        public
        onlyHost(_campaignId)
    {
        if (_campaigns[_campaignId].status != CampaignStatus.Draft) {
            revert Web3Campaigns__CampaignAlreadyStarted();
        }
        require(bytes(_description).length > 0, "Description required");
        require(bytes(_description).length <= 500, "Description too long");

        OffChainReward storage offChain = _offChainReward[_campaignId];
        offChain.enabled = true;
        offChain.rewardDescription = _description;
        offChain.rewardMetadata = _metadata;

        emit OffChainRewardConfigured(_campaignId, _description);
    }

    /**
     * @dev Sets the campaign status to Open. Can only be called by the host.
     * @param _campaignId The ID of the campaign.
     */
    function openCampaign(uint256 _campaignId) public virtual onlyHost(_campaignId) {
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
    function endCampaign(uint256 _campaignId) public virtual onlyHost(_campaignId) {
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
    function closeCampaign(uint256 _campaignId) public virtual onlyHost(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }

        campaign.status = CampaignStatus.Closed;
        _campaignClosedAt[_campaignId] = uint64(block.timestamp); // start of the unclaimed-sweep grace window
        emit CampaignStatusUpdated(_campaignId, CampaignStatus.Closed);
    }
}
