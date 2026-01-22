// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Exchange.sol";
import "./utils/MonadPerpExchangeHarness.sol";

/**
 * @title Multi-Market Test
 * @notice Tests for multi-market deployment and independent operation
 *
 * This test verifies that multiple Exchange contracts can be deployed
 * and operated independently, simulating ETH/USD, SOL/USD, and BTC/USD markets.
 */
contract MultiMarketTest is Test {
    // Three independent exchange contracts (one per market)
    MonadPerpExchangeHarness internal ethExchange;
    MonadPerpExchangeHarness internal solExchange;
    MonadPerpExchangeHarness internal btcExchange;

    // Test accounts
    address internal alice;
    address internal bob;
    address internal carol;

    // Initial prices for each market
    uint256 constant ETH_PRICE = 2000 ether;
    uint256 constant SOL_PRICE = 25 ether;
    uint256 constant BTC_PRICE = 42000 ether;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        // Deploy three separate Exchange contracts
        ethExchange = new MonadPerpExchangeHarness();
        solExchange = new MonadPerpExchangeHarness();
        btcExchange = new MonadPerpExchangeHarness();

        // Set initial prices for each market
        ethExchange.updateIndexPrice(ETH_PRICE);
        solExchange.updateIndexPrice(SOL_PRICE);
        btcExchange.updateIndexPrice(BTC_PRICE);

        // Fund test accounts
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        vm.deal(carol, 1_000_000 ether);
    }

    // =====================================================
    // Test 1: Independent Deployment
    // =====================================================
    function testMultipleExchangesDeployed() public view {
        // Verify each exchange has a unique address
        assertTrue(
            address(ethExchange) != address(solExchange),
            "ETH and SOL should have different addresses"
        );
        assertTrue(
            address(solExchange) != address(btcExchange),
            "SOL and BTC should have different addresses"
        );
        assertTrue(
            address(ethExchange) != address(btcExchange),
            "ETH and BTC should have different addresses"
        );
    }

    function testEachMarketHasCorrectPrice() public view {
        assertEq(
            ethExchange.indexPrice(),
            ETH_PRICE,
            "ETH market should have correct index price"
        );
        assertEq(
            solExchange.indexPrice(),
            SOL_PRICE,
            "SOL market should have correct index price"
        );
        assertEq(
            btcExchange.indexPrice(),
            BTC_PRICE,
            "BTC market should have correct index price"
        );
    }

    // =====================================================
    // Test 2: Independent Margin Deposits
    // =====================================================
    function testIndependentMarginDeposits() public {
        // Alice deposits different amounts to each market
        vm.startPrank(alice);
        ethExchange.deposit{value: 100 ether}();
        solExchange.deposit{value: 50 ether}();
        btcExchange.deposit{value: 500 ether}();
        vm.stopPrank();

        // Verify margins are tracked independently
        assertEq(ethExchange.margin(alice), 100 ether, "Alice ETH margin");
        assertEq(solExchange.margin(alice), 50 ether, "Alice SOL margin");
        assertEq(btcExchange.margin(alice), 500 ether, "Alice BTC margin");

        // Bob deposits only to ETH market
        vm.prank(bob);
        ethExchange.deposit{value: 200 ether}();

        assertEq(ethExchange.margin(bob), 200 ether, "Bob ETH margin");
        assertEq(solExchange.margin(bob), 0, "Bob should have no SOL margin");
        assertEq(btcExchange.margin(bob), 0, "Bob should have no BTC margin");
    }

    // =====================================================
    // Test 3: Independent Order Placement
    // =====================================================
    function testIndependentOrderPlacement() public {
        // Setup: Deposit to all markets
        vm.startPrank(alice);
        ethExchange.deposit{value: 1000 ether}();
        solExchange.deposit{value: 100 ether}();
        btcExchange.deposit{value: 5000 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        ethExchange.deposit{value: 1000 ether}();
        solExchange.deposit{value: 100 ether}();
        btcExchange.deposit{value: 5000 ether}();
        vm.stopPrank();

        // Place orders on different markets
        vm.prank(alice);
        ethExchange.placeOrder(true, ETH_PRICE, 1 ether, 0); // Buy 1 ETH

        vm.prank(alice);
        solExchange.placeOrder(true, SOL_PRICE, 10 ether, 0); // Buy 10 SOL

        vm.prank(alice);
        btcExchange.placeOrder(true, BTC_PRICE, 0.1 ether, 0); // Buy 0.1 BTC

        // Verify order books are independent
        assertEq(ethExchange.bestBuyId(), 1, "ETH should have buy order");
        assertEq(solExchange.bestBuyId(), 1, "SOL should have buy order");
        assertEq(btcExchange.bestBuyId(), 1, "BTC should have buy order");

        // Orders in one market don't affect others
        assertEq(ethExchange.bestSellId(), 0, "ETH should have no sell orders");
        assertEq(solExchange.bestSellId(), 0, "SOL should have no sell orders");
        assertEq(btcExchange.bestSellId(), 0, "BTC should have no sell orders");
    }

    // =====================================================
    // Test 4: Independent Trade Execution
    // =====================================================
    function testIndependentTradeExecution() public {
        // Setup: Deposit to ETH and SOL markets
        vm.startPrank(alice);
        ethExchange.deposit{value: 1000 ether}();
        solExchange.deposit{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        ethExchange.deposit{value: 1000 ether}();
        solExchange.deposit{value: 100 ether}();
        vm.stopPrank();

        // Execute trade on ETH market
        vm.prank(alice);
        ethExchange.placeOrder(true, ETH_PRICE, 1 ether, 0);
        vm.prank(bob);
        ethExchange.placeOrder(false, ETH_PRICE, 1 ether, 0);

        // Execute trade on SOL market
        vm.prank(alice);
        solExchange.placeOrder(true, SOL_PRICE, 5 ether, 0);
        vm.prank(bob);
        solExchange.placeOrder(false, SOL_PRICE, 5 ether, 0);

        // Verify positions are independent
        MonadPerpExchange.Position memory aliceEthPos = ethExchange.getPosition(
            alice
        );
        MonadPerpExchange.Position memory aliceSolPos = solExchange.getPosition(
            alice
        );
        MonadPerpExchange.Position memory aliceBtcPos = btcExchange.getPosition(
            alice
        );

        assertEq(aliceEthPos.size, 1 ether, "Alice should have 1 ETH long");
        assertEq(aliceSolPos.size, 5 ether, "Alice should have 5 SOL long");
        assertEq(aliceBtcPos.size, 0, "Alice should have no BTC position");

        // Verify entry prices match market prices
        assertEq(aliceEthPos.entryPrice, ETH_PRICE, "ETH entry price");
        assertEq(aliceSolPos.entryPrice, SOL_PRICE, "SOL entry price");
    }

    // =====================================================
    // Test 5: Independent Price Updates
    // =====================================================
    function testIndependentPriceUpdates() public {
        // Update ETH price
        ethExchange.updateIndexPrice(2500 ether);

        // Update SOL price
        solExchange.updateIndexPrice(30 ether);

        // BTC price unchanged

        // Verify prices are independent
        assertEq(
            ethExchange.indexPrice(),
            2500 ether,
            "ETH should have new price"
        );
        assertEq(
            solExchange.indexPrice(),
            30 ether,
            "SOL should have new price"
        );
        assertEq(
            btcExchange.indexPrice(),
            BTC_PRICE,
            "BTC should still have original price"
        );
    }

    // =====================================================
    // Test 6: Cross-Market Trading Scenario
    // =====================================================
    function testCrossMarketTradingScenario() public {
        // Alice is bullish on ETH and BTC, bearish on SOL
        vm.startPrank(alice);
        ethExchange.deposit{value: 2000 ether}();
        solExchange.deposit{value: 200 ether}();
        btcExchange.deposit{value: 10000 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        ethExchange.deposit{value: 2000 ether}();
        solExchange.deposit{value: 200 ether}();
        btcExchange.deposit{value: 10000 ether}();
        vm.stopPrank();

        // Alice goes long ETH
        vm.prank(bob);
        ethExchange.placeOrder(false, ETH_PRICE, 2 ether, 0);
        vm.prank(alice);
        ethExchange.placeOrder(true, ETH_PRICE, 2 ether, 0);

        // Alice goes short SOL
        vm.prank(bob);
        solExchange.placeOrder(true, SOL_PRICE, 20 ether, 0);
        vm.prank(alice);
        solExchange.placeOrder(false, SOL_PRICE, 20 ether, 0);

        // Alice goes long BTC
        vm.prank(bob);
        btcExchange.placeOrder(false, BTC_PRICE, 0.5 ether, 0);
        vm.prank(alice);
        btcExchange.placeOrder(true, BTC_PRICE, 0.5 ether, 0);

        // Verify Alice's positions
        MonadPerpExchange.Position memory ethPos = ethExchange.getPosition(
            alice
        );
        MonadPerpExchange.Position memory solPos = solExchange.getPosition(
            alice
        );
        MonadPerpExchange.Position memory btcPos = btcExchange.getPosition(
            alice
        );

        assertEq(ethPos.size, 2 ether, "Alice long 2 ETH");
        assertEq(solPos.size, -20 ether, "Alice short 20 SOL");
        assertEq(btcPos.size, 0.5 ether, "Alice long 0.5 BTC");

        // Verify Bob has opposite positions
        MonadPerpExchange.Position memory bobEthPos = ethExchange.getPosition(
            bob
        );
        MonadPerpExchange.Position memory bobSolPos = solExchange.getPosition(
            bob
        );
        MonadPerpExchange.Position memory bobBtcPos = btcExchange.getPosition(
            bob
        );

        assertEq(bobEthPos.size, -2 ether, "Bob short 2 ETH");
        assertEq(bobSolPos.size, 20 ether, "Bob long 20 SOL");
        assertEq(bobBtcPos.size, -0.5 ether, "Bob short 0.5 BTC");
    }

    // =====================================================
    // Test 7: PnL Calculation per Market
    // =====================================================
    function testPnLCalculationPerMarket() public {
        // Setup positions
        vm.startPrank(alice);
        ethExchange.deposit{value: 2000 ether}();
        btcExchange.deposit{value: 10000 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        ethExchange.deposit{value: 2000 ether}();
        btcExchange.deposit{value: 10000 ether}();
        vm.stopPrank();

        // Alice longs 1 ETH @ 2000
        vm.prank(bob);
        ethExchange.placeOrder(false, ETH_PRICE, 1 ether, 0);
        vm.prank(alice);
        ethExchange.placeOrder(true, ETH_PRICE, 1 ether, 0);

        // Alice longs 0.1 BTC @ 42000
        vm.prank(bob);
        btcExchange.placeOrder(false, BTC_PRICE, 0.1 ether, 0);
        vm.prank(alice);
        btcExchange.placeOrder(true, BTC_PRICE, 0.1 ether, 0);

        // Price changes: ETH up 10%, BTC down 5%
        uint256 newEthPrice = 2200 ether; // +10%
        uint256 newBtcPrice = 39900 ether; // -5%

        ethExchange.updateIndexPrice(newEthPrice);
        btcExchange.updateIndexPrice(newBtcPrice);

        // Calculate expected PnL
        // ETH: 1 ETH * (2200 - 2000) = +200 ETH
        // BTC: 0.1 BTC * (39900 - 42000) = -210 ETH

        MonadPerpExchange.Position memory ethPos = ethExchange.getPosition(
            alice
        );
        MonadPerpExchange.Position memory btcPos = btcExchange.getPosition(
            alice
        );

        int256 ethPnL = ((int256(newEthPrice) - int256(ethPos.entryPrice)) *
            ethPos.size) / 1e18;
        int256 btcPnL = ((int256(newBtcPrice) - int256(btcPos.entryPrice)) *
            btcPos.size) / 1e18;

        assertEq(ethPnL, 200 ether, "ETH PnL should be +200");
        assertEq(btcPnL, -210 ether, "BTC PnL should be -210");
    }

    // =====================================================
    // Test 8: Market Isolation - Liquidation in One Market
    // =====================================================
    function testMarketIsolationOnLiquidation() public {
        // Setup: Alice deposits to both markets
        vm.startPrank(alice);
        ethExchange.deposit{value: 100 ether}();
        solExchange.deposit{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        ethExchange.deposit{value: 1000 ether}();
        solExchange.deposit{value: 1000 ether}();
        vm.stopPrank();

        // Alice takes a large ETH long position
        vm.prank(bob);
        ethExchange.placeOrder(false, ETH_PRICE, 5 ether, 0);
        vm.prank(alice);
        ethExchange.placeOrder(true, ETH_PRICE, 5 ether, 0);

        // Alice takes a small SOL long position
        vm.prank(bob);
        solExchange.placeOrder(false, SOL_PRICE, 2 ether, 0);
        vm.prank(alice);
        solExchange.placeOrder(true, SOL_PRICE, 2 ether, 0);

        // ETH price crashes 50% - Alice should be liquidatable on ETH
        ethExchange.updateIndexPrice(1000 ether);

        // Check ETH market - Alice should be liquidatable
        assertTrue(
            ethExchange.canLiquidate(alice),
            "Alice should be liquidatable on ETH"
        );

        // Check SOL market - Alice should NOT be liquidatable
        assertFalse(
            solExchange.canLiquidate(alice),
            "Alice should NOT be liquidatable on SOL"
        );

        // SOL position should be unaffected
        MonadPerpExchange.Position memory solPos = solExchange.getPosition(
            alice
        );
        assertEq(solPos.size, 2 ether, "SOL position should be intact");
    }

    // =====================================================
    // Helper: Get total equity across markets
    // =====================================================
    function getTotalEquity(address trader) internal view returns (int256) {
        int256 ethEquity = int256(ethExchange.margin(trader)) +
            _getPnL(ethExchange, trader);
        int256 solEquity = int256(solExchange.margin(trader)) +
            _getPnL(solExchange, trader);
        int256 btcEquity = int256(btcExchange.margin(trader)) +
            _getPnL(btcExchange, trader);
        return ethEquity + solEquity + btcEquity;
    }

    function _getPnL(
        MonadPerpExchangeHarness exch,
        address trader
    ) internal view returns (int256) {
        MonadPerpExchange.Position memory pos = exch.getPosition(trader);
        if (pos.size == 0) return 0;
        return
            ((int256(exch.indexPrice()) - int256(pos.entryPrice)) * pos.size) /
            1e18;
    }
}
