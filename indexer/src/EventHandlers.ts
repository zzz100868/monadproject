import {
    Exchange,
    Trade,
    Candle,
    Order,
    Position,
    MarginEvent,
    Liquidation,
    LatestCandle,
    FundingEvent
} from "../generated";

const toLower = (addr: string) => addr.toLowerCase();
const toBigInt = (v: bigint | number) => (typeof v === "bigint" ? v : BigInt(v));
const toUnixSeconds = (v: bigint | number) => Number(toBigInt(v));
const abs = (v: bigint) => (v < 0n ? -v : v);
Exchange.FundingUpdated.handler(async ({ event, context }) => {
    const entity: FundingEvent = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        eventType: "GLOBAL_UPDATE",
        trader: undefined,
        cumulativeRate: (event.params as any).cumulativeFundingRate ?? undefined,
        payment: undefined,
        timestamp: event.block.timestamp,
    };
    context.FundingEvent.set(entity);
});

Exchange.FundingPaid.handler(async ({ event, context }) => {
    const trader = (event.params as any).trader ? toLower((event.params as any).trader) : undefined;
    const payment = (event.params as any).payment ?? undefined;
    const cumulativeRate = (event.params as any).cumulativeFundingRate ?? undefined;

    const entity: FundingEvent = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        eventType: "USER_PAID",
        trader,
        cumulativeRate,
        payment,
        timestamp: event.block.timestamp,
    };
    context.FundingEvent.set(entity);
});

Exchange.MarginDeposited.handler(async ({ event, context }) => {
    const entity: MarginEvent = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        trader: toLower(event.params.trader),
        amount: event.params.amount,
        eventType: "DEPOSIT",
        timestamp: toUnixSeconds(event.block.timestamp),
        txHash: event.transaction.hash,
    };
    context.MarginEvent.set(entity);
});

Exchange.MarginWithdrawn.handler(async ({ event, context }) => {
    const entity: MarginEvent = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        trader: toLower(event.params.trader),
        amount: event.params.amount,
        eventType: "WITHDRAW",
        timestamp: toUnixSeconds(event.block.timestamp),
        txHash: event.transaction.hash,
    };
    context.MarginEvent.set(entity);
});





Exchange.TradeExecuted.handler(async ({ event, context }) => {
    const timestamp = toUnixSeconds(event.block.timestamp);
    const tradeAmount = event.params.amount;

    const trade: Trade = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        price: event.params.price,
        amount: tradeAmount,
        buyer: toLower(event.params.buyer),
        seller: toLower(event.params.seller),
        buyOrderId: event.params.buyOrderId,
        sellOrderId: event.params.sellOrderId,
        timestamp,
        txHash: event.transaction.hash,
    };
    context.Trade.set(trade);

    const buyOrder = await context.Order.get(trade.buyOrderId.toString());
    if (buyOrder) {
        const remaining = buyOrder.amount - tradeAmount;
        context.Order.set({
            ...buyOrder,
            amount: remaining > 0n ? remaining : 0n,
            status: remaining > 0n ? "PARTIAL" : "FILLED",
            timestamp,
        });
    }

    const sellOrder = await context.Order.get(trade.sellOrderId.toString());
    if (sellOrder) {
        const remaining = sellOrder.amount - tradeAmount;
        context.Order.set({
            ...sellOrder,
            amount: remaining > 0n ? remaining : 0n,
            status: remaining > 0n ? "PARTIAL" : "FILLED",
            timestamp,
        });
    }

    // 1m candle aggregation
    const blockTs = toBigInt(event.block.timestamp);
    const minuteTs = blockTs - (blockTs % 60n);
    const candleId = `1m-${minuteTs}`;
    const existingCandle = await context.Candle.get(candleId);

    if (!existingCandle) {
        const latest: LatestCandle | undefined = await context.LatestCandle.get("1");
        const openPrice = latest ? latest.closePrice : event.params.price;

        const candle: Candle = {
            id: candleId,
            resolution: "1m",
            timestamp: Number(minuteTs),
            openPrice,
            highPrice: event.params.price > openPrice ? event.params.price : openPrice,
            lowPrice: event.params.price < openPrice ? event.params.price : openPrice,
            closePrice: event.params.price,
            volume: tradeAmount,
        };
        context.Candle.set(candle);
    } else {
        const newHigh = event.params.price > existingCandle.highPrice ? event.params.price : existingCandle.highPrice;
        const newLow = event.params.price < existingCandle.lowPrice ? event.params.price : existingCandle.lowPrice;

        context.Candle.set({
            ...existingCandle,
            highPrice: newHigh,
            lowPrice: newLow,
            closePrice: event.params.price,
            volume: existingCandle.volume + tradeAmount,
        });
    }

    context.LatestCandle.set({
        id: "1",
        closePrice: event.params.price,
        timestamp,
    });

    await updatePosition(context, trade.buyer, true, tradeAmount, event.params.price, timestamp);
    await updatePosition(context, trade.seller, false, tradeAmount, event.params.price, timestamp);
});

