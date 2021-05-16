import '@typechain/hardhat'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-waffle'
import 'prettier-plugin-solidity'
import 'hardhat-tracer'
import 'hardhat-gas-reporter'

export default {
  networks: {
    hardhat: {},
  },
  solidity: { version: '0.8.0', settings: { optimizer: { enabled: true, runs: 400 } } },
  gasReporter: {
    currency: 'USD',
    gasPrice: 100,
  },
}
