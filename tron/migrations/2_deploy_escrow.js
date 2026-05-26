const LocalUSDTEscrow = artifacts.require('LocalUSDTEscrow');

module.exports = function (deployer, network) {
    // USDT TRC-20 contract addresses per network
    const usdtAddresses = {
        mainnet: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
        shasta: 'TG3XXyExBkPp9nzdajDZsozEu4BkaSJozs', // Shasta test USDT
        nile: 'TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj',   // Nile test USDT
    };

    const usdtAddress = usdtAddresses[network];

    if (!usdtAddress) {
        throw new Error(`No USDT address configured for network: ${network}`);
    }

    console.log(`Deploying LocalUSDTEscrow on ${network} with USDT: ${usdtAddress}`);
    deployer.deploy(LocalUSDTEscrow, usdtAddress);
};
