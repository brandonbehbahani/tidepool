// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title TidepoolHub — singleton ERC-1155 bonding-curve hub (slice MVP)
/// @notice Linear curve P(s)=M·s, R(s)=M·s²/2. Buy pays Cost; sell pays GrossRefund capped at reserve.
/// @dev Units: shares are 18-dp (1e18 = one share); CurveMath works in 18-dp USD ("WAD").
///      USDC has 6 decimals, so every USDC amount is scaled by USDC_TO_WAD (1e12) at this boundary.
///      With M = 1e15 the spot price at one share outstanding is $0.001 and the first full share
///      costs $0.0005. Rounding favours the pool: buys keep the full payment, sells and quotes of
///      payouts round down, and quoteBuyShares rounds up.
contract TidepoolHub is ERC1155, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_ID = 1;
    /// @notice Curve slope in WAD: spot at 1 share = M / 1e18 USD = $0.001.
    uint256 public constant M = 1e15;
    /// @notice Scale from 6-decimal USDC base units to 18-decimal WAD.
    uint256 public constant USDC_TO_WAD = 1e12;

    IERC20 public immutable usdc;
    uint256 public supply;
    /// @notice USDC held for the pool, in 6-decimal base units.
    uint256 public reserve;

    error ZeroAmount();
    error InsufficientShares();
    error ZeroAddress();

    event Bought(address indexed buyer, uint256 usdcIn, uint256 sharesOut, uint256 supplyAfter);
    event Sold(address indexed seller, uint256 sharesIn, uint256 usdcOut, uint256 supplyAfter);

    constructor(IERC20 usdc_) ERC1155("https://tidepool.local/{id}.json") {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    /// @notice Spot price per whole share, in 6-decimal USDC base units (rounded down).
    function spot() external view returns (uint256) {
        return CurveMath.spotPrice(supply, M) / USDC_TO_WAD;
    }

    /// @notice Preview shares minted for a USDC payment (no state change).
    function quoteBuy(uint256 usdcAmount) external view returns (uint256 sharesOut) {
        return CurveMath.sharesForCost(supply, usdcAmount * USDC_TO_WAD, M);
    }

    /// @notice Preview USDC paid for a sell, capped at current reserve.
    function quoteSell(uint256 shares) external view returns (uint256 usdcOut) {
        uint256 gross = _sellRefundUsdc(shares);
        return gross > reserve ? reserve : gross;
    }

    /// @notice Preview USDC needed to mint an exact share amount (theoretical buyCost).
    /// @dev `buy` uses sharesForCost, which can undershoot: paying this cost may mint <= `shares`.
    function quoteBuyShares(uint256 shares) external view returns (uint256 usdcIn) {
        uint256 wad = CurveMath.buyCost(supply, shares, M);
        return (wad + USDC_TO_WAD - 1) / USDC_TO_WAD; // round up: never under-quote the payment
    }

    function buy(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        // CEI: compute shares before transfer so dust that mints 0 reverts without moving USDC
        uint256 ds = CurveMath.sharesForCost(supply, usdcAmount * USDC_TO_WAD, M);
        if (ds == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        // Exact cost for ds may be <= usdcAmount; keep full payment in reserve (dust stays)
        supply += ds;
        reserve += usdcAmount;
        _mint(msg.sender, POOL_ID, ds, "");
        emit Bought(msg.sender, usdcAmount, ds, supply);
    }

    /// @notice Burn shares for reserve-capped USDC refund (GrossRefund, min reserve).
    /// @dev CEI: compute `paid` before burn/transfer; dust sells that pay 0 revert without burning.
    function sell(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, POOL_ID) < shares) revert InsufficientShares();
        // CEI: compute payout before burn so a dust sell that pays 0 does not destroy shares
        uint256 gross = _sellRefundUsdc(shares);
        uint256 paid = gross > reserve ? reserve : gross;
        if (paid == 0) revert ZeroAmount();
        supply -= shares;
        reserve -= paid;
        _burn(msg.sender, POOL_ID, shares);
        usdc.safeTransfer(msg.sender, paid);
        emit Sold(msg.sender, shares, paid, supply);
    }

    /// @dev GrossRefund converted to USDC base units, rounded down (pool keeps the remainder).
    function _sellRefundUsdc(uint256 shares) internal view returns (uint256) {
        return CurveMath.sellRefund(supply, shares, M) / USDC_TO_WAD;
    }
}
