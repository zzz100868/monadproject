#!/usr/bin/env bash
# 一键启动 anvil、部署合约，最后把 anvil 留在前台（Ctrl+C 关闭）。
# Multi-market version: deploys 3 Exchange contracts (ETH, SOL, BTC)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="$ROOT_DIR/contract"

# 默认参数（直接改这里即可，无需每次传参）
RPC_URL="http://127.0.0.1:8545"
CHAIN_ID="31337"
PORT="8545"
LOG_FILE="$ROOT_DIR/output/logs/anvil.log"

# anvil 默认私钥（账户 #0）
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
# 前端用于本地签名的测试私钥（使用助记词索引 #1）
TEST_PRIVATE_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# 部署脚本参数 - 3个市场的初始价格
USE_MOCK_PYTH="true"
MOCK_EXPO="0"

# Market configurations
declare -A MARKET_PRICES
MARKET_PRICES[ETH]=2000
MARKET_PRICES[SOL]=25
MARKET_PRICES[BTC]=42000

declare -A MARKET_ADDRESSES

# Generate a random deployer key to avoid nonce collisions
PRIVATE_KEY=$(cast wallet new | grep -i "Private Key" | awk '{print $3}')
echo "Generated ephemeral deployer key: $PRIVATE_KEY"

# Kill any existing anvil processes using port 8545 to ensure clean slate
lsof -ti:8545 | xargs kill -9 >/dev/null 2>&1 || true
pkill -f "anvil --" >/dev/null 2>&1 || true
sleep 2

echo "启动 anvil (chain-id=$CHAIN_ID, port=$PORT)..."
# Reset log file
echo "Starting Anvil..." > "$LOG_FILE"
anvil --host 0.0.0.0 --chain-id "$CHAIN_ID" --port "$PORT" --block-time 1 >>"$LOG_FILE" 2>&1 &
ANVIL_PID=$!
echo "anvil PID: $ANVIL_PID (日志: $LOG_FILE)"

cleanup() {
  if ps -p "$ANVIL_PID" >/dev/null 2>&1; then
    echo "停止 anvil ($ANVIL_PID)..."
    kill "$ANVIL_PID"
  fi
}
trap cleanup EXIT

echo "等待 anvil 就绪..."
for _ in {1..30}; do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  
  # Check if process is still alive
  if ! ps -p "$ANVIL_PID" >/dev/null 2>&1; then
    echo "Anvil process died unexpectedly!"
    echo "Last 20 lines of log:"
    tail -n 20 "$LOG_FILE"
    exit 1
  fi
  sleep 0.3
done

# Final check
if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "Anvil failed to become ready."
    echo "Last 20 lines of log:"
    tail -n 20 "$LOG_FILE"
    exit 1
fi

echo "Funding ephemeral deployer key..."
ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
# Use Account #2 for funding to avoid potential conflicts with Account #0
FUNDING_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
cast send "$ADDRESS" --value 100ether --private-key "$FUNDING_KEY" --rpc-url "$RPC_URL" --gas-price 20000000000 >/dev/null

cd "$CONTRACT_DIR"
rm -rf broadcast/ cache/
forge clean

# Deploy 3 Exchange contracts
for MARKET in ETH SOL BTC; do
  MOCK_PRICE=${MARKET_PRICES[$MARKET]}
  echo ""
  echo "========================================"
  echo "  Deploying $MARKET-USD Exchange (price=$MOCK_PRICE)"
  echo "========================================"
  
  USE_MOCK_PYTH="$USE_MOCK_PYTH" MOCK_PRICE="$MOCK_PRICE" MOCK_EXPO="$MOCK_EXPO" PRIVATE_KEY="$PRIVATE_KEY" \
  forge script script/DeployExchange.s.sol:DeployExchangeScript --broadcast --rpc-url "$RPC_URL" --legacy --slow || exit 1
  
  if command -v jq >/dev/null 2>&1; then
    BROADCAST_FILE="$CONTRACT_DIR/broadcast/DeployExchange.s.sol/$CHAIN_ID/run-latest.json"
    if [[ -f "$BROADCAST_FILE" ]]; then
      EXCHANGE_ADDR=$(jq -r '.transactions[] | select(.contractName=="MonadPerpExchange") | .contractAddress' "$BROADCAST_FILE" | tail -n 1)
      MARKET_ADDRESSES[$MARKET]="$EXCHANGE_ADDR"
      echo "  $MARKET-USD deployed at: $EXCHANGE_ADDR"
      
      # Grant OPERATOR_ROLE to Alice for seeding
      echo "  Granting OPERATOR_ROLE to Alice..."
      cast send "$EXCHANGE_ADDR" "setOperator(address)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
    fi
  fi
done

# Get deploy block from the last deployment
BROADCAST_FILE="$CONTRACT_DIR/broadcast/DeployExchange.s.sol/$CHAIN_ID/run-latest.json"
BLOCK_HEX=$(jq -r '.receipts[0].blockNumber' "$BROADCAST_FILE" | tail -n 1)
if [[ "$BLOCK_HEX" =~ ^0x ]]; then
  BLOCK_DEC=$((BLOCK_HEX))
else
  BLOCK_DEC="$BLOCK_HEX"
fi

