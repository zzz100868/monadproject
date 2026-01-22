# 多交易对功能实现文档

本文档详细说明了为 Perpetual DEX 项目添加多交易对（ETH/USD、SOL/USD、BTC/USD）支持所做的所有修改。

---

## 目录

1. [架构概述](#架构概述)
2. [前端修改](#前端修改)
3. [后端/索引器修改](#后端索引器修改)
4. [部署脚本修改](#部署脚本修改)
5. [测试新增](#测试新增)
6. [数据流程图](#数据流程图)
7. [如何新增交易对](#如何新增交易对)

---

## 架构概述

### 设计决策

采用 **多合约架构**：每个交易对部署一个独立的 `MonadPerpExchange` 合约。

```
┌─────────────────────────────────────────────────────────────┐
│                        前端 (Frontend)                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │  ETH/USD    │  │  SOL/USD    │  │  BTC/USD    │          │
│  │  Contract   │  │  Contract   │  │  Contract   │          │
│  │  0x60f0...  │  │  0xc0cb...  │  │  0xaf7a...  │          │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
│         └────────────────┴────────────────┘                  │
│                          │                                   │
│                    activeMarket                              │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                      索引器 (Indexer)                        │
│                                                              │
│   监听所有3个合约地址 → 根据srcAddress派生marketId           │
│   所有实体增加 marketId 字段用于区分市场                      │
└─────────────────────────────────────────────────────────────┘
```

### 优势

- **市场隔离**：各市场保证金、仓位、订单完全独立
- **风险隔离**：一个市场的清算不影响其他市场
- **可扩展性**：新增市场只需部署新合约

---

## 前端修改

### 1. 市场定义文件 (新增)

**文件**: `frontend/markets.ts`

```typescript
export interface Market {
    id: string;           // e.g., "ETH-USD"
    symbol: string;       // e.g., "ETH/USD"
    baseAsset: string;    // e.g., "ETH"
    quoteAsset: string;   // e.g., "USD"
    icon: string;         // Emoji 图标
    decimals: number;     // 价格小数位
    envKey: string;       // 环境变量键名
}

export const MARKETS: Market[] = [
    { id: 'ETH-USD', symbol: 'ETH/USD', baseAsset: 'ETH', quoteAsset: 'USD', icon: '⟠', decimals: 2, envKey: 'VITE_EXCHANGE_ADDRESS_ETH' },
    { id: 'SOL-USD', symbol: 'SOL/USD', baseAsset: 'SOL', quoteAsset: 'USD', icon: '◎', decimals: 4, envKey: 'VITE_EXCHANGE_ADDRESS_SOL' },
    { id: 'BTC-USD', symbol: 'BTC/USD', baseAsset: 'BTC', quoteAsset: 'USD', icon: '₿', decimals: 2, envKey: 'VITE_EXCHANGE_ADDRESS_BTC' },
];

// 根据市场获取合约地址
export const getMarketContractAddress = (market: Market): string => {
    const env = (import.meta as any).env || {};
    return env[market.envKey] || env.VITE_EXCHANGE_ADDRESS || '';
};
```

### 2. 状态管理修改

**文件**: `frontend/store/exchangeStore.tsx`

新增内容：
```typescript
import { MARKETS, DEFAULT_MARKET, Market, getMarketContractAddress } from '../markets';

class ExchangeStore {
    // 新增：当前激活的市场
    activeMarket: Market = DEFAULT_MARKET;
    
    // 新增：切换市场
    setActiveMarket = (market: Market) => {
        this.activeMarket = market;
        this.contract = null; // 重置合约实例
        // 重新加载数据...
    };
    
    // 修改：动态获取合约地址
    ensureContract() {
        const address = getMarketContractAddress(this.activeMarket);
        // 使用动态地址创建合约实例
    }
    
    // 修改：加载 K 线时传入 marketId
    loadCandles = async () => {
        const result = await client.query(GET_CANDLES, { 
            marketId: this.activeMarket.id  // 新增参数
        }).toPromise();
    };
}
```

### 3. GraphQL 查询修改

**文件**: `frontend/store/IndexerClient.ts`

```typescript
// 修改前
export const GET_CANDLES = `
  query GetCandles {
    Candle(order_by: { timestamp: desc }, limit: 100) { ... }
  }
`;

// 修改后
export const GET_CANDLES = `
  query GetCandles($marketId: String!) {
    Candle(where: { marketId: { _eq: $marketId } }, order_by: { timestamp: desc }, limit: 100) { ... }
  }
`;
```

### 4. UI 组件修改

**文件**: `frontend/components/Header.tsx`

新增市场选择器下拉菜单：
```tsx
<select onChange={(e) => store.setActiveMarket(MARKETS.find(m => m.id === e.target.value))}>
    {MARKETS.map(market => (
        <option key={market.id} value={market.id}>
            {market.icon} {market.symbol}
        </option>
    ))}
</select>
```

**文件**: `frontend/components/TradingChart.tsx`

```tsx
// 修改前
<div>ETH/USD</div>

// 修改后
<div>{store.activeMarket.symbol}</div>
```

**文件**: `frontend/components/OrderForm.tsx`

```tsx
// 修改前
<label>Amount (ETH)</label>

// 修改后
<label>Amount ({store.activeMarket.baseAsset})</label>
```

**文件**: `frontend/components/Positions.tsx`

```tsx
// 动态显示仓位的基础资产符号
<td>{store.activeMarket.baseAsset}</td>
```

### 5. Order ID 解析修复

**文件**: `frontend/store/exchangeStore.tsx`

```typescript
// 修改前 (导致错误 "Cannot convert ETH-USD-9 to a BigInt")
id: BigInt(o.id)

// 修改后
const numericId = String(o.id).split('-').pop() || '0';
id: BigInt(numericId)
```

---

## 后端/索引器修改

### 1. Schema 修改

**文件**: `indexer/schema.graphql`

为所有实体添加 `marketId` 字段：

```graphql
type Order {
  id: ID!
  marketId: String!  # 新增
  trader: String!
  # ...
}

type Trade {
  id: ID!
  marketId: String!  # 新增
  price: BigInt!
  # ...
}

type Candle {
  id: ID!
  marketId: String!  # 新增
  timestamp: Int!
  # ...
}

type Position {
  id: ID!
  marketId: String!  # 新增
  trader: String!
  # ...
}
```

### 2. 市场地址映射 (自动生成)

**文件**: `indexer/src/marketAddresses.ts`

```typescript
// 由部署脚本自动生成
export const MARKET_ADDRESS_MAP: Record<string, string> = {
  '0x60f02157159b12bae61f2adce391b88324e4606e': 'ETH-USD',
  '0xc0cbd77ba95788e2462b755ee1fd42c6a4946901': 'SOL-USD',
  '0xaf7adbc53376d6ecf6668758eeddef4aa162eab2': 'BTC-USD',
};

export function getMarketIdFromAddress(address: string): string {
  return MARKET_ADDRESS_MAP[address.toLowerCase()] || 'ETH-USD';
}
```

### 3. 事件处理器修改

**文件**: `indexer/src/EventHandlers.ts`

```typescript
import { getMarketIdFromAddress } from "./marketAddresses";

// 根据合约地址派生 marketId
function getMarketId(srcAddress: string): string {
    return getMarketIdFromAddress(srcAddress);
}

// 所有事件处理器中添加 marketId
Exchange.TradeExecuted.handler(async ({ event, context }) => {
    const marketId = getMarketId(event.srcAddress);
    
    const trade: Trade = {
        id: `${marketId}-${event.transaction.hash}-${event.logIndex}`,
        marketId,  // 新增
        price: event.params.price,
        // ...
    };
    context.Trade.set(trade);
});

// Order ID 格式改为: marketId-orderId
Exchange.OrderPlaced.handler(async ({ event, context }) => {
    const marketId = getMarketId(event.srcAddress);
    
    const order: Order = {
        id: `${marketId}-${event.params.id}`,  // 前缀加 marketId
        marketId,
        // ...
    };
});
```

### 4. 索引器配置修改

**文件**: `indexer/config.yaml`

```yaml
networks:
  - id: 31337
    contracts:
      - name: Exchange
        address:
          - 0x60f02157159b12bae61f2adce391b88324e4606e  # ETH-USD
          - 0xc0cbd77ba95788e2462b755ee1fd42c6a4946901  # SOL-USD
          - 0xaf7adbc53376d6ecf6668758eeddef4aa162eab2  # BTC-USD
        handler: src/EventHandlers.ts
```

---

## 部署脚本修改

### 1. 主部署脚本

**文件**: `scripts/run-anvil-deploy.sh`

```bash
# 市场价格配置
declare -A MARKET_PRICES
MARKET_PRICES[ETH]=2000
MARKET_PRICES[SOL]=25
MARKET_PRICES[BTC]=42000

# 循环部署 3 个合约
for MARKET in ETH SOL BTC; do
    MOCK_PRICE=${MARKET_PRICES[$MARKET]}
    forge script DeployExchange.s.sol --broadcast ...
    MARKET_ADDRESSES[$MARKET]="$DEPLOYED_ADDRESS"
done

# 写入前端环境变量
cat > frontend/.env.local <<EOF
VITE_EXCHANGE_ADDRESS_ETH=${MARKET_ADDRESSES[ETH]}
VITE_EXCHANGE_ADDRESS_SOL=${MARKET_ADDRESSES[SOL]}
VITE_EXCHANGE_ADDRESS_BTC=${MARKET_ADDRESSES[BTC]}
EOF

# 更新索引器配置
# 生成 marketAddresses.ts
```

### 2. 种子数据脚本

**文件**: `scripts/seed.sh`

```bash
# 根据价格计算保证金
seed_market() {
    local BASE_PRICE=$3
    
    # 高价资产需要更多保证金
    if [ "$BASE_PRICE" -gt 10000 ]; then
        DEPOSIT_AMOUNT=500  # BTC
    elif [ "$BASE_PRICE" -gt 1000 ]; then
        DEPOSIT_AMOUNT=200  # ETH
    else
        DEPOSIT_AMOUNT=100  # SOL
    fi
    
    # 存款、下单、生成 K 线数据...
}

# 种子所有市场
seed_market "ETH-USD" "$EXCHANGE_ETH" 1500
seed_market "SOL-USD" "$EXCHANGE_SOL" 25
seed_market "BTC-USD" "$EXCHANGE_BTC" 42000
```

---

## 测试新增

### 多市场 Foundry 测试

**文件**: `contract/test/MultiMarket.t.sol`

```solidity
contract MultiMarketTest is Test {
    MonadPerpExchangeHarness internal ethExchange;
    MonadPerpExchangeHarness internal solExchange;
    MonadPerpExchangeHarness internal btcExchange;

    function setUp() public {
        // 部署 3 个独立合约
        ethExchange = new MonadPerpExchangeHarness();
        solExchange = new MonadPerpExchangeHarness();
        btcExchange = new MonadPerpExchangeHarness();
        
        // 设置不同初始价格
        ethExchange.updateIndexPrice(2000 ether);
        solExchange.updateIndexPrice(25 ether);
        btcExchange.updateIndexPrice(42000 ether);
    }

    // 测试用例
    function testMultipleExchangesDeployed() public { ... }
    function testEachMarketHasCorrectPrice() public { ... }
    function testIndependentMarginDeposits() public { ... }
    function testIndependentOrderPlacement() public { ... }
    function testIndependentTradeExecution() public { ... }
    function testIndependentPriceUpdates() public { ... }
    function testCrossMarketTradingScenario() public { ... }
    function testMarketIsolationOnLiquidation() public { ... }
}
```

运行测试：
```bash
cd contract
forge test --match-contract MultiMarketTest -vvv
```

---

## 数据流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              用户操作                                    │
│                                                                         │
│  1. 用户在 Header 选择 "BTC/USD"                                        │
│     ↓                                                                   │
│  2. store.setActiveMarket(BTC_MARKET)                                   │
│     ↓                                                                   │
│  3. getMarketContractAddress() → 从 .env 读取 VITE_EXCHANGE_ADDRESS_BTC │
│     ↓                                                                   │
│  4. 创建 BTC 合约实例，发送交易                                          │
│     ↓                                                                   │
│  5. 合约发出事件 (TradeExecuted, OrderPlaced 等)                         │
│     ↓                                                                   │
│  6. Indexer 监听事件，根据 srcAddress 派生 marketId="BTC-USD"            │
│     ↓                                                                   │
│  7. 数据存储时带上 marketId 字段                                         │
│     ↓                                                                   │
│  8. 前端查询时传入 marketId="BTC-USD" 过滤数据                           │
│     ↓                                                                   │
│  9. UI 显示 BTC/USD 的 K 线、订单簿、最近成交等                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 如何新增交易对

以新增 **DOGE/USD** 为例：

### Step 1: 修改部署脚本

`scripts/run-anvil-deploy.sh`:
```bash
# 添加 DOGE 价格
MARKET_PRICES[DOGE]=0.1

# 添加到部署循环
for MARKET in ETH SOL BTC DOGE; do

# 添加环境变量输出
VITE_EXCHANGE_ADDRESS_DOGE=${MARKET_ADDRESSES[DOGE]}
```

### Step 2: 修改前端市场定义

`frontend/markets.ts`:
```typescript
export const MARKETS: Market[] = [
    // ... 现有市场
    { id: 'DOGE-USD', symbol: 'DOGE/USD', baseAsset: 'DOGE', quoteAsset: 'USD', icon: '🐕', decimals: 6, envKey: 'VITE_EXCHANGE_ADDRESS_DOGE' },
];
```

### Step 3: 修改种子脚本

`scripts/seed.sh`:
```bash
EXCHANGE_DOGE=$(grep VITE_EXCHANGE_ADDRESS_DOGE "$ENV_FILE" | cut -d '=' -f2)

seed_market "DOGE-USD" "$EXCHANGE_DOGE" 0.1
```

### Step 4: 重新部署

```bash
./scripts/run-anvil-deploy.sh
./scripts/seed.sh
cd indexer && pnpm dev
```

---

## 修改文件清单

| 类型 | 文件路径 | 修改类型 |
|------|----------|----------|
| 前端 | `frontend/markets.ts` | 新增 |
| 前端 | `frontend/store/exchangeStore.tsx` | 修改 |
| 前端 | `frontend/store/IndexerClient.ts` | 修改 |
| 前端 | `frontend/components/Header.tsx` | 修改 |
| 前端 | `frontend/components/TradingChart.tsx` | 修改 |
| 前端 | `frontend/components/OrderForm.tsx` | 修改 |
| 前端 | `frontend/components/Positions.tsx` | 修改 |
| 索引器 | `indexer/schema.graphql` | 修改 |
| 索引器 | `indexer/src/EventHandlers.ts` | 修改 |
| 索引器 | `indexer/src/marketAddresses.ts` | 新增(自动生成) |
| 索引器 | `indexer/config.yaml` | 修改(自动生成) |
| 脚本 | `scripts/run-anvil-deploy.sh` | 修改 |
| 脚本 | `scripts/seed.sh` | 修改 |
| 测试 | `contract/test/MultiMarket.t.sol` | 新增 |

---

*文档生成时间: 2026-01-22*
