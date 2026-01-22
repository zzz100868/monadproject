import { walletClient, publicClient } from '../client';
import { EXCHANGE_ABI } from '../abi';
import { EXCHANGE_ADDRESS as ADDRESS } from '../config';

/**
 * PriceKeeper Service - 脚手架版本
 * 
 * 这个服务负责定期更新交易所的指数价格。
 * 
 * TODO: 学生需要实现 updatePrice 函数：
 * 1. 从 Pyth Network 获取 ETH/USD 价格
 * 2. 转换为合约精度 (1e18)
 * 3. 调用合约的 updateIndexPrice 函数更新价格
 */
export class PriceKeeper {
    private intervalId: NodeJS.Timeout | null = null;
    private isRunning = false;

    // Pyth ETH/USD Price Feed ID
    private readonly PYTH_ETH_ID = '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace';

    constructor(private intervalMs: number = 5000) { }

    start() {
        if (this.isRunning) return;
        this.isRunning = true;
        console.log(`[PriceKeeper] Starting price updates every ${this.intervalMs}ms...`);

        this.updatePrice();
        this.intervalId = setInterval(() => this.updatePrice(), this.intervalMs);
    }

    stop() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = null;
        }
        this.isRunning = false;
        console.log('[PriceKeeper] Stopped.');
    }

    /**
     * 更新价格
     * 
     * TODO: 实现此函数，参考 day4-guide.md Step 5
     */
    private async updatePrice() {
    try {
        // 1. 从 Pyth 获取价格
        const res = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?ids[]=${this.PYTH_ETH_ID}`);
        const data = await res.json();
        const priceInfo = data.parsed[0].price;

        // 2. 解析价格 (price = p * 10^expo)
        const p = BigInt(priceInfo.price);
        const expo = priceInfo.expo;

        // 3. 转换为 1e18 精度 (Wei)
        // 公式: p * 10^expo * 10^18 = p * 10^(18 + expo)
        const priceWei = p * (10n ** BigInt(18 + expo));

        console.log(`[PriceKeeper] Fetched ETH price: $${Number(p) * Math.pow(10, expo)} -> ${priceWei} wei`);

        // 4. 调用合约更新价格
        const hash = await walletClient.writeContract({
            address: ADDRESS as `0x${string}`,
            abi: EXCHANGE_ABI,
            functionName: 'updateIndexPrice',
            args: [priceWei]
        });
        await publicClient.waitForTransactionReceipt({ hash });
        console.log(`[PriceKeeper] Price updated on-chain, tx: ${hash}`);

    } catch (e) {
        console.error('[PriceKeeper] Error updating price:', e);
    }
}
}
