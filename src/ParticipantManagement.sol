// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// This contract manages participant actions like completing tasks and claiming rewards.
contract ParticipantManagement is CampaignStorage {
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

    /**
     * @dev Allows a participant to mark a task as completed.
     * For off-chain tasks, this is a self-assertion that the host will later verify.
     * For on-chain tasks, this function performs direct on-chain verification.
     * @param _campaignId The ID of the campaign.
     * @param _taskIndex The index of the task within the campaign's tasks array.
     */
    function completeTask(uint256 _campaignId, uint256 _taskIndex) public virtual campaignTimeValid(_campaignId) {
        Campaign storage campaign = _campaigns[_campaignId];

        // Basic checks for campaign and task existence/status
        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Open) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        if (_taskIndex >= campaign.tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        if (_participantTaskCompletion[msg.sender][_campaignId][_taskIndex]) {
            revert Web3Campaigns__TaskAlreadyCompleted();
        }

        // SECURITY CHECKS
        require(_suspiciousActivityScore[msg.sender] < MAX_SUSPICIOUS_SCORE, "Account flagged for suspicious activity");

        // Anti-spam protection
        require(block.timestamp - _lastActivityTime[msg.sender] >= 30 seconds, "Too many rapid actions");

        CampaignTask storage currentTask = campaign.tasks[_taskIndex];

        // --- On-chain verification for specific task types ---
        if (currentTask.taskType == TaskType.ONCHAIN_HOLD_ERC20) {
            // Expects verificationData to be abi.encode(tokenAddress, requiredAmount)
            // Standard ABI encoding pads the address to a full word:
            // address (32 bytes) + uint256 (32 bytes) = 64 bytes
            if (currentTask.verificationData.length != 64) {
                revert Web3Campaigns__InvalidVerificationData();
            }

            (address tokenAddress, uint256 requiredAmount) =
                abi.decode(currentTask.verificationData, (address, uint256));

            // Perform the actual balance check
            if (IERC20(tokenAddress).balanceOf(msg.sender) < requiredAmount) {
                revert Web3Campaigns__InsufficientERC20Balance();
            }
        } else if (currentTask.taskType == TaskType.ONCHAIN_HOLD_ERC721) {
            // Expects verificationData to be abi.encode(tokenAddress, tokenId)
            // Standard ABI encoding pads the address to a full word:
            // address (32 bytes) + uint256 (32 bytes) = 64 bytes
            if (currentTask.verificationData.length != 64) {
                revert Web3Campaigns__InvalidVerificationData();
            }

            (address tokenAddress, uint256 tokenId) = abi.decode(currentTask.verificationData, (address, uint256));

            // Perform the actual ownership check
            // ERC721's ownerOf will revert if tokenId doesn't exist, which is fine.
            if (IERC721(tokenAddress).ownerOf(tokenId) != msg.sender) {
                revert Web3Campaigns__NotHoldingSpecificERC721();
            }
        } else if (currentTask.taskType == TaskType.ONCHAIN_TX) {
            // A specific on-chain transaction cannot be self-asserted here without an
            // oracle/proof system. It is instead settled via a signed attestation
            // (verifyTaskCompletionWithSignature), so we block self-completion rather
            // than hard-reverting the whole task type (which would brick claims for any
            // campaign that includes a mandatory ONCHAIN_TX task).
            revert Web3Campaigns__NotSelfVerifiable();
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

        // Update last activity time
        _lastActivityTime[msg.sender] = block.timestamp;
    }

    /**
     * @notice Verify (or update) a participant's off-chain task completion via a signed attestation.
     * @dev Replaces host-tx verification. A `SIGNER_ROLE` key (typically the host's backend,
     *      after checking Twitter/Discord/etc.) signs an EIP-712 `TaskAttestation` and anyone —
     *      the host, a relayer, or the participant — can submit it; the contract only trusts the
     *      recovered signer, not the caller. Any address holding `DEFAULT_ADMIN_ROLE` can grant or
     *      revoke `SIGNER_ROLE`, which is the rotation/revocation path for a compromised key.
     *
     *      Replay / update model: `version` is read as `_taskAttestationVersion[...] + 1` at call
     *      time and must match what the signer signed. Using a signature consumes that version, so
     *      it can never be replayed. A signer can later issue a fresh attestation (for the next
     *      version) to flip `completed` back to false or re-affirm it — e.g. to correct a mistake
     *      or re-verify a task that requires periodic proof (like continuing to hold a token).
     * @param _campaignId The ID of the campaign.
     * @param _participant The address the attestation is about.
     * @param _taskIndex The index of the task within the campaign's tasks array.
     * @param _completed Whether the signer is attesting the task as completed (true) or not (false).
     * @param _deadline Unix timestamp after which this specific attestation is no longer valid.
     * @param _signature EIP-712 signature over the TaskAttestation struct by a SIGNER_ROLE key.
     */
    function verifyTaskCompletionWithSignature(
        uint256 _campaignId,
        address _participant,
        uint256 _taskIndex,
        bool _completed,
        uint256 _deadline,
        bytes calldata _signature
    ) public virtual {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Open && campaign.status != CampaignStatus.Ended) {
            revert Web3Campaigns__CampaignNotOpen();
        }
        if (_taskIndex >= campaign.tasks.length) {
            revert Web3Campaigns__TaskNotFound();
        }
        // ONCHAIN_HOLD_* tasks are self-verified on-chain in completeTask and must NOT be
        // signer-overridable. ONCHAIN_TX is settled by the host's off-chain indexer, so it IS
        // signature-verifiable here.
        TaskType tType = campaign.tasks[_taskIndex].taskType;
        if (tType == TaskType.ONCHAIN_HOLD_ERC20 || tType == TaskType.ONCHAIN_HOLD_ERC721) {
            revert Web3Campaigns__TaskNotVerifiableByHost();
        }
        if (block.timestamp > _deadline) {
            revert Web3Campaigns__SignatureExpired();
        }

        uint256 nextVersion = _taskAttestationVersion[_participant][_campaignId][_taskIndex] + 1;

        bytes32 structHash = keccak256(
            abi.encode(
                TASK_ATTESTATION_TYPEHASH, _campaignId, _participant, _taskIndex, _completed, nextVersion, _deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), _signature);
        if (!hasRole(SIGNER_ROLE, signer)) {
            revert Web3Campaigns__InvalidSigner();
        }

        // Effects (CEI): consume the version (replay guard) before any state derived from it.
        _taskAttestationVersion[_participant][_campaignId][_taskIndex] = nextVersion;

        bool wasCompleted = _participantTaskCompletion[_participant][_campaignId][_taskIndex];
        _participantTaskCompletion[_participant][_campaignId][_taskIndex] = _completed;

        // totalParticipants tracks lifetime participation, not current completion status, so it
        // is only ever incremented on a participant's first-ever completed attestation/task.
        if (_completed && !wasCompleted && !_hasParticipated[_participant][_campaignId]) {
            _hasParticipated[_participant][_campaignId] = true;
            campaign.totalParticipants++;
        }

        if (_completed) {
            emit ParticipantTaskCompleted(_campaignId, _participant, _taskIndex);
        }
        emit TaskVerifiedWithSignature(_campaignId, _participant, _taskIndex, _completed, nextVersion, signer);
    }

    /**
     * @notice Verify (or update) task completion for multiple participants in one transaction.
     * @dev Each entry is independently signature-checked via verifyTaskCompletionWithSignature;
     *      the whole batch reverts if any single attestation is invalid or expired.
     * @param _campaignId The ID of the campaign
     * @param _participants Array of participant addresses
     * @param _taskIndices Array of task indices, one per participant
     * @param _completedFlags Array of completed flags, one per entry
     * @param _deadlines Array of signature deadlines, one per entry
     * @param _signatures Array of EIP-712 signatures, one per entry
     */
    function batchVerifyTaskCompletionWithSignatures(
        uint256 _campaignId,
        address[] calldata _participants,
        uint256[] calldata _taskIndices,
        bool[] calldata _completedFlags,
        uint256[] calldata _deadlines,
        bytes[] calldata _signatures
    ) public virtual {
        uint256 length = _participants.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert Web3Campaigns__BatchTooLarge();
        }
        if (
            _taskIndices.length != length || _completedFlags.length != length || _deadlines.length != length
                || _signatures.length != length
        ) {
            revert Web3Campaigns__ArrayLengthMismatch();
        }

        for (uint256 i; i < length; ++i) {
            verifyTaskCompletionWithSignature(
                _campaignId, _participants[i], _taskIndices[i], _completedFlags[i], _deadlines[i], _signatures[i]
            );
        }

        emit BatchTasksVerified(_campaignId, length);
    }

    /**
     * @notice Claim ERC20 rewards via post-campaign Merkle settlement.
     * @dev Allocations are computed off-chain after the campaign ends and committed as a
     *      Merkle root by the host (setERC20MerkleRoot). The leaf is the OpenZeppelin
     *      StandardMerkleTree format: keccak256(bytes.concat(keccak256(abi.encode(account, amount)))).
     *      Pays out of the contract-held escrow, so claims cannot be bricked by the host
     *      revoking an allowance, and there is no claim-order front-running.
     * @param _campaignId Campaign ID
     * @param _amount The exact allocation for msg.sender as committed in the tree
     * @param _proof Merkle proof for the (msg.sender, _amount) leaf
     */
    function claimERC20(uint256 _campaignId, uint256 _amount, bytes32[] calldata _proof) public virtual {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        // Claims open once the campaign has Ended; they remain open after Closed until the
        // host sweeps unclaimed funds (guarded by _erc20Swept in the transfer accounting).
        if (campaign.status != CampaignStatus.Ended && campaign.status != CampaignStatus.Closed) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }

        bytes32 root = _erc20MerkleRoot[_campaignId];
        if (root == bytes32(0)) {
            revert Web3Campaigns__MerkleRootNotSet();
        }
        if (_erc20SettlementClaimed[_campaignId][msg.sender]) {
            revert Web3Campaigns__AlreadyClaimedSettlement();
        }

        // OZ StandardMerkleTree leaf: double-hash of the ABI-encoded tuple.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, _amount))));
        if (!MerkleProof.verify(_proof, root, leaf)) {
            revert Web3Campaigns__InvalidMerkleProof();
        }

        // Effects (CEI): mark claimed and account the distribution before transferring.
        _erc20SettlementClaimed[_campaignId][msg.sender] = true;
        uint256 newDistributed = _erc20Distributed[_campaignId] + _amount;
        if (newDistributed > _erc20Escrowed[_campaignId]) {
            revert Web3Campaigns__InsufficientEscrow();
        }
        _erc20Distributed[_campaignId] = newDistributed;

        IERC20(_erc20RewardToken[_campaignId]).safeTransfer(msg.sender, _amount);

        emit ERC20RewardClaimed(_campaignId, msg.sender, _amount);
    }

    /**
     * @notice Claim an NFT reward (ERC721 or ERC1155) via post-campaign Merkle settlement.
     * @dev Allocations are computed off-chain and committed by the host (setNFTMerkleRoot).
     *      Leaf: keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount)))).
     *      Pays from the per-campaign escrow; the escrow ownership maps prevent draining another
     *      campaign's NFTs. nonReentrant + whenNotPaused via the Web3Campaigns wrapper.
     * @param _campaignId Campaign ID
     * @param _standard NFT standard (ERC721 or ERC1155)
     * @param _token NFT contract address
     * @param _tokenId Token id (specific NFT for ERC721; id for ERC1155)
     * @param _amount Quantity (1 for ERC721; arbitrary for ERC1155) — must match the tree leaf
     * @param _proof Merkle proof for the leaf
     */
    function claimNFT(
        uint256 _campaignId,
        NFTStandard _standard,
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        bytes32[] calldata _proof
    ) public virtual {
        Campaign storage campaign = _campaigns[_campaignId];

        if (campaign.id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        if (campaign.status != CampaignStatus.Ended && campaign.status != CampaignStatus.Closed) {
            revert Web3Campaigns__CampaignNotYetEnded();
        }

        bytes32 root = _nftMerkleRoot[_campaignId];
        if (root == bytes32(0)) {
            revert Web3Campaigns__MerkleRootNotSet();
        }

        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(msg.sender, uint8(_standard), _token, _tokenId, _amount))));
        if (_nftLeafClaimed[_campaignId][leaf]) {
            revert Web3Campaigns__AlreadyClaimedSettlement();
        }
        if (!MerkleProof.verify(_proof, root, leaf)) {
            revert Web3Campaigns__InvalidMerkleProof();
        }

        // Effects (CEI): mark the leaf claimed and decrement campaign escrow before transfer.
        _nftLeafClaimed[_campaignId][leaf] = true;

        if (_standard == NFTStandard.ERC721) {
            if (!_escrowedERC721[_campaignId][_token][_tokenId]) {
                revert Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC721[_campaignId][_token][_tokenId] = false;

            IERC721(_token).safeTransferFrom(address(this), msg.sender, _tokenId);
        } else {
            uint256 held = _escrowedERC1155[_campaignId][_token][_tokenId];
            if (_amount == 0 || _amount > held) {
                revert Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC1155[_campaignId][_token][_tokenId] = held - _amount;

            IERC1155(_token).safeTransferFrom(address(this), msg.sender, _tokenId, _amount, "");
        }

        emit NFTRewardClaimed(_campaignId, msg.sender, _standard, _token, _tokenId, _amount);
    }
}

