import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Address, Hash, parseEther } from 'viem';
import { EXCHANGE_ABI } from '../onchain/abi';
import { EXCHANGE_ADDRESS, EXCHANGE_DEPLOY_BLOCK } from '../onchain/config';
import { chain, getWalletClient, publicClient, fallbackAccount } from '../onchain/client';
import { OrderBookItem, OrderSide, OrderType, PositionSnapshot, Trade } from '../types';

interface OrderStruct {
  id: bigint;
  trader: Address;
  isBuy: boolean;
  price: bigint;
  amount: bigint;
  initialAmount: bigint;
  timestamp: bigint;
  next: bigint;
}

interface OrderBookState {
  bids: OrderBookItem[];
  asks: OrderBookItem[];
}

interface OpenOrder {
  id: bigint;
  isBuy: boolean;
  price: bigint;
  amount: bigint;
  timestamp: bigint;
  trader: Address;
}

interface ExchangeContextValue {
  account?: Address;
  margin: bigint;
  position?: PositionSnapshot;
  markPrice: bigint;
  indexPrice: bigint;
  orderBook: OrderBookState;
  myOrders: OpenOrder[];
  trades: Trade[];
  syncing: boolean;
  error?: string;
  deposit: (amount: string) => Promise<void>;
  withdraw: (amount: string) => Promise<void>;
  placeOrder: (params: {
    side: OrderSide;
    orderType?: OrderType;
    price?: string;
    amount: string;
    hintId?: string;
  }) => Promise<void>;
  cancelOrder: (orderId: string) => Promise<void>;
  refresh: () => Promise<void>;
}

const ExchangeContext = createContext<ExchangeContextValue | undefined>(undefined);

function parseRaw(value: string): bigint {
  try {
    return parseEther(value);
  } catch {
    return 0n;
  }
}

/**
 * Exchange Provider - 脚手架版本
 * 
 * 这个 Provider 提供了与合约交互的接口，但实现为空。
 * 学生需要完成以下功能：
 * 
 * 1. deposit() - 调用合约的 deposit 函数
 * 2. withdraw() - 调用合约的 withdraw 函数
 * 3. placeOrder() - 调用合约的 placeOrder 函数
 * 4. cancelOrder() - 调用合约的 cancelOrder 函数
 * 5. 数据读取 - 从合约读取余额、持仓、订单簿等
 */
export function ExchangeProvider({ children }: { children: React.ReactNode }) {
  // ============================================
  // State - 这些状态用于 UI 显示
  // ============================================
  const [account, setAccount] = useState<Address | undefined>();
  const [margin, setMargin] = useState<bigint>(0n);
  const [position, setPosition] = useState<PositionSnapshot | undefined>();
  const [markPrice, setMarkPrice] = useState<bigint>(0n);
  const [indexPrice, setIndexPrice] = useState<bigint>(0n);
  const [orderBook, setOrderBook] = useState<OrderBookState>({ bids: [], asks: [] });
  const [myOrders, setMyOrders] = useState<OpenOrder[]>([]);
  const [trades, setTrades] = useState<Trade[]>([]);
  const [syncing, setSyncing] = useState(false);
  const [error, setError] = useState<string | undefined>();

  // ============================================
  // 合约交互函数
  // ============================================

  /**
   * 刷新余额数据
   */
  const refresh = useCallback(async () => {
    if (!EXCHANGE_ADDRESS || !account) return;
    setSyncing(true);
    try {
      const marginBal = await publicClient.readContract({
        address: EXCHANGE_ADDRESS,
        abi: EXCHANGE_ABI,
        functionName: 'margin' as const,
        args: [account],
      }) as bigint;
      setMargin(marginBal);
      setError(undefined);
    } catch (e: any) {
      console.error(e);
    } finally {
      setSyncing(false);
    }
  }, [account]);

  /**
   * 存入保证金
   */
  const deposit = useCallback(async (amount: string) => {
    try {
      const walletClient = await getWalletClient();
      if (!walletClient) throw new Error('No wallet connected');

      const hash = await walletClient.writeContract({
        address: EXCHANGE_ADDRESS!,
        abi: EXCHANGE_ABI,
        functionName: 'deposit',
        value: parseEther(amount),
        account: walletClient.account,
        chain: chain,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refresh();
    } catch (e: any) {
      setError(e.message || 'Deposit failed');
    }
  }, [refresh]);

  /**
   * 提取保证金
   */
  const withdraw = useCallback(async (amount: string) => {
    try {
      const walletClient = await getWalletClient();
      if (!walletClient) throw new Error('No wallet connected');

      const hash = await walletClient.writeContract({
        address: EXCHANGE_ADDRESS!,
        abi: EXCHANGE_ABI,
        functionName: 'withdraw',
        args: [parseEther(amount)],
        account: walletClient.account,
        chain: chain,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refresh();
    } catch (e: any) {
      setError(e.message || 'Withdraw failed');
    }
  }, [refresh]);

  /**
   * 下单
   * TODO: Day 2 实现
   */
  const placeOrder = useCallback(async (params: {
    side: OrderSide;
    orderType?: OrderType;
    price?: string;
    amount: string;
    hintId?: string;
  }) => {
    console.log('TODO: Implement placeOrder', params);
    setError('placeOrder 功能尚未实现，请完成 useExchange.tsx 中的 placeOrder 函数');
  }, []);

  /**
   * 取消订单
   * TODO: Day 2 实现
   */
  const cancelOrder = useCallback(async (orderId: string) => {
    console.log('TODO: Implement cancelOrder', orderId);
    setError('cancelOrder 功能尚未实现，请完成 useExchange.tsx 中的 cancelOrder 函数');
  }, []);

  // ============================================
  // 初始化和事件监听
  // ============================================

  useEffect(() => {
    // TODO: 获取当前账户地址
    // 可以使用 getWalletClient 或 fallbackAccount
    if (fallbackAccount) {
      setAccount(fallbackAccount.address);
    }

    // 初始刷新
    refresh();
  }, [refresh]);

  // ============================================
  // Context Value
  // ============================================
  const value: ExchangeContextValue = {
    account,
    margin,
    position,
    markPrice,
    indexPrice,
    orderBook,
    myOrders,
    trades,
    syncing,
    error,
    deposit,
    withdraw,
    placeOrder,
    cancelOrder,
    refresh,
  };

  return (
    <ExchangeContext.Provider value={value}>
      {children}
    </ExchangeContext.Provider>
  );
}

export function useExchange() {
  const context = useContext(ExchangeContext);
  if (!context) {
    throw new Error('useExchange must be used within ExchangeProvider');
  }
  return context;
}
