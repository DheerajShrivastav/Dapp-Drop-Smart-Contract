// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {FeeModule} from "../src/FeeModule.sol";
import {IFeeModule} from "../src/IFeeModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice A minimal, deliberately misbehaving IFeeModule used only to exercise
/// Web3Campaigns' defensive feeAmount > amount guard -- the reference FeeModule can never
/// produce this (capped at MAX_FEE_BPS <= 100%), so a real module can't reach this path.
contract EvilFeeModule is IFeeModule {
    function computeFee(uint256, uint256 amount) external pure returns (uint256 feeAmount, address treasury) {
        feeAmount = amount + 1; // always claims more than was funded
        treasury = address(0xBAD);
    }
}

/// @notice A second misbehaving IFeeModule used only to exercise Web3Campaigns' defensive
/// treasury == address(0) guard -- the reference FeeModule can never produce this (both its
/// constructor and setTreasury reject address(0)), so a real module can't reach this path either.
contract EvilFeeModuleZeroTreasury is IFeeModule {
    function computeFee(uint256, uint256 amount) external pure returns (uint256 feeAmount, address treasury) {
        feeAmount = amount / 10; // a plausible, in-bounds fee
        treasury = address(0); // but nowhere to send it
    }
}

/// @notice A module that always returns (0, address(0)) -- used to confirm the zero-treasury guard
/// only fires when there's an actual fee to send, not merely because treasury happens to be unset.
contract ZeroFeeZeroTreasuryModule is IFeeModule {
    function computeFee(uint256, uint256) external pure returns (uint256 feeAmount, address treasury) {
        return (0, address(0));
    }
}

