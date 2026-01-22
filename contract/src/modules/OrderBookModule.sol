// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "./MarginModule.sol";

/// @notice Order placement and matching logic.
/// @dev Day 2-3: 订单簿与撮合模块
abstract contract OrderBookModule is MarginModule {

    /// @notice 下单
    /// @param isBuy 是否为买单
    /// @param price 价格
    /// @param amount 数量
    /// @param hintId 插入提示 (可选优化)
    /// @return 订单 ID
  function placeOrder(bool isBuy, uint256 price, uint256 amount, uint256 hintId)
    external
    virtual
    nonReentrant
    returns (uint256)
{
    require(price > 0 && amount > 0, "invalid params");

    _applyFunding(msg.sender);

    require(_countPendingOrders(msg.sender) < MAX_PENDING_ORDERS, "too many pending orders");
    _checkWorstCaseMargin(msg.sender);

    orderIdCounter += 1;
    uint256 orderId = orderIdCounter;
    emit OrderPlaced(orderId, msg.sender, isBuy, price, amount);

    Order memory incoming = Order(orderId, msg.sender, isBuy, price, amount, amount, block.timestamp, 0);

    if (isBuy) _matchBuy(incoming, hintId);
    else _matchSell(incoming, hintId);

    return orderId;
}

    /// @notice 取消订单
    /// @param orderId 订单 ID
    function cancelOrder(uint256 orderId) external virtual nonReentrant {
    Order storage o = orders[orderId];
    require(o.id != 0, "order not found");
    require(o.trader == msg.sender, "not your order");

    if (o.isBuy) bestBuyId = _removeOrderFromList(bestBuyId, orderId);
    else bestSellId = _removeOrderFromList(bestSellId, orderId);

    pendingOrderCount[msg.sender]--;
    emit OrderRemoved(orderId);
    delete orders[orderId];
}



    /// @notice 从链表中移除指定订单
    function _removeOrderFromList(uint256 head, uint256 targetId) internal returns (uint256 newHead) {
    if (head == targetId) return orders[head].next;

    uint256 prev = head;
    uint256 curr = orders[head].next;
    while (curr != 0) {
        if (curr == targetId) {
            orders[prev].next = orders[curr].next;
            break;
        }
        prev = curr;
        curr = orders[curr].next;
    }
    return head;
}

    /// @notice 买单撮合
    /// @dev Day 3: 撮合买单与卖单链表
   function _matchBuy(Order memory incoming, uint256 hintId) internal virtual {
    while (incoming.amount > 0 && bestSellId != 0) {
        Order storage head = orders[bestSellId];
        if (incoming.price < head.price) break;

        uint256 matched = Math.min(incoming.amount, head.amount);
        _executeTrade(incoming.trader, head.trader, incoming.id, head.id, matched, head.price); // Day3 实现

        incoming.amount -= matched;
        head.amount -= matched;

        if (head.amount == 0) {
            uint256 nextHead = head.next;
            uint256 removedId = head.id;
            pendingOrderCount[head.trader]--;
            delete orders[bestSellId];
            bestSellId = nextHead;
            emit OrderRemoved(removedId);
        }
    }

    if (incoming.amount > 0) {
        _insertBuy(incoming, hintId);
        _checkWorstCaseMargin(incoming.trader); // Day2 可先实现成“结构化的骨架”
    }
}

    /// @notice 卖单撮合
   function _matchSell(Order memory incoming, uint256 hintId) internal virtual {
    while (incoming.amount > 0 && bestBuyId != 0) {
        Order storage head = orders[bestBuyId];
        if (incoming.price > head.price) break;

        uint256 matched = Math.min(incoming.amount, head.amount);
        _executeTrade(head.trader, incoming.trader, head.id, incoming.id, matched, head.price);

        incoming.amount -= matched;
        head.amount -= matched;

        if (head.amount == 0) {
            uint256 nextHead = head.next;
            uint256 removedId = head.id;
            pendingOrderCount[head.trader]--;
            delete orders[bestBuyId];
            bestBuyId = nextHead;
            emit OrderRemoved(removedId);
        }
    }

    if (incoming.amount > 0) {
        _insertSell(incoming, hintId);
        _checkWorstCaseMargin(incoming.trader);
    }
}

    /// @notice 插入买单到链表
    /// @dev Day 2: 维护价格优先级 (高价优先)
   function _insertBuy(Order memory incoming, uint256 hintId) internal virtual {
    (uint256 prevId, uint256 currentId) = _startFromHint(true, incoming.price, hintId);

    while (currentId != 0 && orders[currentId].price > incoming.price) {
        prevId = currentId;
        currentId = orders[currentId].next;
    }
    while (currentId != 0 && orders[currentId].price == incoming.price) {
        prevId = currentId;
        currentId = orders[currentId].next;
    }

    incoming.next = currentId;
    orders[incoming.id] = incoming;

    if (prevId == 0) bestBuyId = incoming.id;
    else orders[prevId].next = incoming.id;

    pendingOrderCount[incoming.trader]++;
}

    /// @notice 插入卖单到链表
    /// @dev Day 2: 维护价格优先级 (低价优先)
    function _insertSell(Order memory incoming, uint256 hintId) internal virtual {
    (uint256 prevId, uint256 currentId) = _startFromHint(false, incoming.price, hintId);

    while (currentId != 0 && orders[currentId].price < incoming.price) {
        prevId = currentId;
        currentId = orders[currentId].next;
    }
    while (currentId != 0 && orders[currentId].price == incoming.price) {
        prevId = currentId;
        currentId = orders[currentId].next;
    }

    incoming.next = currentId;
    orders[incoming.id] = incoming;

    if (prevId == 0) bestSellId = incoming.id;
    else orders[prevId].next = incoming.id;

    pendingOrderCount[incoming.trader]++;
}

    /// @notice 从 hint 位置开始遍历
    function _startFromHint(bool isBuy, uint256 price, uint256 hintId)
    internal
    view
    virtual
    returns (uint256 prev, uint256 curr)
{
    if (hintId == 0) {
        return (0, isBuy ? bestBuyId : bestSellId);
    }

    Order storage hint = orders[hintId];
    require(hint.id != 0, "invalid hint");

    if (isBuy) {
        require(price <= hint.price, "hint too deep");
        if (price == hint.price && hint.next != 0) {
            require(orders[hint.next].price != price, "hint not last");
        }
    } else {
        require(price >= hint.price, "hint too deep");
        if (price == hint.price && hint.next != 0) {
            require(orders[hint.next].price != price, "hint not last");
        }
    }

    return (hintId, hint.next);
}

    /// @notice 清算用户
    /// @dev Day 6: 强制平仓
    function liquidate(address trader, uint256 amount) external virtual nonReentrant {
        require(msg.sender != trader, "cannot self-liquidate");
        require(markPrice > 0, "mark price unset");

        _applyFunding(trader);
        require(canLiquidate(trader), "position healthy");

        // Remove pending orders so locked margin is freed
        _clearTraderOrders(trader);

        Position storage p = accounts[trader].position;
        uint256 sizeAbs = SignedMath.abs(p.size);
        uint256 liqAmount = amount == 0 ? sizeAbs : Math.min(amount, sizeAbs);

        // Perform market-close against existing liquidity
        if (p.size > 0) {
            Order memory closeOrder = Order(0, trader, false, 0, liqAmount, liqAmount, block.timestamp, 0);
            _matchLiquidationSell(closeOrder);
        } else {
            Order memory closeOrder = Order(0, trader, true, 0, liqAmount, liqAmount, block.timestamp, 0);
            _matchLiquidationBuy(closeOrder);
        }

        // Transfer liquidation fee to liquidator
        uint256 notional = (liqAmount * markPrice) / 1e18;
        uint256 fee = (notional * liquidationFeeBps) / 10_000;
        if (fee < minLiquidationFee) fee = minLiquidationFee;

        if (accounts[trader].margin >= fee) {
            accounts[trader].margin -= fee;
            accounts[msg.sender].margin += fee;
        } else {
            uint256 avail = accounts[trader].margin;
            accounts[trader].margin = 0;
            accounts[msg.sender].margin += avail;
        }

        emit Liquidated(trader, msg.sender, liqAmount, fee);

        // H-1 protection: if still unhealthy after partial fill, require full liquidation
        Position storage pAfter = accounts[trader].position;
        if (pAfter.size != 0) {
            require(!canLiquidate(trader), "must fully liquidate unhealthy position");
        }
    }

    /// @notice 清算卖单撮合 (市价)
    function _matchLiquidationSell(Order memory incoming) internal {
        while (incoming.amount > 0 && bestBuyId != 0) {
            Order storage head = orders[bestBuyId];

            uint256 matched = Math.min(incoming.amount, head.amount);
            _executeTrade(head.trader, incoming.trader, head.id, 0, matched, head.price);

            incoming.amount -= matched;
            head.amount -= matched;

            if (head.amount == 0) {
                uint256 nextHead = head.next;
                uint256 removedId = head.id;
                if (pendingOrderCount[head.trader] > 0) pendingOrderCount[head.trader]--;
                delete orders[bestBuyId];
                bestBuyId = nextHead;
                emit OrderRemoved(removedId);
            }
        }
    }

    /// @notice 清算买单撮合 (市价)
    function _matchLiquidationBuy(Order memory incoming) internal {
        while (incoming.amount > 0 && bestSellId != 0) {
            Order storage head = orders[bestSellId];

            uint256 matched = Math.min(incoming.amount, head.amount);
            _executeTrade(incoming.trader, head.trader, 0, head.id, matched, head.price);

            incoming.amount -= matched;
            head.amount -= matched;

            if (head.amount == 0) {
                uint256 nextHead = head.next;
                uint256 removedId = head.id;
                if (pendingOrderCount[head.trader] > 0) pendingOrderCount[head.trader]--;
                delete orders[bestSellId];
                bestSellId = nextHead;
                emit OrderRemoved(removedId);
            }
        }
    }
}