async function updatePosition(
    context: any,
    trader: string,
    isBuy: boolean,
    amount: bigint,
    price: bigint,
    timestamp: number,
) {
    const existing: Position | undefined = await context.Position.get(trader);
    const prevSize = existing?.size ?? 0n;
    const prevEntry = existing?.entryPrice ?? 0n;

    const delta = isBuy ? amount : -amount;
    const newSize = prevSize + delta;

    let newEntry = prevEntry;
    const increasing = prevSize === 0n || (prevSize > 0n && delta > 0n) || (prevSize < 0n && delta < 0n);

    if (increasing) {
        const totalAbs = abs(prevSize) + amount;
        const weightedCost = abs(prevSize) * prevEntry + amount * price;
        newEntry = totalAbs > 0n ? weightedCost / totalAbs : price;
    } else if (newSize === 0n) {
        newEntry = 0n;
    } else if ((prevSize > 0n && newSize < 0n) || (prevSize < 0n && newSize > 0n)) {
        newEntry = price;
    } else {
        newEntry = prevEntry;
    }

    const position: Position = {
        id: trader,
        trader,
        size: newSize,
        entryPrice: newEntry,
    };
    context.Position.set(position);
}
Exchange.OrderPlaced.handler(async ({ event, context }) => {
    const order: Order = {
        id: event.params.id.toString(),
        trader: event.params.trader,
        isBuy: event.params.isBuy,
        price: event.params.price,
        initialAmount: event.params.amount,
        amount: event.params.amount,
        status: "OPEN",
        timestamp: event.block.timestamp,
    };
    context.Order.set(order);
});

Exchange.OrderRemoved.handler(async ({ event, context }) => {
    const order = await context.Order.get(event.params.id.toString());
    if (order) {
        context.Order.set({
            ...order,
            status: order.amount === 0n ? "FILLED" : "CANCELLED",
            amount: 0n, // 清零以便 GET_OPEN_ORDERS 过滤
        });
    }
});
Exchange.PositionUpdated.handler(async ({ event, context }) => {
    const position: Position = {
        id: toLower(event.params.trader),
        trader: toLower(event.params.trader),
        size: event.params.size,
        entryPrice: event.params.entryPrice,
    };
    context.Position.set(position);
});
Exchange.Liquidated.handler(async ({ event, context }) => {
    const trader = toLower(event.params.trader);
    const liquidator = toLower(event.params.liquidator);

    const entity: Liquidation = {
        id: `${event.transaction.hash}-${event.logIndex}`,
        trader,
        liquidator,
        amount: event.params.amount,
        fee: event.params.reward,
        timestamp: toUnixSeconds(event.block.timestamp),
        txHash: event.transaction.hash,
    };
    context.Liquidation.set(entity);

    // 清算后持仓应该归零或减少
    const position = await context.Position.get(trader);
    if (position) {
        const newSize = position.size > 0n
            ? position.size - event.params.amount
            : position.size + event.params.amount;
        context.Position.set({
            ...position,
            size: newSize,
        });
    }
});