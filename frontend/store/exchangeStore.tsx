import React, { createContext, useContext, useEffect } from 'react';
import { makeAutoObservable, runInAction } from 'mobx';
import { Address, Hash, parseAbiItem, parseEther, formatEther } from 'viem';
import { EXCHANGE_ABI } from '../onchain/abi';
import { EXCHANGE_ADDRESS, EXCHANGE_DEPLOY_BLOCK } from '../onchain/config';
import { chain, getWalletClient, publicClient, fallbackAccount, ACCOUNTS } from '../onchain/client';
import { OrderBookItem, OrderSide, OrderType, PositionSnapshot, Trade, CandleData } from '../types';
import { client, GET_CANDLES, GET_RECENT_TRADES, GET_POSITIONS, GET_OPEN_ORDERS } from './IndexerClient';

type OrderStruct = {
  id: bigint;
  trader: Address;
  isBuy: boolean;
  price: bigint;
  amount: bigint;
  initialAmount: bigint;
  timestamp: bigint;
  next: bigint;
};

type OrderBookState = {
  bids: OrderBookItem[];
  asks: OrderBookItem[];
};

export type OpenOrder = {
  id: bigint;
  isBuy: boolean;
  price: bigint;
  amount: bigint;
  initialAmount: bigint;
  timestamp: bigint;
  trader: Address;
};

class ExchangeStore {
  account?: Address;
  accountIndex = 0; // New observable state
  margin = 0n;

  position?: PositionSnapshot;
  markPrice = 0n;
  indexPrice = 0n;
  initialMarginBps = 100n; // Default 1%
  fundingRate = 0; // Estimated hourly funding rate
  orderBook: OrderBookState = { bids: [], asks: [] };
  trades: Trade[] = [];
  candles: CandleData[] = [];
  myOrders: OpenOrder[] = [];
  syncing = false;
  error?: string;
  walletClient = getWalletClient();

  constructor() {
    makeAutoObservable(this);
    this.autoConnect();
    this.refresh();
    // 定时刷新
    setInterval(() => {
      this.refresh().catch(() => { });
    }, 4000);
    console.info('[store] 交易所 store 初始化完成');
  }

  ensureContract() {
    if (!EXCHANGE_ADDRESS) throw new Error('Set VITE_EXCHANGE_ADDRESS');
    return EXCHANGE_ADDRESS;
  }

  autoConnect = async () => {
    // Check URL params first
    const params = new URLSearchParams(window.location.search);
    const urlAccount = params.get('account');
    if (urlAccount && urlAccount.startsWith('0x')) {
      runInAction(() => (this.account = urlAccount as Address));
      return;
    }

    if (fallbackAccount) {
      runInAction(() => (this.account = fallbackAccount.address));
      return;
    }
    if (!this.walletClient || !('getAddresses' in this.walletClient)) return;
    try {
      const addrs = await (this.walletClient as any).getAddresses();
      if (addrs.length > 0) {
        runInAction(() => (this.account = addrs[0]));
      }
    } catch {
      /* ignore */
    }
  };

  connectWallet = async () => {
    if (!this.walletClient) {
      runInAction(() => (this.error = 'No wallet configured'));
      return;
    }
    if ('requestAddresses' in this.walletClient) {
      const [addr] = await (this.walletClient as any).requestAddresses();
      runInAction(() => (this.account = addr));
    } else if ('getAddresses' in this.walletClient) {
      const addrs = await (this.walletClient as any).getAddresses();
      if (addrs.length > 0) runInAction(() => (this.account = addrs[0]));
    } else if ((this.walletClient as any).account?.address) {
      runInAction(() => (this.account = (this.walletClient as any).account.address));
    } else if (fallbackAccount) {
      runInAction(() => (this.account = fallbackAccount.address));
    }
  };

  switchAccount = () => {
    this.accountIndex = (this.accountIndex + 1) % ACCOUNTS.length;
    const newAccount = ACCOUNTS[this.accountIndex];
    this.walletClient = getWalletClient(newAccount);
    runInAction(() => {
      this.account = newAccount.address;
      this.refresh();
    });
  };

  mapOrder(data: any): OrderStruct {
    // 优先检查命名属性（viem 通常返回带命名属性的数组）
    if (data && typeof data.price !== 'undefined') {
      return {
        id: data.id,
        trader: data.trader,
        isBuy: data.isBuy,
        price: data.price,
        amount: data.amount,
        initialAmount: data.initialAmount,
        timestamp: data.timestamp,
        next: data.next,
      };
    }

    if (Array.isArray(data)) {
      return {
        id: data[0],
        trader: data[1],
        isBuy: data[2],
        price: data[3],
        amount: data[4],
        initialAmount: data[5],
        timestamp: data[6],
        next: data[7],
      };
    }
    return data as OrderStruct;
  }

