// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";

/// @notice Stateful-fuzz handler adversarially attacking the signed-attestation replay guard on a
///         single (participant, campaign, task) triple: attempts stale-version replays, version
///         skip-aheads, and non-signer signatures interleaved with legitimate next-version
///         attestations, and tracks a ghost "expected version" that should track the on-chain
///         counter exactly regardless of how many invalid attempts are interleaved.
///
/// The four attacker functions below do NOT revert on the unexpected-success branch (they used to,
/// via `revert("...")` -- removed after a negative control proved that pattern doesn't work: any
/// revert from a handler call is silently discarded under this project's `fail_on_revert = false`
/// profile, which unwinds EVERYTHING done in that same call, including the exploited contract's own
/// state mutation, not just a ghost-counter write meant to flag it. Concretely: with the loud
/// revert, disabling the contract's `hasRole(SIGNER_ROLE, signer)` check produced ZERO failures on
/// this suite, even though `invariant_versionMatchesGhostModel`/
/// `invariant_completionMatchesLastAcceptedAttestation` are independent live-state cross-checks that
/// don't reference these attacker functions' own bookkeeping at all -- because the bypassed call's
/// on-chain mutation never survived to be observed. See docs/SECURITY_FINDINGS.md. Now: the call is
/// simply left to return normally on unexpected success, so the mutation persists and the two
/// pre-existing invariants above catch the divergence on their own; `ghost_unexpectedAcceptances` is
/// an explicit, redundant-but-clearer counter for the same thing.
///
/// `attestReplayStaleVersion`/`attestSkipAheadVersion` are structurally unable to succeed regardless
/// of this fix: `verifyTaskCompletionWithSignature` takes no caller-supplied version at all -- the
/// contract always computes `nextVersion = current + 1` itself and embeds THAT in the digest it
/// recomputes, so a signature built for any other version can never recover to a valid signer. They
/// are kept (converted to the same non-reverting shape for consistency) as a regression check
/// against a hypothetical future refactor that accepted an explicit version parameter, not because
/// they currently exercise a reachable bypass.
contract AttestationVersionHandler is Test {
    Web3Campaigns public campaigns;
    address public participant = address(0xFEED);
    uint256 public campaignId;

    uint256 constant SIGNER_PK = 1; // deployer, holds SIGNER_ROLE by default
    uint256 constant NON_SIGNER_PK = 999; // never granted SIGNER_ROLE

    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant TASK_ATTESTATION_TYPEHASH = keccak256(
        "TaskAttestation(uint256 campaignId,address participant,uint256 taskIndex,bool completed,uint256 version,uint256 deadline)"
    );

    uint256 public ghost_expectedVersion;
    bool public ghost_lastCompleted;
    uint256 public ghost_acceptedCount;
    uint256 public ghost_rejectedCount;
    uint256 public ghost_unexpectedAcceptances; // must stay 0 -- a nonzero value is a live security bug

    constructor(Web3Campaigns _campaigns, uint256 _campaignId) {
        campaigns = _campaigns;
        campaignId = _campaignId;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Web3Campaigns")),
                keccak256(bytes("1")),
                block.chainid,
                address(campaigns)
            )
        );
    }

    function _sign(uint256 pk, bool completed, uint256 version, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(TASK_ATTESTATION_TYPEHASH, campaignId, participant, uint256(0), completed, version, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Legitimate attestation targeting exactly the correct next version. Must always succeed.
    function attestCorrectVersion(bool completed) external {
        uint256 nextVersion = ghost_expectedVersion + 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(SIGNER_PK, completed, nextVersion, deadline);

        campaigns.verifyTaskCompletionWithSignature(campaignId, participant, 0, completed, deadline, sig);

        ghost_expectedVersion = nextVersion;
        ghost_lastCompleted = completed;
        ghost_acceptedCount++;
    }

    /// @dev Attempts to replay a stale (already-consumed or never-valid-yet) version. Must always
    /// revert — the on-chain version has already moved past it (or, at version 0, there is no valid
    /// "version 0" attestation since the contract always requires current+1).
    function attestReplayStaleVersion(bool completed, uint256 staleOffsetSeed) external {
        uint256 staleVersion = bound(staleOffsetSeed, 0, ghost_expectedVersion); // <= current, never == next
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(SIGNER_PK, completed, staleVersion, deadline);

        try campaigns.verifyTaskCompletionWithSignature(campaignId, participant, 0, completed, deadline, sig) {
            ghost_unexpectedAcceptances++;
        } catch {
            ghost_rejectedCount++;
        }
    }

    /// @dev Attempts to skip ahead past the required next version. Must always revert.
    function attestSkipAheadVersion(bool completed, uint256 skipSeed) external {
        uint256 futureVersion = ghost_expectedVersion + 2 + bound(skipSeed, 0, 50);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(SIGNER_PK, completed, futureVersion, deadline);

        try campaigns.verifyTaskCompletionWithSignature(campaignId, participant, 0, completed, deadline, sig) {
            ghost_unexpectedAcceptances++;
        } catch {
            ghost_rejectedCount++;
        }
    }

    /// @dev Correct version, correct EIP-712 encoding, but signed by a key that never held
    /// SIGNER_ROLE. Must always revert regardless of version correctness.
    function attestNonSigner(bool completed) external {
        uint256 nextVersion = ghost_expectedVersion + 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(NON_SIGNER_PK, completed, nextVersion, deadline);

        try campaigns.verifyTaskCompletionWithSignature(campaignId, participant, 0, completed, deadline, sig) {
            ghost_unexpectedAcceptances++;
        } catch {
            ghost_rejectedCount++;
        }
    }

    /// @dev Correct version and signer, but an already-expired deadline. Must always revert on
    /// expiry before signature recovery is even relevant.
    function attestExpiredDeadline(bool completed, uint256 pastSeed) external {
        uint256 nextVersion = ghost_expectedVersion + 1;
        uint256 deadline = bound(pastSeed, 0, block.timestamp > 0 ? block.timestamp - 1 : 0);
        bytes memory sig = _sign(SIGNER_PK, completed, nextVersion, deadline);

        try campaigns.verifyTaskCompletionWithSignature(campaignId, participant, 0, completed, deadline, sig) {
            ghost_unexpectedAcceptances++;
        } catch {
            ghost_rejectedCount++;
        }
    }
}
