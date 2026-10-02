// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";

/// @notice Submits a SIGNER_ROLE-signed EIP-712 TaskAttestation -- the only way a non-hold task
/// can be completed (completeTask self-verifies ONCHAIN_HOLD_* only).
abstract contract AttestationHelper is Test {
    function _attestTask(
        Web3Campaigns target,
        uint256 signerPk,
        uint256 campaignId,
        address participant,
        uint256 taskIndex,
        bool completed
    ) internal {
        uint256 version = target.getTaskAttestationVersion(campaignId, participant, taskIndex) + 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                target.TASK_ATTESTATION_TYPEHASH(), campaignId, participant, taskIndex, completed, version, deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Web3Campaigns")),
                keccak256(bytes("1")),
                block.chainid,
                address(target)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        target.verifyTaskCompletionWithSignature(
            campaignId, participant, taskIndex, completed, deadline, abi.encodePacked(r, s, v)
        );
    }
}
