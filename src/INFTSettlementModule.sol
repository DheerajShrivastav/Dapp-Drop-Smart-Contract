// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice The slice of NFTSettlementModule's surface Web3Campaigns needs: trusted bookkeeping
/// callbacks invoked immediately after Web3Campaigns pulls NFTs into its own custody. The module
/// exposes the full participant/host-facing settlement surface (setNFTMerkleRoot, claimNFT,
/// withdrawUnclaimedERC721/1155) directly, called by users, not through Web3Campaigns -- see
/// NFTSettlementModule.sol.
interface INFTSettlementModule {
    /// @notice Record ERC721 tokenIds as escrowed for a campaign. Called immediately after
    /// Web3Campaigns pulls them into custody via depositERC721Rewards.
    function recordERC721Deposit(uint256 campaignId, address token, uint256[] calldata tokenIds) external;

    /// @notice Record ERC1155 balances as escrowed for a campaign. Called immediately after
    /// Web3Campaigns pulls them into custody via depositERC1155Rewards.
    function recordERC1155Deposit(uint256 campaignId, address token, uint256[] calldata ids, uint256[] calldata amounts)
        external;

    /// @notice The currently published NFT settlement root for a campaign, or bytes32(0) if none
    /// has ever been published. Used by cancelCampaign to refuse cancelling a campaign that has
    /// already committed to an NFT settlement -- see that function's docstring.
    function getNFTMerkleRoot(uint256 campaignId) external view returns (bytes32);
}
