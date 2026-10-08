// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TidepoolHub} from "../src/TidepoolHub.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TidepoolHubTest is Test {
    TidepoolHub internal hub;
    MockUSDC internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant M = 1e15;
    uint256 internal constant WAD = 1e18;

    function setUp() public {
        usdc = new MockUSDC();
        hub = new TidepoolHub(usdc);

        usdc.mint(alice, 1_000_000 ether);
        usdc.mint(bob, 1_000_000 ether);

        vm.prank(alice);
        usdc.approve(address(hub), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(hub), type(uint256).max);
    }

    function test_buy_mintsSharesAndIncreasesReserve() public {
        uint256 amount = 100 ether;
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.buy(amount);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        assertGt(shares, 0, "shares minted");
        assertEq(hub.supply(), shares, "supply == alice shares");
        assertEq(hub.reserve(), amount, "reserve == usdc paid");
        assertEq(usdc.balanceOf(alice), balBefore - amount, "USDC deducted");
        assertEq(usdc.balanceOf(address(hub)), amount, "hub holds USDC");
    }

    function test_sell_burnsSharesAndPaysRefund() public {
        uint256 amount = 100 ether;
        vm.prank(alice);
        hub.buy(amount);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 balBefore = usdc.balanceOf(alice);
        uint256 reserveBefore = hub.reserve();
        uint256 gross = CurveMath.sellRefund(hub.supply(), shares, M);
        uint256 paidExpected = gross > reserveBefore ? reserveBefore : gross;

        vm.prank(alice);
        hub.sell(shares);

        assertEq(hub.balanceOf(alice, hub.POOL_ID()), 0, "shares burned");
        assertEq(hub.supply(), 0, "supply zero");
        // Dust from buy (paid > exact cost) may remain in reserve after full sell
        assertEq(hub.reserve(), reserveBefore - paidExpected, "reserve reduced by paid");
        assertEq(usdc.balanceOf(alice) - balBefore, paidExpected, "refund amount");
        assertLe(paidExpected, reserveBefore, "paid <= prior reserve");
    }

    function test_reserveAccounting_buyThenPartialSell() public {
        vm.prank(alice);
        hub.buy(50 ether);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 half = shares / 2;
        uint256 reserveBefore = hub.reserve();
        uint256 expectedGross = CurveMath.sellRefund(hub.supply(), half, M);
        uint256 expectedPaid = expectedGross > reserveBefore ? reserveBefore : expectedGross;

        vm.prank(alice);
        hub.sell(half);

        assertEq(hub.supply(), shares - half);
        assertEq(hub.reserve(), reserveBefore - expectedPaid);
        assertEq(usdc.balanceOf(address(hub)), hub.reserve());
    }

    function test_buy_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TidepoolHub.ZeroAmount.selector);
        hub.buy(0);
    }

    function test_sell_revertsOnZeroAmount() public {
        vm.prank(alice);
        hub.buy(10 ether);

        vm.prank(alice);
        vm.expectRevert(TidepoolHub.ZeroAmount.selector);
        hub.sell(0);
    }

    function test_sell_revertsOnInsufficientShares() public {
        vm.prank(alice);
        hub.buy(10 ether);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());

        vm.prank(alice);
        vm.expectRevert(TidepoolHub.InsufficientShares.selector);
        hub.sell(shares + 1);
    }

    function test_sell_revertsWhenNoShares() public {
        vm.prank(alice);
        vm.expectRevert(TidepoolHub.InsufficientShares.selector);
        hub.sell(1);
    }

    function test_spotIncreasesWithSupply() public {
        assertEq(hub.spot(), 0);

        vm.prank(alice);
        hub.buy(10 ether);
        uint256 spot1 = hub.spot();
        assertGt(spot1, 0);

        vm.prank(bob);
        hub.buy(10 ether);
        uint256 spot2 = hub.spot();
        assertGt(spot2, spot1, "spot rises with supply");
    }

    function test_buySellMathIdentity() public pure {
        // At s=0: buyCost(0,ds) == sellRefund(ds,ds) exactly (same formula terms)
        uint256 s = 0;
        uint256 cost = 25 ether;
        uint256 ds = CurveMath.sharesForCost(s, cost, M);
        assertGt(ds, 0);

        uint256 exactCost = CurveMath.buyCost(s, ds, M);
        // exactCost for ds should be <= paid cost (dust stays in reserve)
        assertLe(exactCost, cost);

        uint256 refund = CurveMath.sellRefund(ds, ds, M);
        assertEq(refund, exactCost, "full round-trip identity at s=0");
    }

    function test_buySellMathIdentity_nonzeroSupply() public pure {
        // Algebraic identity: sellRefund(s+ds, ds) ~= buyCost(s, ds)
        // Integer division can leave at most 1 wei of dust between the two forms.
        uint256 s = 1e18;
        uint256 ds = 5e17;
        uint256 cost = CurveMath.buyCost(s, ds, M);
        uint256 refund = CurveMath.sellRefund(s + ds, ds, M);
        assertApproxEqAbs(refund, cost, 1, "buy/sell identity at nonzero supply");

        // sharesForCost then buyCost should be <= paid cost
        uint256 paid = 40 ether;
        uint256 ds2 = CurveMath.sharesForCost(s, paid, M);
        uint256 exact = CurveMath.buyCost(s, ds2, M);
        assertLe(exact, paid, "sharesForCost undershoots paid");
        assertApproxEqAbs(CurveMath.sellRefund(s + ds2, ds2, M), exact, 1);
    }

    function test_sellPaysMinGrossAndReserve() public {
        // After buy, dust can make reserve > theoretical R(s); sell of all should pay min(gross, reserve)
        vm.prank(alice);
        hub.buy(77 ether);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 gross = CurveMath.sellRefund(hub.supply(), shares, M);
        uint256 reserveBefore = hub.reserve();
        uint256 paidExpected = gross > reserveBefore ? reserveBefore : gross;

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        hub.sell(shares);

        assertEq(usdc.balanceOf(alice) - balBefore, paidExpected);
        assertEq(hub.reserve(), reserveBefore - paidExpected);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(TidepoolHub.ZeroAddress.selector);
        new TidepoolHub(IERC20(address(0)));
    }

    function test_poolIdIsOne() public view {
        assertEq(hub.POOL_ID(), 1);
    }

    function test_curveMath_spotPrice() public pure {
        assertEq(CurveMath.spotPrice(0, M), 0);
        // P(s)=M*s/WAD => s=WAD => spot=M
        assertEq(CurveMath.spotPrice(WAD, M), M);
    }
}
