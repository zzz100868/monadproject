import React, { useState } from 'react';
import { observer } from 'mobx-react-lite';
import { useExchangeStore } from '../store/exchangeStore';
import { CHAIN_ID, RPC_URL } from '../onchain/config';
import { formatEther } from 'viem';
import { Market } from '../markets';

const shortenAddress = (addr?: string) => {
  if (!addr) return '';
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
};

export const Header: React.FC = observer(() => {
  const { account, connectWallet, markPrice, syncing, accountIndex, switchAccount, activeMarket, markets, setActiveMarket } = useExchangeStore();
  const [marketDropdownOpen, setMarketDropdownOpen] = useState(false);

  const priceDisplay = markPrice > 0n
    ? Number(formatEther(markPrice)).toLocaleString(undefined, { minimumFractionDigits: activeMarket.decimals, maximumFractionDigits: activeMarket.decimals })
    : '--';

  return (
    <header className="h-16 border-b border-white/5 bg-[#0B0E14] flex items-center justify-between px-6 sticky top-0 z-50">
      <div className="flex items-center space-x-6">
        <div className="flex items-center space-x-2">
          {/* Logo Icon */}
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-nebula-violet to-nebula-pink flex items-center justify-center">
            <svg className="w-5 h-5 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          </div>
          <span className="text-xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-400">
            PerpM
          </span>
        </div>

        {/* Market Selector */}
        <div className="relative">
          <button
            onClick={() => setMarketDropdownOpen(!marketDropdownOpen)}
            className="flex items-center gap-2 bg-[#151924] hover:bg-[#1a1f2e] border border-white/10 px-4 py-2 rounded-lg transition-colors"
          >
            <span className="text-lg">{activeMarket.icon}</span>
            <span className="text-white font-semibold">{activeMarket.symbol}</span>
            <span className="text-nebula-teal font-mono text-sm">${priceDisplay}</span>
            <svg className={`w-4 h-4 text-gray-400 transition-transform ${marketDropdownOpen ? 'rotate-180' : ''}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
            </svg>
          </button>

          {marketDropdownOpen && (
            <div className="absolute top-full left-0 mt-2 w-56 bg-[#151924] border border-white/10 rounded-lg shadow-xl z-50 overflow-hidden">
              {markets.map((market: Market) => (
                <button
                  key={market.id}
                  onClick={() => {
                    setActiveMarket(market);
                    setMarketDropdownOpen(false);
                  }}
                  className={`w-full flex items-center gap-3 px-4 py-3 hover:bg-white/5 transition-colors ${activeMarket.id === market.id ? 'bg-nebula-violet/20 border-l-2 border-nebula-violet' : ''
                    }`}
                >
                  <span className="text-xl">{market.icon}</span>
                  <div className="flex flex-col items-start">
                    <span className="text-white font-medium">{market.symbol}</span>
                    <span className="text-xs text-gray-500">{market.baseAsset} Perpetual</span>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="hidden md:flex items-center bg-[#151924] border border-white/10 px-4 py-1.5 rounded-lg text-xs text-gray-400 gap-3">
          <div className="flex items-center gap-1">
            <span className="w-2 h-2 rounded-full bg-emerald-400" />
            <span className="font-mono text-white">Chain {CHAIN_ID}</span>
          </div>
          <div className="w-px h-4 bg-white/10" />
          <div className="flex items-center gap-1">
            <svg className="w-3 h-3 text-nebula-teal" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 2L2 12h3v8h5v-6h2v6h5v-8h3z" />
            </svg>
            <span className="font-mono truncate max-w-[140px]">{RPC_URL}</span>
          </div>
          {syncing && <span className="text-[10px] text-gray-500">syncing…</span>}
        </div>
      </div>

      <div className="flex items-center space-x-4">
        <div className="flex items-center space-x-2">
          <button
            onClick={() => {
              const url = new URL(window.location.href);
              url.searchParams.set('account', '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'); // Bob (Account 2)
              window.location.href = url.toString();
            }}
            className={`px-3 py-2 rounded-lg text-xs font-mono transition-colors border ${account === '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'
              ? 'bg-nebula-pink/20 text-nebula-pink border-nebula-pink/50'
              : 'bg-white/5 hover:bg-white/10 text-gray-300 border-white/5'
              }`}
          >
            Bob
          </button>
          <button
            onClick={() => {
              const url = new URL(window.location.href);
              url.searchParams.set('account', '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'); // Alice (Account 1)
              window.location.href = url.toString();
            }}
            className={`px-3 py-2 rounded-lg text-xs font-mono transition-colors border ${account === '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
              ? 'bg-nebula-teal/20 text-nebula-teal border-nebula-teal/50'
              : 'bg-white/5 hover:bg-white/10 text-gray-300 border-white/5'
              }`}
          >
            Alice
          </button>
          <button
            onClick={() => {
              const url = new URL(window.location.href);
              url.searchParams.set('account', '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'); // Carol (Account 3)
              window.location.href = url.toString();
            }}
            className={`px-3 py-2 rounded-lg text-xs font-mono transition-colors border ${account === '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'
              ? 'bg-nebula-violet/20 text-nebula-violet border-nebula-violet/50'
              : 'bg-white/5 hover:bg-white/10 text-gray-300 border-white/5'
              }`}
          >
            Carol
          </button>
        </div>
        <button
          onClick={() => connectWallet()}
          className="bg-nebula-violet hover:bg-violet-600 text-white font-medium px-4 py-2 rounded-lg text-sm transition-all shadow-lg shadow-violet-900/20"
        >
          {account ? shortenAddress(account) : 'Connect Wallet'}
        </button>
      </div>
    </header>
  );
});