# Write frontend .env.local with all 3 addresses
cat > "$ROOT_DIR/frontend/.env.local" <<EOF
VITE_RPC_URL=$RPC_URL
VITE_CHAIN_ID=$CHAIN_ID
VITE_EXCHANGE_ADDRESS=${MARKET_ADDRESSES[ETH]}
VITE_EXCHANGE_ADDRESS_ETH=${MARKET_ADDRESSES[ETH]}
VITE_EXCHANGE_ADDRESS_SOL=${MARKET_ADDRESSES[SOL]}
VITE_EXCHANGE_ADDRESS_BTC=${MARKET_ADDRESSES[BTC]}
VITE_EXCHANGE_DEPLOY_BLOCK=$BLOCK_DEC
VITE_TEST_PRIVATE_KEY=$TEST_PRIVATE_KEY
EOF
echo ""
echo "已写入 frontend/.env.local"
echo "  ETH-USD: ${MARKET_ADDRESSES[ETH]}"
echo "  SOL-USD: ${MARKET_ADDRESSES[SOL]}"
echo "  BTC-USD: ${MARKET_ADDRESSES[BTC]}"

# Copy ABI JSON to frontend and convert to TS with 'as const'
ABI_SOURCE="$CONTRACT_DIR/out/Exchange.sol/MonadPerpExchange.json"
ABI_DEST_TS="$ROOT_DIR/frontend/onchain/ExchangeABI.ts"
if [[ -f "$ABI_SOURCE" ]]; then
  printf "export const EXCHANGE_ABI = %s as const;\n" "$(jq -c '.abi' "$ABI_SOURCE")" > "$ABI_DEST_TS"
  echo "已生成 ABI 到 frontend/onchain/ExchangeABI.ts"
fi

# Update Indexer config.yaml with all 3 contract addresses
INDEXER_CONFIG="$ROOT_DIR/indexer/config.yaml"
if [[ -f "$INDEXER_CONFIG" ]]; then
  # Create new config with all 3 addresses
  cat > "$INDEXER_CONFIG" <<EOF
name: monad-exchange-indexer
description: Indexer for Monad Perpetual Exchange events (Multi-Market)

field_selection:
  transaction_fields:
    - hash

networks:
  - id: 31337
    start_block: 0
    rpc_config:
      url: http://127.0.0.1:8545
    contracts:
      - name: Exchange
        address:
          - ${MARKET_ADDRESSES[ETH]}  # ETH-USD
          - ${MARKET_ADDRESSES[SOL]}  # SOL-USD
          - ${MARKET_ADDRESSES[BTC]}  # BTC-USD
        handler: src/EventHandlers.ts
        events:
          - event: MarginDeposited(address indexed trader, uint256 amount)
          - event: MarginWithdrawn(address indexed trader, uint256 amount)
          - event: OrderPlaced(uint256 indexed id, address indexed trader, bool isBuy, uint256 price, uint256 amount)
          - event: OrderRemoved(uint256 indexed id)
          - event: TradeExecuted(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 price, uint256 amount, address buyer, address seller)
          - event: PositionUpdated(address indexed trader, int256 size, uint256 entryPrice)
          - event: Liquidated(address indexed trader, address indexed liquidator, uint256 amount, uint256 reward)
          - event: FundingUpdated(int256 cumulativeFundingRate, uint256 timestamp)
          - event: FundingPaid(address indexed trader, int256 amount)
EOF
  echo "已更新 indexer/config.yaml (3 markets)"
fi

# Create market address mapping file for indexer
MARKET_MAPPING_FILE="$ROOT_DIR/indexer/src/marketAddresses.ts"
# Convert addresses to lowercase using bash
ETH_ADDR_LOWER=$(echo "${MARKET_ADDRESSES[ETH]}" | tr '[:upper:]' '[:lower:]')
SOL_ADDR_LOWER=$(echo "${MARKET_ADDRESSES[SOL]}" | tr '[:upper:]' '[:lower:]')
BTC_ADDR_LOWER=$(echo "${MARKET_ADDRESSES[BTC]}" | tr '[:upper:]' '[:lower:]')
cat > "$MARKET_MAPPING_FILE" <<EOF
// Auto-generated market address mapping
// DO NOT EDIT MANUALLY - generated by run-anvil-deploy.sh

export const MARKET_ADDRESS_MAP: Record<string, string> = {
  '${ETH_ADDR_LOWER}': 'ETH-USD',
  '${SOL_ADDR_LOWER}': 'SOL-USD',
  '${BTC_ADDR_LOWER}': 'BTC-USD',
};

export function getMarketIdFromAddress(address: string): string {
  return MARKET_ADDRESS_MAP[address.toLowerCase()] || 'ETH-USD';
}
EOF
echo "已生成 indexer/src/marketAddresses.ts"

echo ""
echo "========================================"
echo "  部署完成！"
echo "========================================"
echo "ETH-USD: ${MARKET_ADDRESSES[ETH]}"
echo "SOL-USD: ${MARKET_ADDRESSES[SOL]}"
echo "BTC-USD: ${MARKET_ADDRESSES[BTC]}"
echo ""
echo "anvil 继续运行，按 Ctrl+C 退出。"
wait "$ANVIL_PID"
