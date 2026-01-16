// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "./PricingModule.sol";

/// @notice Liquidation checks and execution.
/// @dev Day 6: 清算模块
abstract contract LiquidationModule is PricingModule {

    /// @notice 检查用户是否可被清算
    /// @param trader 用户地址
    /// @return 是否可清算
    function canLiquidate(address trader) public view virtual returns (bool) {
        // TODO: 请实现此函数
        // 步骤:
        // 1. 获取用户持仓，如果为 0 返回 false
        // 2. 计算当前标记价下的未实现盈亏
        // 3. 计算 marginBalance = margin + unrealizedPnl
        // 4. 计算 maintenance = positionValue * (maintenanceMarginBps + liquidationFeeBps) / 10000
        // 5. 返回 marginBalance < maintenance
        return false;
    }

    /// @notice 清算用户 (在 OrderBookModule 中实现具体逻辑)
    function liquidate(address trader) external virtual nonReentrant {
        // 将在 OrderBookModule 中实现
    }

    /// @notice 清除用户所有挂单
    /// @param trader 用户地址
    function _clearTraderOrders(address trader) internal returns (uint256 freedLocked) {
        // TODO: 请实现此函数
        // 步骤:
        // 1. 遍历买单链表，删除该用户的订单
        // 2. 遍历卖单链表，删除该用户的订单
        // 3. 触发 OrderRemoved 事件
        return 0;
    }

    /// @notice 从链表中删除指定用户的订单
    function _removeOrders(uint256 headId, address trader) internal returns (uint256 newHead) {
        // TODO: 请实现此函数
        return headId;
    }

    uint256 constant SCALE = 1e18;

    /// @notice 执行交易
    /// @dev Day 3: 撮合成交核心函数
   function _executeTrade(
    address buyer,
    address seller,
    uint256 buyOrderId,
    uint256 sellOrderId,
    uint256 amount,
    uint256 price
) internal virtual {
    _applyFunding(buyer);
    _applyFunding(seller);

    _updatePosition(buyer, true, amount, price);
    _updatePosition(seller, false, amount, price);

    emit TradeExecuted(buyOrderId, sellOrderId, price, amount, buyer, seller);
}

    /// @notice 更新用户持仓
    /// @dev Day 3: 持仓更新核心函数
    function _updatePosition(
    address trader,
    bool isBuy,
    uint256 amount,
    uint256 tradePrice
) internal virtual {
    Position storage p = accounts[trader].position;
    int256 signed = isBuy ? int256(amount) : -int256(amount);
    uint256 existingAbs = SignedMath.abs(p.size);

    // 1) 同方向加仓
    if (p.size == 0 || (p.size > 0) == (signed > 0)) {
        uint256 newAbs = existingAbs + amount;
        uint256 weighted = existingAbs == 0
            ? tradePrice
            : (existingAbs * p.entryPrice + amount * tradePrice) / newAbs;
        p.entryPrice = weighted;
        p.size += signed;
        emit PositionUpdated(trader, p.size, p.entryPrice);
        return;
    }

    // 2) 反向减仓/平仓
    uint256 closing = amount < existingAbs ? amount : existingAbs;
    int256 pnlPerUnit = p.size > 0
        ? int256(tradePrice) - int256(p.entryPrice)
        : int256(p.entryPrice) - int256(tradePrice);
    int256 pnl = (pnlPerUnit * int256(closing)) / int256(SCALE);

    // 盈亏直接结算到 margin（无需单独记录 realizedPnl）
    int256 newMargin = int256(accounts[trader].margin) + pnl;
    if (newMargin < 0) accounts[trader].margin = 0;
    else accounts[trader].margin = uint256(newMargin);

    // 3) 是否反向开仓
    uint256 remaining = amount - closing;
    if (closing == existingAbs) {
        if (remaining == 0) {
            p.size = 0;
            p.entryPrice = tradePrice;
        } else {
            p.size = signed > 0 ? int256(remaining) : -int256(remaining);
            p.entryPrice = tradePrice;
        }
    } else {
        if (p.size > 0) p.size -= int256(closing);
        else p.size += int256(closing);
    }
    
    // Day 5 优化：发出 PositionUpdated 事件，简化 Indexer 逻辑
    emit PositionUpdated(trader, p.size, p.entryPrice);
}
}
