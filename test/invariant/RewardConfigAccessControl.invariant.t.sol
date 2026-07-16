// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721, MockERC1155} from "../NFTSettlement.t.sol";
import {RewardConfigAccessControlHandler} from "./RewardConfigAccessControlHandler.sol";

/// @notice Closes the access-control fuzzing gap noted in docs/NEXT_STEPS.md: every other
/// invariant suite fuzzes a single host (the handler itself), so per-campaign host-BINDING (as
/// opposed to mere HOST_ROLE possession) was never exercised end-to-end. Runs 3 distinct hosts,
/// each with its own campaigns, and repeatedly has each attempt configureERC20Reward/
/// depositERC721Rewards/depositERC1155Rewards on the OTHER hosts' campaigns.
contract RewardConfigAccessControlInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    MockERC721 public nft721;
    MockERC1155 public nft1155;
    RewardConfigAccessControlHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        nft721 = new MockERC721();
        nft1155 = new MockERC1155();
        handler = new RewardConfigAccessControlHandler(campaigns, token, nft721, nft1155);

        vm.startPrank(deployer);
        campaigns.grantHostRole(handler.hosts(0));
        campaigns.grantHostRole(handler.hosts(1));
        campaigns.grantHostRole(handler.hosts(2));
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RewardConfigAccessControlHandler.createCampaign.selector;
        selectors[1] = RewardConfigAccessControlHandler.configureERC20AsRealHost.selector;
        selectors[2] = RewardConfigAccessControlHandler.configureERC20AsAttacker.selector;
        selectors[3] = RewardConfigAccessControlHandler.depositERC721AsRealHost.selector;
        selectors[4] = RewardConfigAccessControlHandler.depositERC721AsAttacker.selector;
        selectors[5] = RewardConfigAccessControlHandler.depositERC1155AsRealHost.selector;
        selectors[6] = RewardConfigAccessControlHandler.depositERC1155AsAttacker.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The core property: no unauthorized configureERC20Reward/depositERC721Rewards/
    /// depositERC1155Rewards call has EVER succeeded, and every rejection was for the right reason
    /// (CallerIsNotHost). Enforced via assertEq inside this view invariant_* function -- which
    /// fails the run through forge-std's non-reverting failure mechanism -- rather than a revert
    /// inside the handler, which this project's fail_on_revert=false invariant profile would
    /// silently discard along with whatever ghost state it tried to record (see the handler's
    /// contract-level docs for the negative control that surfaced this).
    function invariant_UnauthorizedAttemptsNeverSucceed() public view {
        assertEq(handler.ghost_unauthorizedBypasses(), 0, "an unauthorized config/deposit call succeeded");
        assertEq(handler.ghost_wrongRevertReason(), 0, "an unauthorized attempt reverted for the wrong reason");
    }

    /// @notice Cross-check against LIVE contract state, independent of the handler's own
    /// bookkeeping: every campaign's actually-stored ERC20 reward token matches the value its real
    /// host last set (or is unset if the host never successfully configured it). If an attacker's
    /// call had silently mutated a campaign it doesn't own, this would diverge even if the
    /// handler's own ghost counters were (hypothetically) wrong.
    function invariant_ConfiguredTokenMatchesLegitimateHostOnly() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.campaignAt(i);
            (address actualToken,,,,,) = campaigns.getERC20Settlement(id);
            assertEq(actualToken, handler.expectedERC20Token(id), "campaign's reward token was mutated by a non-host");
        }
    }
}
