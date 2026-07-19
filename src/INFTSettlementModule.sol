// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice The slice of NFTSettlementModule's surface Web3Campaigns needs: trusted bookkeeping
/// callbacks invoked immediately after Web3Campaigns pulls NFTs into its own custody. The module
/// exposes the full participant/host-facing settlement surface (setNFTMerkleRoot, claimNFT,
/// withdrawUnclaimedERC721/1155) directly, called by users, not through Web3Campaigns -- see
/// NFTSettlementModule.sol.
interface INFTSettlementModule {
    /// @notice Record ERC721 tokenIds as escrowed for a campaign. Called immediately after
    /// Web3Campaigns pulls them into custody via depositERC721Rewards. `endTime` is passed (not
    /// queried back cross-contract) so the module can cache it for its own settler-fallback delay
    /// check -- campaign endTime is immutable once set, so caching at first deposit is always
    /// correct, and this avoids Web3Campaigns needing to expose a dedicated endTime getter.
    function recordERC721Deposit(uint256 campaignId, address token, uint256[] calldata tokenIds, uint256 endTime)
        external;

    /// @notice Record ERC1155 balances as escrowed for a campaign. Called immediately after
    /// Web3Campaigns pulls them into custody via depositERC1155Rewards. See recordERC721Deposit for
    /// why `endTime` is passed here rather than fetched separately.
    function recordERC1155Deposit(
        uint256 campaignId,
        address token,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        uint256 endTime
    ) external;

    /// @notice The currently published NFT settlement root for a campaign, or bytes32(0) if none
    /// has ever been published. Used by cancelCampaign to refuse cancelling a campaign that has
    /// already committed to an NFT settlement -- see that function's docstring.
    function getNFTMerkleRoot(uint256 campaignId) external view returns (bytes32);
}
