import { waffle } from 'hardhat'
import { expect } from 'chai'
import { constants, BytesLike } from 'ethers'

import { parseWei } from '../../../shared/Units'

import { depositFragment } from '../fragments'

import loadContext from '../../context'
const empty: BytesLike = constants.HashZero

describe('deposit', function () {
  before(async function () {
    loadContext(waffle.provider, ['engineDeposit', 'badEngineDeposit'], depositFragment)
  })

  describe('when the parameters are valid', function () {
    it('adds to the user margin account', async function () {
      await this.contracts.engineDeposit.deposit(this.signers[0].address, parseWei('1001').raw, parseWei('999').raw, empty)

      const margin = await this.contracts.engine.margins(this.signers[0].address)

      expect(margin.balanceRisky).to.equal(parseWei('1001').raw)
      expect(margin.balanceStable).to.equal(parseWei('999').raw)
    })

    it('adds to the margin account of another address when specified', async function () {
      await this.contracts.engineDeposit.deposit(
        this.contracts.engineDeposit.address,
        parseWei('1000').raw,
        parseWei('1000').raw,
        empty
      )

      expect(await this.contracts.engine.margins(this.contracts.engineDeposit.address)).to.be.deep.eq([
        parseWei('1000').raw,
        parseWei('1000').raw,
      ])
    })

    it('increases the previous margin when called another time', async function () {
      await this.contracts.engineDeposit.deposit(this.signers[0].address, parseWei('1001').raw, parseWei('999').raw, empty)
      await this.contracts.engineDeposit.deposit(this.signers[0].address, parseWei('999').raw, parseWei('1001').raw, empty)

      const margin = await this.contracts.engine.margins(this.signers[0].address)

      expect(margin.balanceRisky).to.equal(parseWei('2000').raw)
      expect(margin.balanceStable).to.equal(parseWei('2000').raw)
    })

    it('emits the Deposited event', async function () {
      await expect(
        this.contracts.engineDeposit.deposit(this.signers[0].address, parseWei('1000').raw, parseWei('1000').raw, empty)
      )
        .to.emit(this.contracts.engine, 'Deposited')
        .withArgs(this.contracts.engineDeposit.address, this.signers[0].address, parseWei('1000').raw, parseWei('1000').raw)
    })

    it('reverts when the user does not have sufficient funds', async function () {
      await expect(
        this.contracts.engineDeposit.deposit(
          this.contracts.engineDeposit.address,
          constants.MaxUint256.div(2),
          constants.MaxUint256.div(2),
          empty
        )
      ).to.be.reverted
    })

    it('reverts when the callback did not transfer the stable', async function () {
      await expect(
        this.contracts.badEngineDeposit.deposit(
          this.signers[0].address,
          parseWei('1000').raw,
          parseWei('1000').raw,
          empty,
          0
        )
      ).to.revertedWith('Not enough stable')
    })

    it('reverts when the callback did not transfer the risky', async function () {
      await expect(
        this.contracts.badEngineDeposit.deposit(
          this.signers[0].address,
          parseWei('1000').raw,
          parseWei('1000').raw,
          empty,
          1
        )
      ).to.revertedWith('Not enough risky')
    })

    it('reverts when the callback did not transfer the risky or the stable', async function () {
      await expect(
        this.contracts.badEngineDeposit.deposit(
          this.signers[0].address,
          parseWei('1000').raw,
          parseWei('1000').raw,
          empty,
          2
        )
      ).to.revertedWith('Not enough risky')
    })
  })

  describe.skip('when the parameters are not valid', function () {
    it('reverts if deltaX is 0', async function () {
      await expect(
        this.contracts.engineDeposit.deposit(this.signers[0].address, 0, parseWei('1000').raw, empty)
      ).to.revertedWith('Not enough risky')
    })

    it('reverts if deltaX is 0', async function () {
      await expect(
        this.contracts.engineDeposit.deposit(this.signers[0].address, parseWei('1000').raw, 0, empty)
      ).to.revertedWith('Not enough risky')
    })
  })
})
