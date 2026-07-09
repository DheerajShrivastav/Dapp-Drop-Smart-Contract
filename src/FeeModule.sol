// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {IFeeModule} from "./IFeeModule.sol";

/// @notice Reference protocol-fee module: a flat, global basis-point fee applied to every
/// fundCampaignERC20 call, routed to a single treasury address. Deployed separately from
/// Web3Campaigns (its own EIP-170 budget) and referenced via the admin-rotatable `_feeModule`
/// pointer, mirroring the OnChainRewardModule split -- Web3Campaigns keeps all fund custody and does
/// the actual token movement; this contract only decides how much and where.
///
/// Deliberately minimal: a single rotatable `admin` address rather than pulling in OZ AccessControl
/// for one role, matching OnChainRewardModule's lightweight-satellite style. `admin` is intentionally
/// NOT required to be Web3Campaigns' own DEFAULT_ADMIN_ROLE holder -- the two are wired together by
/// whoever deploys and calls setFeeModule, not enforced on-chain, so a project could run its fee
/// module under separate governance if desired.
contract FeeModule is IFeeModule {
    uint256 public constant MAX_FEE_BPS = 1_000; // 10% cap -- sanity bound, not a policy statement
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public admin;
    uint256 public feeBps;
    address public treasury;

    error FeeModule__NotAdmin();
    error FeeModule__FeeTooHigh();
    error FeeModule__ZeroAddress();

    event AdminUpdated(address indexed admin);
    event FeeBpsUpdated(uint256 feeBps);
    event TreasuryUpdated(address indexed treasury);

    constructor(address _admin, uint256 _feeBps, address _treasury) {
        if (_admin == address(0) || _treasury == address(0)) {
            revert FeeModule__ZeroAddress();
        }
        if (_feeBps > MAX_FEE_BPS) {
            revert FeeModule__FeeTooHigh();
        }
        admin = _admin;
        feeBps = _feeBps;
        treasury = _treasury;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert FeeModule__NotAdmin();
        }
        _;
    }

    /// @notice Rotate the admin address allowed to configure this module.
    function setAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) {
            revert FeeModule__ZeroAddress();
        }
        admin = _admin;
        emit AdminUpdated(_admin);
    }

    /// @notice Update the flat fee rate, in basis points (100 = 1%). Capped at MAX_FEE_BPS.
    function setFeeBps(uint256 _feeBps) external onlyAdmin {
        if (_feeBps > MAX_FEE_BPS) {
            revert FeeModule__FeeTooHigh();
        }
        feeBps = _feeBps;
        emit FeeBpsUpdated(_feeBps);
    }

    /// @notice Update where collected fees are sent.
    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) {
            revert FeeModule__ZeroAddress();
        }
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @inheritdoc IFeeModule
    function computeFee(
        uint256,
        /* campaignId */
        uint256 amount
    )
        external
        view
        returns (uint256 feeAmount, address treasury_)
    {
        feeAmount = (amount * feeBps) / BPS_DENOMINATOR;
        treasury_ = treasury;
    }
}
