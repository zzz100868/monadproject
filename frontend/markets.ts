/**
 * Market configuration for multi-market trading support
 */

export interface Market {
    id: string;           // e.g., "ETH-USD"
    symbol: string;       // e.g., "ETH/USD"
    baseAsset: string;    // e.g., "ETH"
    quoteAsset: string;   // e.g., "USD"
    icon: string;         // Emoji or icon path
    decimals: number;     // Price decimals for display
    envKey: string;       // Environment variable key for contract address
}

export const MARKETS: Market[] = [
    { id: 'ETH-USD', symbol: 'ETH/USD', baseAsset: 'ETH', quoteAsset: 'USD', icon: '⟠', decimals: 2, envKey: 'VITE_EXCHANGE_ADDRESS_ETH' },
    { id: 'SOL-USD', symbol: 'SOL/USD', baseAsset: 'SOL', quoteAsset: 'USD', icon: '◎', decimals: 4, envKey: 'VITE_EXCHANGE_ADDRESS_SOL' },
    { id: 'BTC-USD', symbol: 'BTC/USD', baseAsset: 'BTC', quoteAsset: 'USD', icon: '₿', decimals: 2, envKey: 'VITE_EXCHANGE_ADDRESS_BTC' },
];

export const DEFAULT_MARKET = MARKETS[0];

/**
 * Get market by ID
 */
export const getMarketById = (id: string): Market | undefined => {
    return MARKETS.find(m => m.id === id);
};

/**
 * Get contract address for a market from environment variables
 */
export const getMarketContractAddress = (market: Market): string => {
    const env = (import.meta as any).env || {};
    const address = env[market.envKey] || env.VITE_EXCHANGE_ADDRESS; // Fallback to default
    return address || '';
};

/**
 * Map of all market contract addresses
 */
export const getMarketAddresses = (): Record<string, string> => {
    const addresses: Record<string, string> = {};
    for (const market of MARKETS) {
        addresses[market.id] = getMarketContractAddress(market);
    }
    return addresses;
};