  loadOrderChain = async (headId?: bigint | null) => {
    const head: OrderStruct[] = [];
    if (!headId || headId === 0n) return head;
    const visited = new Set<string>();
    let current: bigint | undefined | null = headId;
    for (let i = 0; i < 128 && typeof current === 'bigint' && current !== 0n; i++) {
      if (visited.has(current.toString())) break;
      visited.add(current.toString());
      const raw = await publicClient.readContract({
        abi: EXCHANGE_ABI,
        address: this.ensureContract(),
        functionName: 'orders',
        args: [current],
      } as any);
      const data = this.mapOrder(raw);
      if (data.id === 0n) break;
      head.push(data);
      current = data.next;
    }
    return head;
  };

  formatOrderBook = (orders: OrderStruct[], isBuy: boolean): OrderBookItem[] => {
    // 1. Filter valid orders
    const filtered = orders.filter((o) => o.isBuy === isBuy && o.amount > 0n);

    // 2. Aggregate by price
    const aggregated = new Map<number, number>();
    filtered.forEach((o) => {
      const price = Number(formatEther(o.price));
      const size = Number(formatEther(o.amount));
      aggregated.set(price, (aggregated.get(price) || 0) + size);
    });

    // 3. Convert to array
    const rows = Array.from(aggregated.entries()).map(([price, size]) => ({
      price,
      size,
      total: 0,
      depth: 0,
    }));

    // 4. Sort: Bids Descending / Asks Ascending
    rows.sort((a, b) => (isBuy ? b.price - a.price : a.price - b.price));

    // 5. Calculate cumulative total
    let running = 0;
    const result = rows.map((r) => {
      running += r.size;
      return { ...r, total: running };
    });

    // 6. Calculate relative depth
    const maxTotal = result.length > 0 ? result[result.length - 1].total : 0;
    return result.map((r) => ({
      ...r,
      depth: maxTotal > 0 ? Math.min(100, Math.round((r.total / maxTotal) * 100)) : 0,
    }));
  };

  loadCandles = async () => {
    try {
      const result = await client.query(GET_CANDLES, {}).toPromise();
      if (result.data?.Candle) {
        const candles = result.data.Candle.map((c: any) => ({
          time: new Date(c.timestamp * 1000).toISOString(), // or format as needed
          open: Number(formatEther(c.openPrice)),
          high: Number(formatEther(c.highPrice)),
          low: Number(formatEther(c.lowPrice)),
          close: Number(formatEther(c.closePrice)),
          volume: Number(formatEther(c.volume)),
        }));
        runInAction(() => {
          this.candles = candles;
        });
      }
    } catch (e) {
      console.error('[store] loadCandles failed', e);
    }
  };

