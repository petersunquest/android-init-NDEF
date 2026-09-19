(function () {
  'use strict';

  // BEAMIO_CONET_WALLET_CHAIN_FIX_V1
  // Coinbase may wrap an unknown-chain response as -32603 while preserving
  // the EIP-3085 error code in originalError.code.
  var CONET_CHAIN = {
    chainId: '0x36ca',
    chainName: 'CoNET',
    nativeCurrency: {
      name: 'CoNET',
      // Chain ID 224422 is registered in MetaMask-compatible chain lists
      // with CONET. Keep the wallet metadata aligned to avoid its warning;
      // this does not change the chain's on-chain asset semantics.
      symbol: 'CONET',
      decimals: 18,
    },
    rpcUrls: ['https://publicrpc.conet.network'],
    blockExplorerUrls: ['https://mainnet.conet.network'],
  };
  var wrappedProviders = typeof WeakSet === 'function' ? new WeakSet() : null;

  function isUnknownChainError(error) {
    var current = error;
    for (var depth = 0; current && depth < 4; depth += 1) {
      if (current.code === 4902) return true;
      current = current.data && current.data.originalError;
    }
    return false;
  }

  function isUserRejectedError(error) {
    var current = error;
    for (var depth = 0; current && depth < 4; depth += 1) {
      if (current.code === 4001) return true;
      current = current.data && current.data.originalError;
    }
    return false;
  }

  function wrapProvider(provider) {
    if (!provider || typeof provider.request !== 'function') return;
    if (wrappedProviders && wrappedProviders.has(provider)) return;
    var originalRequest = provider.request.bind(provider);
    function isOnConet() {
      return originalRequest({ method: 'eth_chainId' }).then(function (chainId) {
        return String(chainId).toLowerCase() === CONET_CHAIN.chainId;
      }, function () {
        return false;
      });
    }
    var request = function (args) {
      if (args && args.method === 'wallet_addEthereumChain') {
        return originalRequest(args).catch(function (error) {
          // Some Coinbase versions report a cancelled duplicate prompt as
          // 4001 even though the chain was added and selected.
          if (!isUserRejectedError(error)) throw error;
          return isOnConet().then(function (onConet) {
            if (onConet) return null;
            throw error;
          });
        });
      }
      if (!args || args.method !== 'wallet_switchEthereumChain') {
        return originalRequest(args);
      }
      return originalRequest(args).catch(function (error) {
        if (isUserRejectedError(error)) {
          return isOnConet().then(function (onConet) {
            if (onConet) return null;
            throw error;
          });
        }
        if (!isUnknownChainError(error)) throw error;
        return originalRequest({
          method: 'wallet_addEthereumChain',
          params: [CONET_CHAIN],
        }).then(function () {
          // Coinbase may switch automatically after adding the chain. Avoid
          // sending a second prompt, which can be reported as error 4001.
          return originalRequest({ method: 'eth_chainId' }).then(function (chainId) {
            if (String(chainId).toLowerCase() === CONET_CHAIN.chainId) return null;
            return originalRequest(args);
          }, function () {
            return originalRequest(args);
          });
        });
      });
    };
    try {
      provider.request = request;
      if (wrappedProviders) wrappedProviders.add(provider);
    } catch (_) {
      // Some injected providers expose a non-writable request property.
    }
  }

  function wrapKnownProviders() {
    var ethereum = window.ethereum;
    wrapProvider(ethereum);
    if (ethereum && Array.isArray(ethereum.providers)) {
      ethereum.providers.forEach(wrapProvider);
    }
  }

  wrapKnownProviders();
  window.addEventListener('eip6963:announceProvider', function (event) {
    wrapProvider(event.detail && event.detail.provider);
  });
  window.dispatchEvent(new Event('eip6963:requestProvider'));
})();
