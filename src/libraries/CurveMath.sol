// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Linear bonding curve P(s)=M*s, integrals in 1e18 fixed-point.
library CurveMath {
    uint256 internal constant WAD = 1e18;

    function spotPrice(uint256 s, uint256 m) internal pure returns (uint256) {
        return (m * s) / WAD;
    }

    /// @dev Cost to mint ds from supply s: M*s*ds/WAD^2 + M*ds^2/(2*WAD^2)
    function buyCost(uint256 s, uint256 ds, uint256 m) internal pure returns (uint256) {
        uint256 term1 = (m * s / WAD) * ds / WAD;
        uint256 term2 = (m * ds / WAD) * ds / (2 * WAD);
        return term1 + term2;
    }

    /// @dev Gross refund burning ds from supply s
    function sellRefund(uint256 s, uint256 ds, uint256 m) internal pure returns (uint256) {
        require(ds <= s, "CurveMath: ds>s");
        uint256 term1 = (m * s / WAD) * ds / WAD;
        uint256 term2 = (m * ds / WAD) * ds / (2 * WAD);
        return term1 - term2;
    }

    /// @dev ds from cost C at supply s: -s + sqrt(s^2 + 2*C*WAD^2/M)
    function sharesForCost(uint256 s, uint256 cost, uint256 m) internal pure returns (uint256) {
        if (cost == 0) return 0;
        uint256 twoCW2overM = (2 * cost * WAD / m) * WAD;
        uint256 disc = s * s + twoCW2overM;
        return sqrt(disc) - s;
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
