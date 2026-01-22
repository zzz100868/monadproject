#!/usr/bin/env bash
# Multi-market seed script: generates trading data for ETH, SOL, and BTC markets
set -e

RPC_URL="http://localhost:8545"

# Load addresses from frontend/.env.local
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/../frontend/.env.local"
if [ -f "$ENV_FILE" ]; then
    EXCHANGE_ETH=$(grep VITE_EXCHANGE_ADDRESS_ETH "$ENV_FILE" | cut -d '=' -f2)
    EXCHANGE_SOL=$(grep VITE_EXCHANGE_ADDRESS_SOL "$ENV_FILE" | cut -d '=' -f2)
    EXCHANGE_BTC=$(grep VITE_EXCHANGE_ADDRESS_BTC "$ENV_FILE" | cut -d '=' -f2)
    
    if [ -z "$EXCHANGE_ETH" ] || [ -z "$EXCHANGE_SOL" ] || [ -z "$EXCHANGE_BTC" ]; then
        # Fallback to single contract mode
        EXCHANGE_ETH=$(grep "^VITE_EXCHANGE_ADDRESS=" "$ENV_FILE" | cut -d '=' -f2)
        EXCHANGE_SOL="$EXCHANGE_ETH"
        EXCHANGE_BTC="$EXCHANGE_ETH"
        echo "Single contract mode: $EXCHANGE_ETH"
    else
        echo "Multi-market mode:"
        echo "  ETH: $EXCHANGE_ETH"
        echo "  SOL: $EXCHANGE_SOL"
        echo "  BTC: $EXCHANGE_BTC"
    fi
else
    echo "Error: frontend/.env.local not found. Run run-anvil-deploy.sh first."
    exit 1
fi

ALICE_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
BOB_PK="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

echo "=================================================="
echo "   Monad Exchange: Multi-Market Seeding"
echo "=================================================="

check_tx() {
    if [ $? -ne 0 ]; then
        echo "❌ Transaction Failed!"
        exit 1
    fi
}

# Helper to place order
place_order() {
    local pk=$1
    local exchange=$2
    local is_buy=$3
    local price=$4
    local amount=$5
    echo "  -> Placing Order: Buy=$is_buy Price=$price Amount=$amount"
    cast send --rpc-url $RPC_URL --private-key $pk $exchange "placeOrder(bool,uint256,uint256,uint256)" $is_buy $price $amount 0
    sleep 0.5
    check_tx
}

# Seed a single market
seed_market() {
    local MARKET_NAME=$1
    local EXCHANGE=$2
    local BASE_PRICE=$3
    
    echo ""
    echo "========================================"
    echo "  Seeding $MARKET_NAME Market"
    echo "  Contract: $EXCHANGE"
    echo "  Base Price: $BASE_PRICE"
    echo "========================================"
    
    # Calculate prices based on base price
    local P1=$BASE_PRICE
    local P2=$(echo "$BASE_PRICE * 1.02" | bc | cut -d. -f1)
    local P3=$(echo "$BASE_PRICE * 0.98" | bc | cut -d. -f1)
    local P4=$(echo "$BASE_PRICE * 1.05" | bc | cut -d. -f1)
    local BID_LOW=$(echo "$BASE_PRICE * 0.93" | bc | cut -d. -f1)
    local BID_MID=$(echo "$BASE_PRICE * 0.95" | bc | cut -d. -f1)
    local ASK_MID=$(echo "$BASE_PRICE * 1.07" | bc | cut -d. -f1)
    local ASK_HIGH=$(echo "$BASE_PRICE * 1.10" | bc | cut -d. -f1)
    
    # Calculate deposit amount based on base price
    # Higher priced assets need more margin
    local DEPOSIT_AMOUNT=100
    if [ "$BASE_PRICE" -gt 10000 ]; then
        DEPOSIT_AMOUNT=500  # BTC needs more margin
    elif [ "$BASE_PRICE" -gt 1000 ]; then
        DEPOSIT_AMOUNT=200  # ETH 
    fi
    
    echo "[1/4] Depositing Funds..."
    echo "  -> Alice Deposit $DEPOSIT_AMOUNT ETH"
    cast send --rpc-url $RPC_URL --private-key $ALICE_PK $EXCHANGE "deposit()" --value ${DEPOSIT_AMOUNT}ether
    check_tx
    
    echo "  -> Bob Deposit $DEPOSIT_AMOUNT ETH"
    cast send --rpc-url $RPC_URL --private-key $BOB_PK $EXCHANGE "deposit()" --value ${DEPOSIT_AMOUNT}ether
    check_tx
    
    echo "[1.5/4] Setting Initial Index Price..."
    cast send --rpc-url $RPC_URL --private-key $ALICE_PK $EXCHANGE "updateIndexPrice(uint256)" ${P1}ether
    check_tx
    
    echo "[2/4] Executing Trades (Generating Candles)..."
    
    # Candle 1
    echo "  - Trade @ $P1"
    place_order $BOB_PK $EXCHANGE false ${P1}ether 0.01ether
    place_order $ALICE_PK $EXCHANGE true ${P1}ether 0.01ether
    
    echo "  - Time Travel (1 minute)..."
    cast rpc --rpc-url $RPC_URL evm_increaseTime 60 > /dev/null
    cast rpc --rpc-url $RPC_URL evm_mine > /dev/null
    
    # Candle 2
    echo "  - Trade @ $P2"
    place_order $BOB_PK $EXCHANGE false ${P2}ether 0.02ether
    place_order $ALICE_PK $EXCHANGE true ${P2}ether 0.02ether
    
    echo "  - Time Travel (1 minute)..."
    cast rpc --rpc-url $RPC_URL evm_increaseTime 60 > /dev/null
    cast rpc --rpc-url $RPC_URL evm_mine > /dev/null
    
    # Candle 3
    echo "  - Trade @ $P3"
    place_order $BOB_PK $EXCHANGE false ${P3}ether 0.015ether
    place_order $ALICE_PK $EXCHANGE true ${P3}ether 0.015ether
    
    echo "  - Time Travel (1 minute)..."
    cast rpc --rpc-url $RPC_URL evm_increaseTime 60 > /dev/null
    cast rpc --rpc-url $RPC_URL evm_mine > /dev/null
    
    # Candle 4
    echo "  - Trade @ $P4"
    place_order $BOB_PK $EXCHANGE false ${P4}ether 0.03ether
    place_order $ALICE_PK $EXCHANGE true ${P4}ether 0.03ether
    
    echo "[3/4] Placing Open Orders..."
    place_order $ALICE_PK $EXCHANGE true ${BID_LOW}ether 0.01ether
    place_order $ALICE_PK $EXCHANGE true ${BID_MID}ether 0.02ether
    place_order $BOB_PK $EXCHANGE false ${ASK_MID}ether 0.015ether
    place_order $BOB_PK $EXCHANGE false ${ASK_HIGH}ether 0.025ether
    
    echo "  ✓ $MARKET_NAME market seeded!"
}

# Seed all 3 markets
seed_market "ETH-USD" "$EXCHANGE_ETH" 1500
seed_market "SOL-USD" "$EXCHANGE_SOL" 25
seed_market "BTC-USD" "$EXCHANGE_BTC" 42000

echo ""
echo "=================================================="
echo "   All Markets Seeded Successfully!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Start indexer: cd indexer && pnpm codegen && pnpm dev"
echo "  2. Start frontend: cd frontend && npm run dev"
echo ""
