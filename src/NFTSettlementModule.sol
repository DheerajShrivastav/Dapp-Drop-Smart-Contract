// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {CampaignStorage} from "./CampaignStorage.sol";
import {IWeb3CampaignsForNFTModule} from "./IWeb3CampaignsForNFTModule.sol";
import {INFTSettlementModule} from "./INFTSettlementModule.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Standalone settlement engine for multi-standard (ERC721 + ERC1155) NFT Merkle
/// settlement -- extracted from Web3Campaigns purely for EIP-170 bytecode headroom (the entrypoint
/// was down to ~747B before this split). Web3Campaigns retains ALL NFT custody (it alone implements
/// ERC721Holder/ERC1155Holder) and all core campaign state; this module holds the settlement logic
/// (Merkle roots, leaf-claimed tracking, per-campaign escrow bookkeeping) and never moves a token
/// itself -- every transfer is executed by calling back into Web3Campaigns' trusted
/// executeNFTTransferOut.
///
/// Unlike OnChainRewardModule/FeeModule, participants and hosts call THIS contract directly for
/// setNFTMerkleRoot/claimNFT/withdrawUnclaimed* (mirroring OnChainRewardModule.claimReward, not
/// Web3Campaigns-forwards-to-module) -- this is the entrypoint shape with the best size payoff,
/// since the validation-heavy function bodies live entirely in this contract's own EIP-170 budget.
///
/// Trust boundary, both directions:
/// - Web3Campaigns only accepts executeNFTTransferOut from the campaign's PINNED module
///   (_campaignNFTModule[id], set by Web3Campaigns at first deposit -- see the header comment there
///   for why deposit, not root-set, is the pin trigger).
/// - This module only accepts recordERC721Deposit/recordERC1155Deposit from the one Web3Campaigns
///   address it was deployed with (immutable).
/// - setNFTMerkleRoot/claimNFT/withdrawUnclaimedERC721/withdrawUnclaimedERC1155 all self-verify via
///   getCampaignNFTModule(id) == address(this) before touching any local state -- defense-in-depth,
///   mirroring OnChainRewardModule.claimReward's self-check, so a module that is no longer a
///   campaign's authoritative one can never act on stale escrow bookkeeping.
contract NFTSettlementModule is INFTSettlementModule {
    address public immutable WEB3_CAMPAIGNS;

    error NFTSettlementModule__NotWeb3Campaigns();
    error NFTSettlementModule__NotCampaignHost();
    error NFTSettlementModule__NotAuthoritativeModule();

    mapping(uint256 => bytes32) internal _nftMerkleRoot; // campaignId => NFT settlement root
    mapping(uint256 => uint64) internal _nftRootSetAt; // campaignId => timestamp root was last (re-)published
    mapping(uint256 => mapping(bytes32 => bool)) internal _nftLeafClaimed; // campaignId => leaf => claimed
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) internal _escrowedERC721; // id => token => tokenId => held
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _escrowedERC1155; // id => token => tokenId => amount held

    event NFTMerkleRootSet(uint256 indexed campaignId, bytes32 merkleRoot);
    event NFTRewardClaimed(
        uint256 indexed campaignId,
        address indexed account,
        CampaignStorage.NFTStandard standard,
        address token,
        uint256 tokenId,
        uint256 amount
    );
    event UnclaimedNFTsWithdrawn(
        uint256 indexed campaignId, address indexed token, CampaignStorage.NFTStandard standard, uint256 count
    );

    constructor(address _web3Campaigns) {
        if (_web3Campaigns == address(0)) {
            revert NFTSettlementModule__NotWeb3Campaigns();
        }
        WEB3_CAMPAIGNS = _web3Campaigns;
    }

    modifier onlyWeb3Campaigns() {
        if (msg.sender != WEB3_CAMPAIGNS) {
            revert NFTSettlementModule__NotWeb3Campaigns();
        }
        _;
    }

    /// @dev Both self-checks a claim/root/sweep function needs before touching local state: this
    /// module must still be the campaign's pinned, authoritative one.
    function _requireAuthoritative(uint256 _campaignId) internal view {
        if (IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).getCampaignNFTModule(_campaignId) != address(this)) {
            revert NFTSettlementModule__NotAuthoritativeModule();
        }
    }

    function _requireHost(uint256 _campaignId) internal view returns (CampaignStorage.CampaignStatus status) {
        address host;
        (host, status) = IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).getCampaignHostAndStatus(_campaignId);
        if (msg.sender != host) {
            revert NFTSettlementModule__NotCampaignHost();
        }
    }

    /// @dev Mirrors CampaignManagement._requireSweepable's Cancelled-immediate / Closed+grace rule,
    /// via cross-contract reads since this module holds none of that state itself.
    function _requireSweepable(uint256 _campaignId) internal view {
        (, CampaignStorage.CampaignStatus status) =
            IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).getCampaignHostAndStatus(_campaignId);
        if (status == CampaignStorage.CampaignStatus.Cancelled) {
            return;
        }
        if (status != CampaignStorage.CampaignStatus.Closed) {
            revert CampaignStorage.Web3Campaigns__CampaignNotYetEnded();
        }
        uint64 closedAt = IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).getCampaignClosedAt(_campaignId);
        if (block.timestamp < closedAt + IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).CLAIM_GRACE_PERIOD()) {
            revert CampaignStorage.Web3Campaigns__GracePeriodActive();
        }
    }

    // --- Trusted bookkeeping callbacks (Web3Campaigns only, driven by its own custody receipts) ---

    /// @notice Record ERC721 tokenIds as escrowed for a campaign. Called by Web3Campaigns
    /// immediately after it pulls the tokens into its own custody via depositERC721Rewards.
    function recordERC721Deposit(uint256 _campaignId, address _token, uint256[] calldata _tokenIds)
        external
        onlyWeb3Campaigns
    {
        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
            _escrowedERC721[_campaignId][_token][_tokenIds[i]] = true;
        }
    }

    /// @notice Record ERC1155 balances as escrowed for a campaign. Called by Web3Campaigns
    /// immediately after it pulls the tokens into its own custody via depositERC1155Rewards.
    function recordERC1155Deposit(
        uint256 _campaignId,
        address _token,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) external onlyWeb3Campaigns {
        uint256 len = _ids.length;
        for (uint256 i; i < len; ++i) {
            _escrowedERC1155[_campaignId][_token][_ids[i]] += _amounts[i];
        }
    }

    // --- Host-facing settlement config ---

    /**
     * @notice Publish (or update) the NFT reward Merkle root for settlement.
     * @dev Only after the campaign has Ended. Leaf format:
     *      keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount)))).
     *      Updatable while Ended, frozen at Closed. Publishing a NEW root value rearms
     *      ROOT_DISPUTE_WINDOW (claimNFT rejects claims against it until the window elapses); a
     *      no-op republish of the byte-identical root does not rearm.
     */
    function setNFTMerkleRoot(uint256 _campaignId, bytes32 _merkleRoot) external {
        _requireAuthoritative(_campaignId);
        CampaignStorage.CampaignStatus status = _requireHost(_campaignId);
        if (status != CampaignStorage.CampaignStatus.Ended) {
            revert CampaignStorage.Web3Campaigns__CampaignNotYetEnded();
        }
        if (_merkleRoot == bytes32(0)) {
            revert CampaignStorage.Web3Campaigns__MerkleRootNotSet();
        }

        if (_nftMerkleRoot[_campaignId] != _merkleRoot) {
            _nftRootSetAt[_campaignId] = uint64(block.timestamp);
        }
        _nftMerkleRoot[_campaignId] = _merkleRoot;
        emit NFTMerkleRootSet(_campaignId, _merkleRoot);
    }

    // --- Participant claim ---

    /**
     * @notice Claim an NFT reward via post-campaign Merkle settlement.
     * @dev Allocations are computed off-chain and committed by the host (setNFTMerkleRoot). Leaf:
     *      keccak256(bytes.concat(keccak256(abi.encode(account, uint8(standard), token, tokenId, amount)))).
     *      Validated entirely here (proof, escrow, dispute window); the actual transfer is executed
     *      by Web3Campaigns via executeNFTTransferOut, since only it holds custody.
     */
    function claimNFT(
        uint256 _campaignId,
        CampaignStorage.NFTStandard _standard,
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        bytes32[] calldata _proof
    ) external {
        _claimNFT(_campaignId, msg.sender, _standard, _token, _tokenId, _amount, _proof);
    }

    /**
     * @notice Submit an NFT settlement claim ON BEHALF OF an allocated account (sponsored /
     *         gasless claim). The NFT is ALWAYS delivered to `_account` -- never to the caller.
     * @dev Deliberately permissionless, mirroring Web3Campaigns.claimERC20For: the Merkle proof
     *      only verifies against a leaf committing to `_account`, so a third-party caller can only
     *      deliver `_account`'s own allocation to `_account`'s own wallet. Lets the project backend
     *      pay gas for users with no meta-transaction framework. NOTE: if `_account` is a contract,
     *      ERC721/1155 safeTransferFrom's receiver check still applies -- a non-receiver contract
     *      reverts the claim, exactly as it would for a self-submitted one.
     */
    function claimNFTFor(
        uint256 _campaignId,
        address _account,
        CampaignStorage.NFTStandard _standard,
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        bytes32[] calldata _proof
    ) external {
        if (_account == address(0)) {
            revert CampaignStorage.Web3Campaigns__ZeroAddress();
        }
        _claimNFT(_campaignId, _account, _standard, _token, _tokenId, _amount, _proof);
    }

    /// @dev Shared claim body for claimNFT (account = msg.sender) and claimNFTFor (sponsored). All
    /// checks/effects/delivery run against `_account`.
    function _claimNFT(
        uint256 _campaignId,
        address _account,
        CampaignStorage.NFTStandard _standard,
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        bytes32[] calldata _proof
    ) internal {
        _requireAuthoritative(_campaignId);

        (, CampaignStorage.CampaignStatus status) =
            IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).getCampaignHostAndStatus(_campaignId);
        if (status != CampaignStorage.CampaignStatus.Ended && status != CampaignStorage.CampaignStatus.Closed) {
            revert CampaignStorage.Web3Campaigns__CampaignNotYetEnded();
        }

        bytes32 root = _nftMerkleRoot[_campaignId];
        if (root == bytes32(0)) {
            revert CampaignStorage.Web3Campaigns__MerkleRootNotSet();
        }
        // Dispute window: gives the community time to catch an unfair root before any NFTs move
        // against it. Rearmed only when the published root VALUE actually changes.
        uint256 claimableAt =
            _nftRootSetAt[_campaignId] + IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).ROOT_DISPUTE_WINDOW();
        if (block.timestamp < claimableAt) {
            revert CampaignStorage.Web3Campaigns__RootDisputeWindowActive(_campaignId, claimableAt);
        }

        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(_account, uint8(_standard), _token, _tokenId, _amount))));
        if (_nftLeafClaimed[_campaignId][leaf]) {
            revert CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement();
        }
        if (!MerkleProof.verify(_proof, root, leaf)) {
            revert CampaignStorage.Web3Campaigns__InvalidMerkleProof();
        }

        // Effects (CEI): mark the leaf claimed and decrement escrow before the cross-contract
        // transfer call.
        _nftLeafClaimed[_campaignId][leaf] = true;

        if (_standard == CampaignStorage.NFTStandard.ERC721) {
            if (!_escrowedERC721[_campaignId][_token][_tokenId]) {
                revert CampaignStorage.Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC721[_campaignId][_token][_tokenId] = false;
        } else {
            uint256 held = _escrowedERC1155[_campaignId][_token][_tokenId];
            if (_amount == 0 || _amount > held) {
                revert CampaignStorage.Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC1155[_campaignId][_token][_tokenId] = held - _amount;
        }

        IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS)
            .executeNFTTransferOut(_campaignId, _standard, _token, _tokenId, _amount, _account);

        emit NFTRewardClaimed(_campaignId, _account, _standard, _token, _tokenId, _amount);
    }

    // --- Host sweep of unclaimed NFTs ---

    /// @notice Reclaim still-escrowed ERC721 NFTs after the grace period (unclaimed by winners).
    function withdrawUnclaimedERC721(uint256 _campaignId, address _token, uint256[] calldata _tokenIds) external {
        _requireAuthoritative(_campaignId);
        _requireHost(_campaignId);
        _requireSweepable(_campaignId);

        uint256 len = _tokenIds.length;
        if (len == 0 || len > 100) {
            revert CampaignStorage.Web3Campaigns__BatchTooLarge();
        }

        for (uint256 i; i < len; ++i) {
            if (!_escrowedERC721[_campaignId][_token][_tokenIds[i]]) {
                revert CampaignStorage.Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC721[_campaignId][_token][_tokenIds[i]] = false;
        }

        emit UnclaimedNFTsWithdrawn(_campaignId, _token, CampaignStorage.NFTStandard.ERC721, len);

        for (uint256 i; i < len; ++i) {
            IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS)
                .executeNFTTransferOut(
                    _campaignId, CampaignStorage.NFTStandard.ERC721, _token, _tokenIds[i], 1, msg.sender
                );
        }
    }

    /// @notice Reclaim still-escrowed ERC1155 balances after the grace period.
    function withdrawUnclaimedERC1155(
        uint256 _campaignId,
        address _token,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) external {
        _requireAuthoritative(_campaignId);
        _requireHost(_campaignId);
        _requireSweepable(_campaignId);

        uint256 len = _ids.length;
        if (len == 0 || len > 100) {
            revert CampaignStorage.Web3Campaigns__BatchTooLarge();
        }
        if (_amounts.length != len) {
            revert CampaignStorage.Web3Campaigns__ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            uint256 held = _escrowedERC1155[_campaignId][_token][_ids[i]];
            if (_amounts[i] == 0 || _amounts[i] > held) {
                revert CampaignStorage.Web3Campaigns__NFTNotEscrowed();
            }
            _escrowedERC1155[_campaignId][_token][_ids[i]] = held - _amounts[i];
        }

        emit UnclaimedNFTsWithdrawn(_campaignId, _token, CampaignStorage.NFTStandard.ERC1155, len);

        for (uint256 i; i < len; ++i) {
            IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS)
                .executeNFTTransferOut(
                    _campaignId, CampaignStorage.NFTStandard.ERC1155, _token, _ids[i], _amounts[i], msg.sender
                );
        }
    }

    // --- Views ---

    function getNFTMerkleRoot(uint256 _campaignId) external view returns (bytes32) {
        return _nftMerkleRoot[_campaignId];
    }

    function getNFTClaimableAt(uint256 _campaignId) external view returns (uint256) {
        uint64 setAt = _nftRootSetAt[_campaignId];
        if (setAt == 0) {
            return 0;
        }
        return setAt + IWeb3CampaignsForNFTModule(WEB3_CAMPAIGNS).ROOT_DISPUTE_WINDOW();
    }

    function isNFTLeafClaimed(uint256 _campaignId, bytes32 _leaf) external view returns (bool) {
        return _nftLeafClaimed[_campaignId][_leaf];
    }

    function isERC721Escrowed(uint256 _campaignId, address _token, uint256 _tokenId) external view returns (bool) {
        return _escrowedERC721[_campaignId][_token][_tokenId];
    }

    function getERC1155Escrowed(uint256 _campaignId, address _token, uint256 _tokenId) external view returns (uint256) {
        return _escrowedERC1155[_campaignId][_token][_tokenId];
    }
}
