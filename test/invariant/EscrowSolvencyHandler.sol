// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Stateful-fuzz handler that drives the full ERC20 escrow + Merkle settlement lifecycle
///         across MANY campaigns sharing one reward token, so invariant tests can check that the
///         contract stays solvent no matter the interleaving of fund / claim / sweep.
///
/// Design: each campaign allocates to a fixed 4-participant set via a balanced 4-leaf Merkle tree
/// (the same OZ StandardMerkleTree + sorted-pair convention the contract verifies). Allocations are
/// capped at fundAmount/4 so every allocation is individually claimable (sum <= escrow) — this keeps
/// claims non-vacuous (real tokens actually move) rather than bouncing off InsufficientEscrow.
///
/// Ghost variables track every token flow; the invariant contract asserts global accounting and
/// per-campaign backing against them. Reverting handler calls are discarded (foundry
/// `fail_on_revert = false`), so a call that reverts leaves ghosts untouched and consistent.
contract EscrowSolvencyHandler is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;

    address[4] public participants;

    uint256[] public settled; // campaignIds that have a published root
    mapping(uint256 => uint256[4]) public allocations;
    mapping(uint256 => mapping(uint256 => bool)) public claimed; // campaignId => pIdx => claimed
    mapping(uint256 => bool) public swept;

    // --- ghost accounting ---
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_totalSwept;

    constructor(Web3Campaigns _campaigns, ERC20Mock _token) {
        campaigns = _campaigns;
        token = _token;
        participants[0] = address(0xA11CE);
        participants[1] = address(0xB0B01);
        participants[2] = address(0xC0FFEE);
        participants[3] = address(0xD00D);
    }

    // --- Merkle helpers (balanced 4-leaf tree, commutative pair hashing) ---
    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hp(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _leaves(uint256 id) internal view returns (bytes32 l0, bytes32 l1, bytes32 l2, bytes32 l3) {
        uint256[4] memory a = allocations[id];
        l0 = _leaf(participants[0], a[0]);
        l1 = _leaf(participants[1], a[1]);
        l2 = _leaf(participants[2], a[2]);
        l3 = _leaf(participants[3], a[3]);
    }

    function _root(uint256 id) internal view returns (bytes32) {
        (bytes32 l0, bytes32 l1, bytes32 l2, bytes32 l3) = _leaves(id);
        return _hp(_hp(l0, l1), _hp(l2, l3));
    }

    function _proof(uint256 id, uint256 idx) internal view returns (bytes32[] memory p) {
        (bytes32 l0, bytes32 l1, bytes32 l2, bytes32 l3) = _leaves(id);
        p = new bytes32[](2);
        if (idx == 0) {
            p[0] = l1;
            p[1] = _hp(l2, l3);
        } else if (idx == 1) {
            p[0] = l0;
            p[1] = _hp(l2, l3);
        } else if (idx == 2) {
            p[0] = l3;
            p[1] = _hp(l0, l1);
        } else {
            p[0] = l2;
            p[1] = _hp(l0, l1);
        }
    }

    // --- actions ---

    /// @dev Create a campaign, escrow `fundAmount`, publish a settlement root over the 4 participants.
    function createFundAndSettle(uint256 fundAmount, uint256 s0, uint256 s1, uint256 s2, uint256 s3, uint256 durSeed)
        external
    {
        // Sidestep createCampaign's per-host rate limit (5 min cooldown).
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);

        fundAmount = bound(fundAmount, 4, 1e30);
        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));
        token.mint(address(this), fundAmount);
        token.approve(address(campaigns), fundAmount);
        campaigns.fundCampaignERC20(id, fundAmount);
        ghost_totalFunded += fundAmount;

        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        uint256 cap = fundAmount / 4; // sum of 4 allocations <= fundAmount
        allocations[id] = [bound(s0, 0, cap), bound(s1, 0, cap), bound(s2, 0, cap), bound(s3, 0, cap)];

        campaigns.setERC20MerkleRoot(id, _root(id));
        settled.push(id);
    }

    /// @dev A participant claims its allocation for a settled campaign.
    function claim(uint256 cSeed, uint256 pSeed) external {
        if (settled.length == 0) return;
        uint256 id = settled[bound(cSeed, 0, settled.length - 1)];
        uint256 idx = bound(pSeed, 0, 3);
        if (claimed[id][idx]) return;

        uint256 amt = allocations[id][idx];
        bytes32[] memory pr = _proof(id, idx);

        vm.prank(participants[idx]);
        campaigns.claimERC20(id, amt, pr); // a revert here discards the whole call, ghosts untouched

        claimed[id][idx] = true;
        ghost_totalClaimed += amt;
    }

    /// @dev Close a settled campaign and, after the grace period, sweep unclaimed escrow to the host.
    function sweep(uint256 cSeed) external {
        if (settled.length == 0) return;
        uint256 id = settled[bound(cSeed, 0, settled.length - 1)];
        if (swept[id]) return;

        campaigns.closeCampaign(id);
        vm.warp(block.timestamp + campaigns.CLAIM_GRACE_PERIOD() + 1);

        (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(id);
        uint256 remaining = escrowed - distributed;

        campaigns.withdrawUnclaimedERC20(id);

        swept[id] = true;
        ghost_totalSwept += remaining;
    }

    // --- views for the invariant contract ---
    function settledCount() external view returns (uint256) {
        return settled.length;
    }

    function settledAt(uint256 i) external view returns (uint256) {
        return settled[i];
    }

    function isSwept(uint256 id) external view returns (bool) {
        return swept[id];
    }
}