  loadTrades = async (viewer?: Address): Promise<Trade[]> => {
    try {
      const result = await client.query(GET_RECENT_TRADES, {}).toPromise();
      if (!result.data?.Trade) return [];

      return result.data.Trade.map((t: any) => {
        // 根据 Taker（发起交易的一方）确定方向
        // Taker 的订单 ID 总是更大
        // 如果 buyOrderId > sellOrderId，Taker 是买方 -> 方向是买（绿色）
        // 如果 sellOrderId > buyOrderId，Taker 是卖方 -> 方向是卖（红色）
        const buyId = BigInt(t.buyOrderId || 0);
        const sellId = BigInt(t.sellOrderId || 0);
        const side = buyId > sellId ? 'buy' : 'sell';

        return {
          id: t.id,
          price: Number(formatEther(t.price)),
          amount: Number(formatEther(t.amount)),
          time: new Date(t.timestamp * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
          side,
          buyer: t.buyer,
          seller: t.seller,
          txHash: t.txHash,
        };
      });
    } catch (e) {
      console.error('[store] loadTrades failed', e);
      return [];
    }
  };

  refresh = async () => {
    try {
      runInAction(() => {
        this.syncing = true;
        this.error = undefined;
      });
      const address = this.ensureContract();
      const [mark, index, bestBid, bestAsk, imBps] = await Promise.all([
        publicClient.readContract({ abi: EXCHANGE_ABI, address, functionName: 'markPrice' } as any) as Promise<bigint>,
        publicClient.readContract({ abi: EXCHANGE_ABI, address, functionName: 'indexPrice' } as any) as Promise<bigint>,
        publicClient.readContract({ abi: EXCHANGE_ABI, address, functionName: 'bestBuyId' } as any) as Promise<bigint>,
        publicClient.readContract({ abi: EXCHANGE_ABI, address, functionName: 'bestSellId' } as any) as Promise<bigint>,
        publicClient.readContract({ abi: EXCHANGE_ABI, address, functionName: 'initialMarginBps' } as any) as Promise<bigint>,
      ]);
      console.debug('[orderbook] head ids', {
        bestBid: bestBid?.toString?.(),
        bestAsk: bestAsk?.toString?.(),
        address,
      });
      runInAction(() => {
        this.markPrice = mark;
        this.indexPrice = index;
        this.initialMarginBps = imBps;
        // 使用币安公式计算预估资金费率
        // F = P + clamp(I - P, 0.05%, -0.05%)
        if (index > 0n) {
          const m = Number(formatEther(mark));
          const i = Number(formatEther(index));
          const premiumIndex = (m - i) / i;
          const interestRate = 0.0001; // 0.01%
          const clampRange = 0.0005;   // 0.05%

          let diff = interestRate - premiumIndex;
          if (diff > clampRange) diff = clampRange;
          if (diff < -clampRange) diff = -clampRange;

          this.fundingRate = premiumIndex + diff;
        } else {
          this.fundingRate = 0;
        }
      });

      if (this.account) {
        const m = await publicClient.readContract({
          abi: EXCHANGE_ABI,
          address,
          functionName: 'margin',
          args: [this.account],
        } as any) as bigint;

        // 从 Indexer 获取持仓
        let pos: PositionSnapshot = { size: 0n, entryPrice: 0n, realizedPnl: 0n };
        try {
          const posResult = await client.query(GET_POSITIONS, { trader: this.account.toLowerCase() }).toPromise();
          if (posResult.data?.Position?.[0]) {
            const p = posResult.data.Position[0];
            pos = {
              size: BigInt(p.size),
              entryPrice: BigInt(p.entryPrice),
              realizedPnl: BigInt(p.realizedPnl),
            };
          }
        } catch (e) {
          console.error('[store] failed to fetch position from indexer', e);
        }

        runInAction(() => {
          this.margin = m;
          this.position = pos;
        });
      }

      let bidsRaw: OrderStruct[] = [];
      let asksRaw: OrderStruct[] = [];
      try {
        [bidsRaw, asksRaw] = await Promise.all([this.loadOrderChain(bestBid), this.loadOrderChain(bestAsk)]);
      } catch (inner) {
        const msg = (inner as Error)?.message || 'Failed to load orderbook';
        console.error('[orderbook] loadOrderChain error', msg);
        runInAction(() => (this.error = msg));
      }

      const scanned: OrderStruct[] = [];
      const SCAN_LIMIT = 20;
      for (let i = 1; i <= SCAN_LIMIT; i++) {
        try {
          const id = BigInt(i);
          const raw = await publicClient.readContract({
            abi: EXCHANGE_ABI,
            address,
            functionName: 'orders',
            args: [id],
          } as any);
          const data = this.mapOrder(raw);
          console.debug('[orderbook] slot', i, data);
          if (data.id !== 0n) scanned.push(data);
        } catch (inner) {
          console.error('[orderbook] scan error', i.toString(), (inner as Error)?.message);
          break;
        }
      }
      console.debug(
        '[orderbook] scanned raw',
        scanned.map((o) => ({
          id: o.id.toString(),
          p: o.price.toString(),
          a: o.amount.toString(),
          isBuy: o.isBuy,
          next: o.next.toString(),
        })),
      );
      const merged = new Map<bigint, OrderStruct>();
      [...bidsRaw, ...asksRaw, ...scanned].forEach((o) => {
        if (o && o.id) merged.set(o.id, o);
      });
      const allOrders = Array.from(merged.values());
      const bids = allOrders.filter((o) => o.isBuy && o.amount > 0n);
      const asks = allOrders.filter((o) => !o.isBuy && o.amount > 0n);
      console.debug('[orderbook] bids/asks', {
        bids: bids.map((o) => ({ id: o.id.toString(), p: o.price.toString(), a: o.amount.toString() })),
        asks: asks.map((o) => ({ id: o.id.toString(), p: o.price.toString(), a: o.amount.toString() })),
        merged: merged.size,
      });
      runInAction(() => {
        this.orderBook = { bids: this.formatOrderBook(bids, true), asks: this.formatOrderBook(asks, false) };
      });

      try {
        const trades = await this.loadTrades(this.account);
        runInAction(() => {
          this.trades = trades;
        });
      } catch (e) {
        console.error('[store] loadTrades failed', e);
      }

      // Load Candles
      this.loadCandles();

      if (this.account) {
        try {
          const ordersResult = await client.query(GET_OPEN_ORDERS, { trader: this.account.toLowerCase() }).toPromise();
          if (ordersResult.data?.Order) {
            const mine = ordersResult.data.Order.map((o: any) => ({
              id: BigInt(o.id),
              isBuy: o.isBuy,
              price: BigInt(o.price),
              amount: BigInt(o.amount),
              initialAmount: BigInt(o.initialAmount || o.amount), // Fallback if missing
              timestamp: BigInt(o.timestamp),
              trader: o.trader as Address,
            }));
            runInAction(() => {
              this.myOrders = mine;
            });
          }
        } catch (e) {
          console.error('[store] failed to fetch open orders from indexer', e);
        }
      } else {
        runInAction(() => {
          this.myOrders = [];
        });
      }
    } catch (e) {
      runInAction(() => (this.error = (e as Error)?.message || 'Failed to sync exchange data'));
    } finally {
      runInAction(() => (this.syncing = false));
    }
  };

  deposit = async (ethAmount: string) => {
    if (!this.walletClient || !this.account) throw new Error('Connect wallet before depositing');
    const value = parseEther(ethAmount || '0');
    const hash = await this.walletClient.writeContract({
      account: this.account,
      address: this.ensureContract(),
      abi: EXCHANGE_ABI,
      functionName: 'deposit',
      value: parseEther(ethAmount),
      chain: undefined,
    } as any);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Transaction failed');
    await this.refresh();
  };

  withdraw = async (amount: string) => {
    if (!this.walletClient || !this.account) throw new Error('Connect wallet before withdrawing');
    const parsed = parseEther(amount || '0');
    const hash = await this.walletClient.writeContract({
      account: this.account,
      address: this.ensureContract(),
      abi: EXCHANGE_ABI,
      functionName: 'withdraw',
      args: [parseEther(amount)],
      chain: undefined,
    } as any);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Transaction failed');
    await this.refresh();
  };

  placeOrder = async (params: { side: OrderSide; orderType?: OrderType; price?: string; amount: string; hintId?: string }) => {
    const { side, orderType = OrderType.LIMIT, price, amount, hintId } = params;
    if (!this.walletClient || !this.account) throw new Error('Connect wallet before placing orders');
    const currentPrice = this.markPrice > 0n ? this.markPrice : parseEther('1500'); // Default to 1500 if no mark
    const parsedPrice = price ? parseEther(price) : currentPrice;
    const effectivePrice =
      orderType === OrderType.MARKET
        ? side === OrderSide.BUY
          ? currentPrice + parseEther('100') // Aggressive slippage for market buy
          : currentPrice - parseEther('100') > 0n ? currentPrice - parseEther('100') : 1n
        : parsedPrice;
    const parsedAmount = parseEther(amount);
    const parsedHint = hintId ? BigInt(hintId) : 0n;
    const hash = await this.walletClient.writeContract({
      account: this.account,
      address: this.ensureContract(),
      abi: EXCHANGE_ABI,
      functionName: 'placeOrder',
      args: [side === OrderSide.BUY, effectivePrice, parsedAmount, parsedHint],
      chain: undefined,
    } as any);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Transaction failed');
    await this.refresh();
  }

  cancelOrder = async (orderId: bigint) => {
    if (!this.walletClient || !this.account) throw new Error('Connect wallet before cancelling orders');
    const hash = await this.walletClient.writeContract({
      account: this.account,
      address: this.ensureContract(),
      abi: EXCHANGE_ABI,
      functionName: 'cancelOrder',
      args: [orderId],
      chain: undefined,
    } as any);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Transaction failed');
    await this.refresh();
  }
}

const ExchangeStoreContext = createContext<ExchangeStore | null>(null);

export const ExchangeStoreProvider: React.FC<React.PropsWithChildren> = ({ children }) => {
  const storeRef = React.useRef<ExchangeStore>();
  if (!storeRef.current) {
    storeRef.current = new ExchangeStore();
  }
  useEffect(() => {
    // ensure initial refresh
    storeRef.current?.refresh().catch(() => { });
  }, []);
  return <ExchangeStoreContext.Provider value={storeRef.current}>{children}</ExchangeStoreContext.Provider>;
};

export const useExchangeStore = () => {
  const ctx = useContext(ExchangeStoreContext);
  if (!ctx) throw new Error('useExchangeStore must be used within ExchangeStoreProvider');
  return ctx;
};
