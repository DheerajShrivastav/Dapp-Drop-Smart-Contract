// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721, MockERC1155} from "../NFTSettlement.t.sol";

/// @notice Stateful-fuzz handler for the reward-configuration access-control gap flagged in
/// docs/NEXT_STEPS.md: prior invariant suites all fuzz a SINGLE host (the handler itself), so
/// per-campaign host-binding (as opposed to mere HOST_ROLE possession) was never exercised. This
/// handler runs 3 distinct hosts, each owning its own set of campaigns, and repeatedly has each
/// host attempt configureERC20Reward/depositERC721Rewards/depositERC1155Rewards on the OTHER
/// hosts' campaigns -- calls that must always revert CallerIsNotHost, regardless of campaign
/// status or token/NFT ownership (onlyHost's campaign.host == msg.sender check runs before any of
/// that internal logic).
///
/// Unauthorized attempts are checked via try/catch -- but, notably, WITHOUT reverting on the
/// unexpected-success branch. This project's other handlers use a "loud revert" there (see
/// AttestationVersionHandler/RootDisputeWindowHandler), reasoning that it beats a bare
/// vm.expectRevert. Empirically (verified with a negative control while building this suite:
/// disable Web3Campaigns' onlyHost host-check, rerun), that reasoning doesn't hold under this
/// project's `fail_on_revert = false` invariant profile: ANY revert from a handler call --
/// including a deliberate one -- is silently discarded by the fuzzer, and everything written
/// during that same call (the ghost-counter increment included) is rolled back with it, so the
/// ghost variable a "loud revert" pattern relies on to signal the bug never actually persists.
/// The fix here is to not revert at all: a bypass is recorded in a ghost counter and the call is
/// left to return normally, so the increment survives and `invariant_UnauthorizedAttemptsNeverSucceed`
/// (an assertEq inside a view invariant_* function, which fails via forge-std's non-reverting
/// failure mechanism, not a revert) genuinely fails the run. See docs/SECURITY_FINDINGS.md for the
/// same finding written up against the pre-existing suites, which were left as-is (out of scope
/// for this pass) but should be corrected the same way in a follow-up.
contract RewardConfigAccessControlHandler is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    MockERC721 public nft721;
    MockERC1155 public nft1155;

    address[3] public hosts;
    uint256 internal nextTokenId = 1;

    uint256[] public campaignIds;
    mapping(uint256 => address) public hostOf;
    mapping(uint256 => address) public expectedERC20Token; // last value the REAL host set (0 = unset)

    // --- ghost accounting ---
    uint256 public ghost_authorizedConfigSuccesses;
    uint256 public ghost_authorizedDepositSuccesses;
    uint256 public ghost_unauthorizedAttemptsBlocked;
    uint256 public ghost_unauthorizedBypasses; // must stay 0 -- a nonzero value is a live security bug
    uint256 public ghost_wrongRevertReason; // must stay 0 -- reverted, but not with CallerIsNotHost

    constructor(Web3Campaigns _campaigns, ERC20Mock _token, MockERC721 _nft721, MockERC1155 _nft1155) {
        campaigns = _campaigns;
        token = _token;
        nft721 = _nft721;
        nft1155 = _nft1155;
        hosts[0] = address(0x40057); // "HOST1"-ish, arbitrary distinct addresses
        hosts[1] = address(0x40057 + 1);
        hosts[2] = address(0x40057 + 2);
    }

    function _host(uint256 seed) internal view returns (address) {
        return hosts[bound(seed, 0, 2)];
    }

    /// @dev An address that is NOT the real host of `_campaignId` -- either one of the other two
    /// legitimate hosts (host-of-a-different-campaign, the stronger cross-campaign check) or a
    /// totally unprivileged address, picked by `_kindSeed`.
    function _attackerFor(uint256 _campaignId, uint256 _kindSeed) internal view returns (address attacker) {
        address realHost = hostOf[_campaignId];
        if (_kindSeed % 2 == 0) {
            // A legitimate host, but not of THIS campaign.
            for (uint256 i; i < 3; ++i) {
                if (hosts[i] != realHost) return hosts[i];
            }
        }
        return address(uint160(uint256(keccak256(abi.encode("attacker", _campaignId, _kindSeed)))));
    }

    // --- actions ---

    function createCampaign(uint256 hostSeed, uint256 durSeed) external {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        address host = _host(hostSeed);

        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        vm.prank(host);
        uint256 id = campaigns.createCampaign("C", startTime, endTime);

        hostOf[id] = host;
        campaignIds.push(id);
    }

    /// @dev The campaign's REAL host configures its ERC20 reward token -- must succeed (Draft-only,
    /// no other guard), and updates the ghost value the invariant cross-checks against.
    function configureERC20AsRealHost(uint256 cSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address host = hostOf[id];

        vm.prank(host);
        try campaigns.configureERC20Reward(id, address(token)) {
            expectedERC20Token[id] = address(token);
            ghost_authorizedConfigSuccesses++;
        } catch {
            // Draft-only: a campaign already moved past Draft correctly rejects even its own host.
        }
    }

    /// @dev A non-host attempts to configure someone ELSE's campaign's reward token. Must ALWAYS
    /// revert CallerIsNotHost, regardless of campaign status -- onlyHost fires before any status
    /// check. Records the outcome in a ghost counter rather than reverting on the unexpected-
    /// success branch (see the contract-level docs above for why: a revert here would be silently
    /// discarded under fail_on_revert=false, along with the ghost write meant to signal it).
    function configureERC20AsAttacker(uint256 cSeed, uint256 kindSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address attacker = _attackerFor(id, kindSeed);

        vm.prank(attacker);
        try campaigns.configureERC20Reward(id, address(token)) {
            ghost_unauthorizedBypasses++;
        } catch (bytes memory reason) {
            if (bytes4(reason) != CampaignStorage.Web3Campaigns__CallerIsNotHost.selector) {
                ghost_wrongRevertReason++;
            } else {
                ghost_unauthorizedAttemptsBlocked++;
            }
        }
    }

    /// @dev The REAL host deposits a freshly-minted ERC721 into its own campaign -- must succeed.
    function depositERC721AsRealHost(uint256 cSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address host = hostOf[id];

        uint256 tokenId = nextTokenId++;
        nft721.mint(host, tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.startPrank(host);
        nft721.setApprovalForAll(address(campaigns), true);
        try campaigns.depositERC721Rewards(id, address(nft721), ids) {
            ghost_authorizedDepositSuccesses++;
        } catch {
            // Campaign moved past the funding-eligible statuses -- correctly rejects its own host too.
        }
        vm.stopPrank();
    }

    /// @dev A non-host attempts to deposit into someone ELSE's campaign. Must ALWAYS revert
    /// CallerIsNotHost -- onlyHost fires before the transfer is ever attempted, so this holds
    /// regardless of whether the attacker even owns an NFT to deposit.
    function depositERC721AsAttacker(uint256 cSeed, uint256 kindSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address attacker = _attackerFor(id, kindSeed);

        uint256[] memory ids = new uint256[](1);
        ids[0] = nextTokenId++; // attacker owns nothing here -- irrelevant, onlyHost fires first

        vm.prank(attacker);
        try campaigns.depositERC721Rewards(id, address(nft721), ids) {
            ghost_unauthorizedBypasses++;
        } catch (bytes memory reason) {
            if (bytes4(reason) != CampaignStorage.Web3Campaigns__CallerIsNotHost.selector) {
                ghost_wrongRevertReason++;
            } else {
                ghost_unauthorizedAttemptsBlocked++;
            }
        }
    }

    /// @dev The REAL host deposits freshly-minted ERC1155 units into its own campaign.
    function depositERC1155AsRealHost(uint256 cSeed, uint256 amountSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address host = hostOf[id];

        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 assetId = nextTokenId++;
        nft1155.mint(host, assetId, amount);
        uint256[] memory ids = new uint256[](1);
        ids[0] = assetId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.startPrank(host);
        nft1155.setApprovalForAll(address(campaigns), true);
        try campaigns.depositERC1155Rewards(id, address(nft1155), ids, amounts) {
            ghost_authorizedDepositSuccesses++;
        } catch {
            // Campaign moved past the funding-eligible statuses -- correctly rejects its own host too.
        }
        vm.stopPrank();
    }

    /// @dev A non-host attempts to deposit ERC1155 into someone ELSE's campaign -- same guarantee
    /// as the ERC721 attacker action above.
    function depositERC1155AsAttacker(uint256 cSeed, uint256 kindSeed, uint256 amountSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(cSeed, 0, campaignIds.length - 1)];
        address attacker = _attackerFor(id, kindSeed);

        uint256[] memory ids = new uint256[](1);
        ids[0] = nextTokenId++;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = bound(amountSeed, 1, 1e24);

        vm.prank(attacker);
        try campaigns.depositERC1155Rewards(id, address(nft1155), ids, amounts) {
            ghost_unauthorizedBypasses++;
        } catch (bytes memory reason) {
            if (bytes4(reason) != CampaignStorage.Web3Campaigns__CallerIsNotHost.selector) {
                ghost_wrongRevertReason++;
            } else {
                ghost_unauthorizedAttemptsBlocked++;
            }
        }
    }

    // --- views for the invariant contract ---
    function campaignCount() external view returns (uint256) {
        return campaignIds.length;
    }

    function campaignAt(uint256 i) external view returns (uint256) {
        return campaignIds[i];
    }
}
