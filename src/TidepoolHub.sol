// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title TidepoolHub — singleton ERC-1155 bonding-curve hub (slice MVP)
/// @notice Linear curve P(s)=M·s, R(s)=M·s²/2. Buy pays Cost; sell pays GrossRefund capped at reserve.
contract TidepoolHub is ERC1155, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_ID = 1;
    uint256 public constant M = 1e15;

    IERC20 public immutable usdc;
    uint256 public supply;
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

    function spot() external view returns (uint256) {
        return CurveMath.spotPrice(supply, M);
    }

    /// @notice Preview shares minted for a USDC payment (no state change).
    function quoteBuy(uint256 usdcAmount) external view returns (uint256 sharesOut) {
        return CurveMath.sharesForCost(supply, usdcAmount, M);
    }

    /// @notice Preview USDC paid for a sell, capped at current reserve.
    function quoteSell(uint256 shares) external view returns (uint256 usdcOut) {
        uint256 gross = CurveMath.sellRefund(supply, shares, M);
        return gross > reserve ? reserve : gross;
    }

    function buy(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 ds = CurveMath.sharesForCost(supply, usdcAmount, M);
        if (ds == 0) revert ZeroAmount();
        // Exact cost for ds may be <= usdcAmount; keep full payment in reserve (dust stays)
        supply += ds;
        reserve += usdcAmount;
        _mint(msg.sender, POOL_ID, ds, "");
        emit Bought(msg.sender, usdcAmount, ds, supply);
    }

    function sell(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender, POOL_ID) < shares) revert InsufficientShares();
        uint256 gross = CurveMath.sellRefund(supply, shares, M);
        uint256 paid = gross > reserve ? reserve : gross;
        supply -= shares;
        reserve -= paid;
        _burn(msg.sender, POOL_ID, shares);
        usdc.safeTransfer(msg.sender, paid);
        emit Sold(msg.sender, shares, paid, supply);
    }
}
