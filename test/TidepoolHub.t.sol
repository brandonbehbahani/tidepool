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
    uint256 internal constant USDC = 1e6; // one USDC in base units
    uint256 internal constant SCALE = 1e12;

    event Bought(address indexed buyer, uint256 usdcIn, uint256 sharesOut, uint256 supplyAfter);
    event Sold(address indexed seller, uint256 sharesIn, uint256 usdcOut, uint256 supplyAfter);

    function setUp() public {
        usdc = new MockUSDC();
        hub = new TidepoolHub(usdc);

        usdc.mint(alice, 1_000_000 * USDC);
        usdc.mint(bob, 1_000_000 * USDC);

        vm.prank(alice);
        usdc.approve(address(hub), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(hub), type(uint256).max);
    }

    function test_buy_mintsSharesAndIncreasesReserve() public {
        uint256 amount = 100 * USDC;
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
        uint256 amount = 100 * USDC;
        vm.prank(alice);
        hub.buy(amount);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 balBefore = usdc.balanceOf(alice);
        uint256 reserveBefore = hub.reserve();
        uint256 gross = CurveMath.sellRefund(hub.supply(), shares, M) / SCALE;
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
        hub.buy(50 * USDC);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 half = shares / 2;
        uint256 reserveBefore = hub.reserve();
        uint256 expectedGross = CurveMath.sellRefund(hub.supply(), half, M) / SCALE;
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
        hub.buy(10 * USDC);

        vm.prank(alice);
        vm.expectRevert(TidepoolHub.ZeroAmount.selector);
        hub.sell(0);
    }

    function test_sell_revertsOnInsufficientShares() public {
        vm.prank(alice);
        hub.buy(10 * USDC);

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
        hub.buy(10 * USDC);
        uint256 spot1 = hub.spot();
        assertGt(spot1, 0);

        vm.prank(bob);
        hub.buy(10 * USDC);
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
        hub.buy(77 * USDC);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 gross = CurveMath.sellRefund(hub.supply(), shares, M) / SCALE;
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

    function test_quoteBuy_matchesBuyMint() public {
        uint256 amount = 100 * USDC;
        uint256 quoted = hub.quoteBuy(amount);

        vm.prank(alice);
        hub.buy(amount);

        assertEq(hub.balanceOf(alice, hub.POOL_ID()), quoted, "quoteBuy matches minted");
        assertEq(hub.supply(), quoted);
    }

    function test_quoteSell_matchesSellPayout() public {
        vm.prank(alice);
        hub.buy(100 * USDC);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 quoted = hub.quoteSell(shares);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.sell(shares);

        assertEq(usdc.balanceOf(alice) - balBefore, quoted, "quoteSell matches payout");
    }

    function test_quoteBuy_zeroWhenDustTooSmall() public view {
        // Tiny payment may mint zero shares at high supply; at s=0 still positive for 1 wei usually
        assertEq(hub.quoteBuy(0), 0);
    }

    function test_quoteBuyShares_matchesBuyCost() public {
        uint256 target = 2e18;
        assertEq(hub.quoteBuyShares(target), _ceilUsdc(CurveMath.buyCost(0, target, M)));

        vm.prank(alice);
        hub.buy(50 * USDC);

        uint256 s = hub.supply();
        uint256 target2 = 1e18;
        assertEq(hub.quoteBuyShares(target2), _ceilUsdc(CurveMath.buyCost(s, target2, M)));
    }

    function test_quoteBuyShares_buyUndershootsTarget() public {
        // buy() mints via sharesForCost; paying buyCost(s, ds) may mint <= ds (integer undershoot).
        uint256 target = 3e18;
        uint256 cost = hub.quoteBuyShares(target);
        assertGt(cost, 0);
        // Capture expected mint before state changes (quoteBuy uses current supply).
        uint256 expectedMint = hub.quoteBuy(cost);
        assertLe(expectedMint, target, "sharesForCost undershoots buyCost target");

        vm.prank(alice);
        hub.buy(cost);

        uint256 minted = hub.balanceOf(alice, hub.POOL_ID());
        assertEq(minted, expectedMint, "quoteBuy matches actual mint");
        assertGt(minted, 0);
    }

    function test_buy_revertsWhenDustMintsZeroShares() public {
        // At extreme supply (>1e15 shares), 1 base unit of USDC rounds to 0 shares; CEI buy must revert.
        usdc.mint(alice, 1e33);
        vm.prank(alice);
        hub.buy(6e32);
        assertGt(hub.supply(), 1e33, "supply high enough for 1-unit dust");
        assertEq(hub.quoteBuy(1), 0, "1 wei quotes zero shares");

        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 hubUsdc = usdc.balanceOf(address(hub));
        uint256 supplyBefore = hub.supply();
        uint256 reserveBefore = hub.reserve();

        vm.prank(alice);
        vm.expectRevert(TidepoolHub.ZeroAmount.selector);
        hub.buy(1);

        assertEq(usdc.balanceOf(alice), aliceUsdc, "buyer USDC unchanged");
        assertEq(usdc.balanceOf(address(hub)), hubUsdc, "hub USDC unchanged");
        assertEq(hub.supply(), supplyBefore, "supply unchanged");
        assertEq(hub.reserve(), reserveBefore, "reserve unchanged");
    }

    function test_buy_emitsBought() public {
        uint256 amount = 25 * USDC;
        uint256 expectedShares = hub.quoteBuy(amount);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(hub));
        emit Bought(alice, amount, expectedShares, expectedShares);
        hub.buy(amount);
    }

    function test_sell_revertsWhenDustPaysZero() public {
        // After a normal buy, selling 1 share rounds GrossRefund to 0; CEI sell must revert with no burn.
        vm.prank(alice);
        hub.buy(1 * USDC);
        assertEq(hub.quoteSell(1), 0, "1 share quotes zero USDC");

        uint256 aliceShares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 hubUsdc = usdc.balanceOf(address(hub));
        uint256 supplyBefore = hub.supply();
        uint256 reserveBefore = hub.reserve();

        vm.prank(alice);
        vm.expectRevert(TidepoolHub.ZeroAmount.selector);
        hub.sell(1);

        assertEq(hub.balanceOf(alice, hub.POOL_ID()), aliceShares, "shares unchanged");
        assertEq(usdc.balanceOf(alice), aliceUsdc, "seller USDC unchanged");
        assertEq(usdc.balanceOf(address(hub)), hubUsdc, "hub USDC unchanged");
        assertEq(hub.supply(), supplyBefore, "supply unchanged");
        assertEq(hub.reserve(), reserveBefore, "reserve unchanged");
    }

    function test_sell_emitsSold() public {
        vm.prank(alice);
        hub.buy(25 * USDC);

        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        uint256 expectedOut = hub.quoteSell(shares);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(hub));
        emit Sold(alice, shares, expectedOut, 0);
        hub.sell(shares);
    }

    // ---- 6-decimal USDC at realistic amounts ----

    function _ceilUsdc(uint256 wad) internal pure returns (uint256) {
        return (wad + SCALE - 1) / SCALE;
    }

    function test_usdc6_firstShareCostsHalfAMilliDollar() public view {
        // Before the fix the first share cost 5e14 base units (~$500M at 6 dp).
        assertEq(hub.quoteBuyShares(1e18), 500, "first share = 500 units = $0.0005");
        assertEq(usdc.decimals(), 6);
    }

    function test_usdc6_spotAtOneShareIsOneMilliDollar() public {
        uint256 cost = hub.quoteBuyShares(1e18);
        vm.prank(alice);
        hub.buy(cost);
        // sharesForCost may undershoot by a wei, so spot is just under $0.001 (1000 units)
        assertApproxEqAbs(hub.spot(), 1000, 1, "spot ~= $0.001 at 1 share");
    }

    function _assertRealisticBuy(uint256 amount) internal {
        uint256 quoted = hub.quoteBuy(amount);
        vm.prank(alice);
        hub.buy(amount);
        uint256 shares = hub.balanceOf(alice, hub.POOL_ID());
        assertEq(shares, quoted);
        // Exact curve cost of what was minted never exceeds what was paid
        assertLe(_ceilUsdc(CurveMath.buyCost(0, shares, M)), amount, "paid covers curve cost");
        assertEq(hub.reserve(), amount);
    }

    function test_usdc6_buy_oneDollar() public {
        _assertRealisticBuy(1 * USDC);
        // $1 at s=0: ds = sqrt(2 * 1e18 * 1e36 / 1e15) ~= 44.72 shares
        assertApproxEqRel(hub.supply(), 44.72e18, 1e15);
    }

    function test_usdc6_buy_hundredDollars() public {
        _assertRealisticBuy(100 * USDC);
        assertApproxEqRel(hub.supply(), 447.21e18, 1e15);
    }

    function test_usdc6_buy_tenThousandDollars() public {
        _assertRealisticBuy(10_000 * USDC);
        assertApproxEqRel(hub.supply(), 4472.13e18, 1e15);
    }

    function _roundTrip(uint256 amount) internal {
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        hub.buy(amount);
        uint256 shares = hub.balanceOf(bob, hub.POOL_ID());
        // A dust position whose payout rounds to 0 is rejected by sell (ZeroAmount); bob just keeps it.
        if (hub.quoteSell(shares) > 0) {
            vm.prank(bob);
            hub.sell(shares);
        }
        assertLe(usdc.balanceOf(bob), before, "round trip never profits");
    }

    function test_usdc6_roundTrips_neverProfit() public {
        vm.prank(alice);
        hub.buy(500 * USDC); // existing holder so bob trades mid-curve
        _roundTrip(1 * USDC);
        _roundTrip(100 * USDC);
        _roundTrip(10_000 * USDC);
    }

    function testFuzz_usdc6_roundTripNeverProfits(uint256 seed, uint256 amount) public {
        seed = bound(seed, 0, 100_000 * USDC);
        amount = bound(amount, 1, 100_000 * USDC);
        if (seed > 0) {
            vm.prank(alice);
            hub.buy(seed);
        }
        _roundTrip(amount);
    }

    function _redeemableAll() internal view returns (uint256) {
        return CurveMath.sellRefund(hub.supply(), hub.supply(), M) / SCALE;
    }

    function test_usdc6_reserveCoversAllRedeemable() public {
        vm.prank(alice);
        hub.buy(1 * USDC);
        vm.prank(bob);
        hub.buy(100 * USDC);
        vm.prank(alice);
        hub.buy(10_000 * USDC);
        assertGe(hub.reserve(), _redeemableAll(), "reserve >= sum redeemable");

        uint256 third = hub.balanceOf(bob, hub.POOL_ID()) / 3;
        vm.prank(bob);
        hub.sell(third);
        assertGe(hub.reserve(), _redeemableAll(), "still solvent after partial sell");
    }

    function testFuzz_usdc6_reserveCoversAllRedeemable(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 100_000 * USDC);
        b = bound(b, 1, 100_000 * USDC);
        vm.prank(alice);
        hub.buy(a);
        vm.prank(bob);
        hub.buy(b);
        c = bound(c, 0, hub.balanceOf(alice, hub.POOL_ID()));
        if (c > 0 && hub.quoteSell(c) > 0) {
            vm.prank(alice);
            hub.sell(c);
        }
        assertGe(hub.reserve(), _redeemableAll(), "reserve >= sum redeemable");
        assertEq(usdc.balanceOf(address(hub)), hub.reserve());
    }
}
