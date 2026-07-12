// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {CampaignStorage} from "./CampaignStorage.sol";
import {CampaignManagement} from "./CampaignManagement.sol";
import {ParticipantManagement} from "./ParticipantManagement.sol";
import {CampaignViewFunctions} from "./CampaignViewFunctions.sol";

contract Web3Campaigns is
    CampaignManagement,
    ParticipantManagement,
    CampaignViewFunctions,
    ReentrancyGuard,
    Pausable,
    ERC721Holder,
    ERC1155Holder
{
    // Version for tracking contract upgrades
    string public constant VERSION = "0.5.0";

    constructor() {
        // Grant emergency admin, moderator, and (bootstrap) signer roles to deployer.
        // DEFAULT_ADMIN_ROLE can grantRole/revokeRole(SIGNER_ROLE, ...) to rotate backend
        // attestation keys without any custom rotation function — that's the intended path.
        _grantRole(EMERGENCY_ADMIN, msg.sender);
        _grantRole(MODERATOR_ROLE, msg.sender);
        _grantRole(SIGNER_ROLE, msg.sender);
    }

    /**
     * @notice Flag (or clear) an account's suspicious-activity score.
     * @dev Wires the anti-abuse gate enforced in ParticipantManagement.completeTask,
     *      which previously read a score that was never written. Setting a score >=
     *      MAX_SUSPICIOUS_SCORE blocks the account from completing tasks; set to 0 to clear.
     * @param _user The account to flag.
     * @param _score The suspicious-activity score to assign.
     */
    function flagAccount(address _user, uint256 _score) external onlyRole(MODERATOR_ROLE) {
        if (_user == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        _suspiciousActivityScore[_user] = _score;
        emit AccountFlagged(_user, _score, msg.sender);
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
    modifier onlyHost(uint256 _campaignId) override(CampaignManagement, ParticipantManagement, CampaignStorage) {
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
        require(_campaigns[_campaignId].status == CampaignStatus.Open, "Campaign not active");
        _;
    }

    /**
     * @notice Withdraw ETH from the contract to prevent locked ether
     */
    function withdrawETH(address payable _to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_to == address(0)) {
            revert Web3Campaigns__InvalidTokenAddress();
        }
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert Web3Campaigns__TransferFailed();
        }

        emit EtherWithdrawn(_to, balance);

        (bool success,) = _to.call{value: balance}("");
        if (!success) {
            revert Web3Campaigns__TransferFailed();
        }
    }

    receive() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Invalid ETH amount");
        emit FundsReceived(msg.sender, msg.value);
    }

    fallback() external payable whenNotPaused {
        revert("Function does not exist");
    }

    // Secure wrapper for CampaignManagement.createCampaign
    function createCampaign(string memory _name, uint256 _startTime, uint256 _endTime)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        return super.createCampaign(_name, _startTime, _endTime);
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

    // Secure wrapper for CampaignManagement.cancelCampaign
    function cancelCampaign(uint256 _campaignId) public override whenNotPaused nonReentrant {
        super.cancelCampaign(_campaignId);
    }

    // Secure wrapper for ParticipantManagement.completeTask
    function completeTask(uint256 _campaignId, uint256 _taskIndex) public override whenNotPaused nonReentrant {
        super.completeTask(_campaignId, _taskIndex);
    }

    // Secure wrapper for ParticipantManagement.verifyTaskCompletionWithSignature
    function verifyTaskCompletionWithSignature(
        uint256 _campaignId,
        address _participant,
        uint256 _taskIndex,
        bool _completed,
        uint256 _deadline,
        bytes calldata _signature
    ) public override whenNotPaused nonReentrant {
        super.verifyTaskCompletionWithSignature(
            _campaignId, _participant, _taskIndex, _completed, _deadline, _signature
        );
    }

    // Secure wrapper for ParticipantManagement.batchVerifyTaskCompletionWithSignatures
    function batchVerifyTaskCompletionWithSignatures(
        uint256 _campaignId,
        address[] calldata _participants,
        uint256[] calldata _taskIndices,
        bool[] calldata _completedFlags,
        uint256[] calldata _deadlines,
        bytes[] calldata _signatures
    ) public override whenNotPaused nonReentrant {
        super.batchVerifyTaskCompletionWithSignatures(
            _campaignId, _participants, _taskIndices, _completedFlags, _deadlines, _signatures
        );
    }

    // Secure wrapper for CampaignManagement.fundCampaignERC20
    function fundCampaignERC20(uint256 _campaignId, uint256 _amount) public override whenNotPaused nonReentrant {
        super.fundCampaignERC20(_campaignId, _amount);
    }

    // Secure wrapper for ParticipantManagement.claimERC20
    function claimERC20(uint256 _campaignId, uint256 _amount, bytes32[] calldata _proof)
        public
        override
        whenNotPaused
        nonReentrant
    {
        super.claimERC20(_campaignId, _amount, _proof);
    }

    // Secure wrapper for CampaignManagement.withdrawUnclaimedERC20
    function withdrawUnclaimedERC20(uint256 _campaignId) public override whenNotPaused nonReentrant {
        super.withdrawUnclaimedERC20(_campaignId);
    }

    // Secure wrapper for ParticipantManagement.payOnChainReward
    function payOnChainReward(uint256 _campaignId, address _participant, uint256 _amount, uint256 _rankOrScore)
        public
        override
        whenNotPaused
        nonReentrant
    {
        super.payOnChainReward(_campaignId, _participant, _amount, _rankOrScore);
    }

    /**
     * @notice Register (or rotate) the trusted OnChainRewardModule contract address.
     * @dev Admin-rotatable rather than set-once-immutable -- an explicit, disclosed exception to
     *      this project's no-upgradability policy, needed so a compromised or buggy module can be
     *      swapped out without redeploying Web3Campaigns itself (which retains all fund custody).
     * @param _module The new module address (may be address(0) to disable the feature).
     */
    function setOnChainRewardModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _onChainRewardModule = _module;
        emit OnChainRewardModuleUpdated(_module);
    }

    /**
     * @notice Register (or rotate) the trusted protocol-fee module, or disable fees (address(0)).
     * @dev Admin-rotatable, same pattern as setOnChainRewardModule. Unlike that module, rotating
     *      this one carries no in-flight-campaign hazard: fee computation has no persistent
     *      per-campaign state (see IFeeModule.sol) -- a rotation only changes the rate/treasury used
     *      by fundCampaignERC20 calls made AFTER it, which is the intended effect.
     * @param _module The new fee module address (may be address(0) to disable fees).
     */
    function setFeeModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _feeModule = _module;
        emit FeeModuleUpdated(_module);
    }

    /**
     * @notice Register (or rotate) the trusted default NFTSettlementModule contract address.
     * @dev Admin-rotatable, same pattern as setOnChainRewardModule. Only affects campaigns that
     *      have NOT yet received their first NFT deposit -- each campaign pins to whichever module
     *      was current at that moment (CampaignManagement._pinNFTModule), so a rotation can never
     *      desync a campaign's already-recorded escrow bookkeeping.
     * @param _module The new module address (may be address(0) to disable new NFT deposits).
     */
    function setNFTSettlementModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nftModule = _module;
        emit NFTModuleUpdated(_module);
    }

    // ---- NFT (multi-standard) settlement wrappers ----
    // setNFTMerkleRoot/claimNFT/withdrawUnclaimedERC721/withdrawUnclaimedERC1155 are no longer
    // Web3Campaigns functions -- call them directly on the campaign's NFTSettlementModule (see
    // getCampaignNFTModule). Web3Campaigns keeps custody and deposits; executeNFTTransferOut is the
    // trusted callback the pinned module uses to move a token once it has validated everything.

    function depositERC721Rewards(uint256 _campaignId, address _token, uint256[] calldata _tokenIds)
        public
        override
        whenNotPaused
        nonReentrant
    {
        super.depositERC721Rewards(_campaignId, _token, _tokenIds);
    }

    function depositERC1155Rewards(
        uint256 _campaignId,
        address _token,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) public override whenNotPaused nonReentrant {
        super.depositERC1155Rewards(_campaignId, _token, _ids, _amounts);
    }

    // Secure wrapper for ParticipantManagement.executeNFTTransferOut
    function executeNFTTransferOut(
        uint256 _campaignId,
        NFTStandard _standard,
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        address _recipient
    ) public override whenNotPaused nonReentrant {
        super.executeNFTTransferOut(_campaignId, _standard, _token, _tokenId, _amount, _recipient);
    }

    /// @dev Resolve the diamond inheritance of supportsInterface (AccessControl + ERC1155Holder).
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
