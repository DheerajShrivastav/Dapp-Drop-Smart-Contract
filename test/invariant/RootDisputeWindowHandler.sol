// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721} from "../NFTSettlement.t.sol";

/// @notice Stateful-fuzz handler adversarially hammering the Merkle root dispute window
/// (ROOT_DISPUTE_WINDOW) for both the ERC20 and NFT claim paths, across many campaigns with
/// randomized publish / same-root-republish / different-root-republish timing.
///
/// Each campaign uses a single-leaf tree (one fixed participant), so root == leaf and proofs are
/// always empty -- the interesting surface here is TIMING, not Merkle mechanics (already covered by
/// EscrowSolvency/NFTInventory). A ghost mirror (erc20ExpectedClaimableAt/nftExpectedClaimableAt)
/// independently reconstructs the exact rearm rule (rearm only on a genuine root-VALUE change) and
/// is cross-checked against the live contract's own getERC20ClaimableAt/getNFTClaimableAt in the
/// invariant contract.
///
/// attemptERC20Claim/attemptNFTClaim predict, from the ghost, whether a claim MUST succeed or MUST
/// revert RootDisputeWindowActive, and assert the actual outcome matches via try/catch with a loud
/// revert on the wrong branch -- fail_on_revert=false would otherwise silently discard a violation
/// in EITHER direction (a should-succeed claim wrongly reverting is just as invisible as a
/// should-revert claim wrongly succeeding), so both are checked explicitly rather than relying on
/// ghost-vs-reality accounting alone (see TEST_AND_BUILD.md Known Issues re: vm.expectRevert
/// fragility -- try/catch with a loud revert on the unexpected branch is this project's established
/// pattern, from AttestationVersionHandler).
contract RootDisputeWindowHandler is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    MockERC721 public nft721;

    address public participant = address(0xF00D);
    uint256 internal nextTokenId = 1;

    uint256[] public erc20Campaigns;
    uint256[] public nftCampaigns;

    mapping(uint256 => uint256) public erc20FundedAmount; // escrow ceiling, fixed at creation
    mapping(uint256 => uint256) public erc20CurrentAmount; // amount encoded in the currently-live root
    mapping(uint256 => bytes32) public erc20LastRoot; // ghost: last actually-published root value
    mapping(uint256 => uint256) public erc20ExpectedClaimableAt; // ghost mirror of the rearm rule
    mapping(uint256 => bool) public erc20Claimed;

    mapping(uint256 => uint256) public nftTokenIdOf;
    mapping(uint256 => bytes32) public nftLastRoot;
    mapping(uint256 => uint256) public nftExpectedClaimableAt;
    mapping(uint256 => bool) public nftClaimed;

    uint256 public ghost_erc20SuccessCount;
    uint256 public ghost_erc20RevertCount;
    uint256 public ghost_nftSuccessCount;
    uint256 public ghost_nftRevertCount;

    constructor(Web3Campaigns _campaigns, ERC20Mock _token, MockERC721 _nft721) {
        campaigns = _campaigns;
        token = _token;
        nft721 = _nft721;
    }

    function _erc20Leaf(uint256 amt) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(participant, amt))));
    }

    function _nftLeaf(uint256 tokenId) internal view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        participant, uint8(CampaignStorage.NFTStandard.ERC721), address(nft721), tokenId, uint256(1)
                    )
                )
            )
        );
    }

    // --- ERC20 path ---

    function createERC20Campaign(uint256 fundAmountSeed, uint256 durSeed) external {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));

        uint256 fundAmount = bound(fundAmountSeed, 1, 1e24);
        token.mint(address(this), fundAmount);
        token.approve(address(campaigns), fundAmount);
        campaigns.fundCampaignERC20(id, fundAmount);

        vm.warp(startTime + 1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        erc20FundedAmount[id] = fundAmount;
        erc20Campaigns.push(id);
    }

    /// @dev Publish a root. `sameValue` forces an exact republish of the current amount (once one
    /// exists); otherwise picks a fresh amount within the funded ceiling, which may or may not
    /// coincidentally match the current one -- either way the ghost mirror below stays correct,
    /// since it compares actual root BYTES, not intent.
    function publishERC20Root(uint256 campaignSeed, bool sameValue, uint256 newAmountSeed) external {
        if (erc20Campaigns.length == 0) return;
        uint256 id = erc20Campaigns[bound(campaignSeed, 0, erc20Campaigns.length - 1)];
        if (erc20Claimed[id]) return; // don't mutate the root out from under an already-settled claim

        uint256 amt;
        if (sameValue && erc20LastRoot[id] != bytes32(0)) {
            amt = erc20CurrentAmount[id];
        } else {
            amt = bound(newAmountSeed, 1, erc20FundedAmount[id]);
        }
        bytes32 root = _erc20Leaf(amt);
        campaigns.setERC20MerkleRoot(id, root);
        erc20CurrentAmount[id] = amt;

        if (root != erc20LastRoot[id]) {
            erc20ExpectedClaimableAt[id] = block.timestamp + campaigns.ROOT_DISPUTE_WINDOW();
            erc20LastRoot[id] = root;
        }
    }

    function attemptERC20Claim(uint256 campaignSeed) external {
        if (erc20Campaigns.length == 0) return;
        uint256 id = erc20Campaigns[bound(campaignSeed, 0, erc20Campaigns.length - 1)];
        if (erc20Claimed[id] || erc20LastRoot[id] == bytes32(0)) return;

        uint256 amt = erc20CurrentAmount[id];
        bytes32[] memory proof = new bytes32[](0);
        bool shouldSucceed = block.timestamp >= erc20ExpectedClaimableAt[id];

        if (shouldSucceed) {
            vm.prank(participant);
            try campaigns.claimERC20(id, amt, proof) {
                erc20Claimed[id] = true;
                ghost_erc20SuccessCount++;
            } catch {
                revert("attemptERC20Claim: expected success but reverted at/after claimableAt");
            }
        } else {
            vm.prank(participant);
            try campaigns.claimERC20(id, amt, proof) {
                revert("attemptERC20Claim: expected RootDisputeWindowActive but succeeded before claimableAt");
            } catch (bytes memory reason) {
                if (bytes4(reason) != CampaignStorage.Web3Campaigns__RootDisputeWindowActive.selector) {
                    revert("attemptERC20Claim: reverted for the wrong reason before claimableAt");
                }
                ghost_erc20RevertCount++;
            }
        }
    }

    // --- NFT (ERC721) path -- same mechanism, mirrors the ERC20 actions above ---

    function createNFTCampaign(uint256 durSeed) external {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        uint256 tokenId = nextTokenId++;
        nft721.mint(address(this), tokenId);
        nft721.approve(address(campaigns), tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        campaigns.depositERC721Rewards(id, address(nft721), ids);

        vm.warp(startTime + 1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        nftTokenIdOf[id] = tokenId;
        nftCampaigns.push(id);
    }

    /// @dev A campaign escrows exactly one tokenId, so there is only ever one valid leaf -- every
    /// publish here is necessarily a same-value republish after the first, which must NOT rearm.
    /// (publishERC20Root above covers the different-value-rearms case.)
    function publishNFTRoot(uint256 campaignSeed) external {
        if (nftCampaigns.length == 0) return;
        uint256 id = nftCampaigns[bound(campaignSeed, 0, nftCampaigns.length - 1)];
        if (nftClaimed[id]) return;

        bytes32 root = _nftLeaf(nftTokenIdOf[id]);
        campaigns.setNFTMerkleRoot(id, root);

        if (root != nftLastRoot[id]) {
            nftExpectedClaimableAt[id] = block.timestamp + campaigns.ROOT_DISPUTE_WINDOW();
            nftLastRoot[id] = root;
        }
    }

    function attemptNFTClaim(uint256 campaignSeed) external {
        if (nftCampaigns.length == 0) return;
        uint256 id = nftCampaigns[bound(campaignSeed, 0, nftCampaigns.length - 1)];
        if (nftClaimed[id] || nftLastRoot[id] == bytes32(0)) return;

        uint256 tokenId = nftTokenIdOf[id];
        bytes32[] memory proof = new bytes32[](0);
        bool shouldSucceed = block.timestamp >= nftExpectedClaimableAt[id];

        if (shouldSucceed) {
            vm.prank(participant);
            try campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), tokenId, 1, proof) {
                nftClaimed[id] = true;
                ghost_nftSuccessCount++;
            } catch {
                revert("attemptNFTClaim: expected success but reverted at/after claimableAt");
            }
        } else {
            vm.prank(participant);
            try campaigns.claimNFT(id, CampaignStorage.NFTStandard.ERC721, address(nft721), tokenId, 1, proof) {
                revert("attemptNFTClaim: expected RootDisputeWindowActive but succeeded before claimableAt");
            } catch (bytes memory reason) {
                if (bytes4(reason) != CampaignStorage.Web3Campaigns__RootDisputeWindowActive.selector) {
                    revert("attemptNFTClaim: reverted for the wrong reason before claimableAt");
                }
                ghost_nftRevertCount++;
            }
        }
    }

    /// @dev Explicit time-advance lever so the fuzzer can deliberately push past
    /// ROOT_DISPUTE_WINDOW, mirroring the large warps EscrowSolvencyHandler.sweep /
    /// NFTInventoryHandler.sweep* perform for their own grace periods. Without this, most calls
    /// would land well inside the window (campaign creation only warps by RATE_LIMIT_COOLDOWN plus
    /// the campaign's own duration), starving the "claim succeeds" branch of coverage.
    function warpForward(uint256 seed) external {
        uint256 delta = bound(seed, 1, 2 * campaigns.ROOT_DISPUTE_WINDOW());
        vm.warp(block.timestamp + delta);
    }

    // --- views for the invariant contract ---
    function erc20Count() external view returns (uint256) {
        return erc20Campaigns.length;
    }

    function erc20At(uint256 i) external view returns (uint256) {
        return erc20Campaigns[i];
    }

    function nftCount() external view returns (uint256) {
        return nftCampaigns.length;
    }

    function nftAt(uint256 i) external view returns (uint256) {
        return nftCampaigns[i];
    }
}