/// @notice Covers the protocol-fee module: the standalone FeeModule contract itself, and its
/// wiring into Web3Campaigns' fundCampaignERC20 (a satellite split mirroring OnChainRewardModule --
/// see docs/ARCHITECTURE.md).
contract FeeModuleTest is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    FeeModule public feeModule;

    address public deployer;
    address public host1;
    address public treasury;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        treasury = vm.addr(3);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);

        vm.prank(deployer);
        campaigns.grantHostRole(host1);

        feeModule = new FeeModule(deployer, 250, treasury); // 2.5%
    }

    function _draftCampaign() internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.prank(host1);
        id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));
    }

    /*//////////////////////////////////////////////////////////////
                          FeeModule (standalone)
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(FeeModule.FeeModule__ZeroAddress.selector);
        new FeeModule(address(0), 100, treasury);
    }

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(FeeModule.FeeModule__ZeroAddress.selector);
        new FeeModule(deployer, 100, address(0));
    }

    function test_Constructor_RevertsIfFeeTooHigh() public {
        uint256 tooHigh = feeModule.MAX_FEE_BPS() + 1;
        vm.expectRevert(FeeModule.FeeModule__FeeTooHigh.selector);
        new FeeModule(deployer, tooHigh, treasury);
    }

    function test_ComputeFee_MatchesBpsMath() public view {
        (uint256 fee,) = feeModule.computeFee(1, 1000 ether);
        assertEq(fee, 25 ether); // 2.5% of 1000
    }

    function test_ComputeFee_ZeroBpsYieldsZeroFee() public {
        FeeModule zeroFee = new FeeModule(deployer, 0, treasury);
        (uint256 fee,) = zeroFee.computeFee(1, 1000 ether);
        assertEq(fee, 0);
    }

    function test_SetFeeBps_OnlyAdmin() public {
        vm.expectRevert(FeeModule.FeeModule__NotAdmin.selector);
        vm.prank(host1);
        feeModule.setFeeBps(500);
    }

    function test_SetFeeBps_RevertsIfTooHigh() public {
        uint256 tooHigh = feeModule.MAX_FEE_BPS() + 1;
        vm.prank(deployer);
        vm.expectRevert(FeeModule.FeeModule__FeeTooHigh.selector);
        feeModule.setFeeBps(tooHigh);
    }

    function test_SetFeeBps_Succeeds() public {
        vm.prank(deployer);
        feeModule.setFeeBps(500);
        assertEq(feeModule.feeBps(), 500);
    }

    function test_SetTreasury_OnlyAdmin() public {
        vm.expectRevert(FeeModule.FeeModule__NotAdmin.selector);
        vm.prank(host1);
        feeModule.setTreasury(host1);
    }

    function test_SetTreasury_RevertsOnZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(FeeModule.FeeModule__ZeroAddress.selector);
        feeModule.setTreasury(address(0));
    }

    function test_SetAdmin_OnlyAdmin() public {
        vm.expectRevert(FeeModule.FeeModule__NotAdmin.selector);
        vm.prank(host1);
        feeModule.setAdmin(host1);
    }

    function test_SetAdmin_RotatesSuccessfully() public {
        vm.prank(deployer);
        feeModule.setAdmin(host1);
        assertEq(feeModule.admin(), host1);

        // Old admin can no longer configure it.
        vm.expectRevert(FeeModule.FeeModule__NotAdmin.selector);
        vm.prank(deployer);
        feeModule.setFeeBps(1);
    }

    /*//////////////////////////////////////////////////////////////
                    Web3Campaigns wiring (fundCampaignERC20)
    //////////////////////////////////////////////////////////////*/

    function test_SetFeeModule_OnlyAdmin() public {
        vm.expectRevert();
        vm.prank(host1);
        campaigns.setFeeModule(address(feeModule));
    }

    function test_SetFeeModule_Succeeds() public {
        vm.prank(deployer);
        campaigns.setFeeModule(address(feeModule));
        assertEq(campaigns.getFeeModule(), address(feeModule));
    }

    /// @notice No fee module registered (the default) -- behavior is byte-for-byte unchanged from
    /// before this feature existed: full amount escrowed, no fee, no ProtocolFeeCollected event.
    function test_FundCampaignERC20_NoFeeModule_EscrowsFullAmount() public {
        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 100 ether);
        assertEq(token.balanceOf(address(campaigns)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    /// @notice With a fee module registered, escrow is credited net-of-fee, and the fee is
    /// transferred to the treasury in the same call -- the host still pays the full gross amount.
    function test_FundCampaignERC20_WithFeeModule_SkimsAndEscrowsNet() public {
        vm.prank(deployer);
        campaigns.setFeeModule(address(feeModule));

        uint256 id = _draftCampaign();
        uint256 hostBalBefore = token.balanceOf(host1);

        vm.startPrank(host1);
        token.approve(address(campaigns), 1000 ether);
        campaigns.fundCampaignERC20(id, 1000 ether);
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 975 ether); // 1000 - 2.5%
        assertEq(token.balanceOf(treasury), 25 ether);
        assertEq(token.balanceOf(address(campaigns)), 975 ether);
        assertEq(hostBalBefore - token.balanceOf(host1), 1000 ether); // host paid the full gross amount
    }

    function test_FundCampaignERC20_EmitsProtocolFeeCollected() public {
        vm.prank(deployer);
        campaigns.setFeeModule(address(feeModule));

        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 1000 ether);
        vm.expectEmit(true, true, false, true, address(campaigns));
        emit CampaignStorage.ProtocolFeeCollected(id, treasury, 25 ether);
        campaigns.fundCampaignERC20(id, 1000 ether);
        vm.stopPrank();
    }

    /// @notice Zero-bps fee module: escrow is unaffected, and no ProtocolFeeCollected event fires
    /// (feeAmount == 0 skips the transfer + event entirely).
    function test_FundCampaignERC20_ZeroFeeModule_NoFeeCollectedEvent() public {
        FeeModule zeroFee = new FeeModule(deployer, 0, treasury);
        vm.prank(deployer);
        campaigns.setFeeModule(address(zeroFee));

        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 100 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    /// @notice A misbehaving module claiming more fee than was funded is rejected explicitly
    /// (Web3Campaigns__FeeExceedsAmount) rather than relying on an implicit arithmetic underflow
    /// panic. The reference FeeModule can never trigger this (capped at MAX_FEE_BPS), so this uses
    /// a deliberately-evil mock to prove the defensive guard itself works.
    function test_FundCampaignERC20_RevertsIfFeeExceedsAmount() public {
        EvilFeeModule evil = new EvilFeeModule();
        vm.prank(deployer);
        campaigns.setFeeModule(address(evil));

        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        vm.expectRevert(CampaignStorage.Web3Campaigns__FeeExceedsAmount.selector);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();
    }

    /// @notice A misbehaving module returning a nonzero fee with a zero treasury is rejected
    /// explicitly (Web3Campaigns__InvalidFeeTreasury) rather than reaching safeTransfer(address(0),
    /// ...) -- which reverts on standard OZ tokens (a self-inflicted funding DoS) but could silently
    /// burn the skimmed fee on a permissive/non-standard token. Symmetric with the feeAmount >
    /// amount guard above. The reference FeeModule can never trigger this (constructor + setTreasury
    /// both reject address(0)), so this uses a deliberately-evil mock.
    function test_FundCampaignERC20_RevertsIfTreasuryIsZeroAddress() public {
        EvilFeeModuleZeroTreasury evil = new EvilFeeModuleZeroTreasury();
        vm.prank(deployer);
        campaigns.setFeeModule(address(evil));

        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidFeeTreasury.selector);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();
    }

    /// @notice A module returning feeAmount == 0 alongside treasury == address(0) is fine -- the
    /// zero-treasury guard only fires when there's actually a fee to send, matching the existing
    /// "feeAmount > 0" gate on the transfer/event itself.
    function test_FundCampaignERC20_ZeroFeeWithZeroTreasury_Succeeds() public {
        ZeroFeeZeroTreasuryModule zeroFee = new ZeroFeeZeroTreasuryModule();
        vm.prank(deployer);
        campaigns.setFeeModule(address(zeroFee));

        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 100 ether);
    }

    /// @notice Rotating the fee module mid-campaign only affects FUNDING CALLS MADE AFTER the
    /// rotation -- confirms there is no persistent per-campaign state to desync (unlike the reward
    /// module, this needs no pinning). A second top-up after rotation uses the NEW module's rate.
    function test_FeeModuleRotation_OnlyAffectsFutureFundingCalls() public {
        vm.prank(deployer);
        campaigns.setFeeModule(address(feeModule)); // 2.5%

        uint256 id = _draftCampaign();
        vm.startPrank(host1);
        token.approve(address(campaigns), 2000 ether);
        campaigns.fundCampaignERC20(id, 1000 ether); // 2.5% of 1000 = 25 fee
        vm.stopPrank();

        FeeModule newFeeModule = new FeeModule(deployer, 1000, treasury); // 10%
        vm.prank(deployer);
        campaigns.setFeeModule(address(newFeeModule));

        vm.prank(host1);
        campaigns.fundCampaignERC20(id, 1000 ether); // 10% of 1000 = 100 fee

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 975 ether + 900 ether); // first call net 975, second net 900
        assertEq(token.balanceOf(treasury), 25 ether + 100 ether);
    }
}
