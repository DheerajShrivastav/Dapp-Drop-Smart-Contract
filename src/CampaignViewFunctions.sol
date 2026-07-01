// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";

// This contract provides all the view (read-only) functions for the system.
contract CampaignViewFunctions is CampaignStorage {
    /**
     * @dev Retrieves campaign details.
     * @param _campaignId The ID of the campaign.
     * @return Campaign struct.
     */
    function getCampaign(uint256 _campaignId) public view returns (Campaign memory) {
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
    function getCampaignTask(uint256 _campaignId, uint256 _taskIndex) public view returns (CampaignTask memory) {
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
    function hasCompletedTask(uint256 _campaignId, address _participant, uint256 _taskIndex)
        public
        view
        returns (bool)
    {
        return _participantTaskCompletion[_participant][_campaignId][_taskIndex];
    }

    /**
     * @dev Checks if a participant has claimed the reward for a specific campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if claimed, false otherwise.
     */
    function hasClaimedReward(uint256 _campaignId, address _participant) public view returns (bool) {
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
    function getCampaignsByHost(address _host) public view returns (uint256[] memory) {
        return _hostCampaigns[_host];
    }

    /**
     * @dev Returns whether a participant has started participating in a campaign.
     * @param _campaignId The ID of the campaign.
     * @param _participant The address of the participant.
     * @return True if the participant has started, false otherwise.
     */
    function hasParticipated(uint256 _campaignId, address _participant) public view returns (bool) {
        return _hasParticipated[_participant][_campaignId];
    }

    // ============================================
    // REWARD VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the off-chain reward configuration for a campaign.
     * @param _campaignId Campaign ID
     * @return OffChainReward struct (enabled, description, metadata)
     */
    function getOffChainReward(uint256 _campaignId) external view returns (OffChainReward memory) {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        return _offChainReward[_campaignId];
    }

    // ============================================
    // MERKLE SETTLEMENT VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the ERC20 Merkle settlement state for a campaign.
     * @param _campaignId Campaign ID
     * @return token The configured ERC20 reward token (address(0) if unconfigured)
     * @return escrowed Total tokens escrowed
     * @return distributed Total tokens claimed so far
     * @return merkleRoot The published settlement root (bytes32(0) if not yet set)
     * @return closedAt Timestamp the campaign was Closed (0 if not closed)
     * @return swept Whether the host has reclaimed the unclaimed remainder
     */
    function getERC20Settlement(uint256 _campaignId)
        external
        view
        returns (address token, uint256 escrowed, uint256 distributed, bytes32 merkleRoot, uint64 closedAt, bool swept)
    {
        if (_campaigns[_campaignId].id == 0) {
            revert Web3Campaigns__CampaignNotFound();
        }
        token = _erc20RewardToken[_campaignId];
        escrowed = _erc20Escrowed[_campaignId];
        distributed = _erc20Distributed[_campaignId];
        merkleRoot = _erc20MerkleRoot[_campaignId];
        closedAt = _campaignClosedAt[_campaignId];
        swept = _erc20Swept[_campaignId];
    }

    /**
     * @notice Whether an account has claimed its ERC20 settlement allocation.
     * @param _campaignId Campaign ID
     * @param _account The account to check
     * @return True if the account has already claimed via claimERC20
     */
    function hasClaimedERC20(uint256 _campaignId, address _account) external view returns (bool) {
        return _erc20SettlementClaimed[_campaignId][_account];
    }

    /**
     * @notice Get the NFT settlement Merkle root for a campaign (bytes32(0) if unset).
     */
    function getNFTMerkleRoot(uint256 _campaignId) external view returns (bytes32) {
        return _nftMerkleRoot[_campaignId];
    }

    /**
     * @notice Whether a specific NFT settlement leaf has been claimed.
     * @dev Recompute the leaf as
     *      keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount)))).
     */
    function isNFTLeafClaimed(uint256 _campaignId, bytes32 _leaf) external view returns (bool) {
        return _nftLeafClaimed[_campaignId][_leaf];
    }

    /**
     * @notice Whether a given ERC721 tokenId is currently escrowed for a campaign.
     */
    function isERC721Escrowed(uint256 _campaignId, address _token, uint256 _tokenId) external view returns (bool) {
        return _escrowedERC721[_campaignId][_token][_tokenId];
    }

    /**
     * @notice Escrowed ERC1155 balance for a campaign/token/id.
     */
    function getERC1155Escrowed(uint256 _campaignId, address _token, uint256 _tokenId) external view returns (uint256) {
        return _escrowedERC1155[_campaignId][_token][_tokenId];
    }
}

