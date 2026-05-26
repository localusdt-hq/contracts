module.exports = {
    networks: {
        mainnet: {
            privateKey: process.env.TRON_PRIVATE_KEY_HEX,
            userFeePercentage: 100,
            feeLimit: 1000 * 1e6, // 1000 TRX
            fullHost: 'https://api.trongrid.io',
            network_id: '1',
        },
        shasta: {
            privateKey: process.env.TRON_PRIVATE_KEY_HEX,
            userFeePercentage: 50,
            feeLimit: 500 * 1e6,
            fullHost: 'https://api.shasta.trongrid.io',
            network_id: '2',
        },
        nile: {
            privateKey: process.env.TRON_PRIVATE_KEY_HEX,
            userFeePercentage: 50,
            feeLimit: 500 * 1e6,
            fullHost: 'https://nile.trongrid.io',
            network_id: '3',
        },
    },
    compilers: {
        solc: {
            version: '0.8.24',
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 200,
                },
            },
        },
    },
};
