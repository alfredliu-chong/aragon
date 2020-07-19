const { createVote, getVoteState } = require('../helpers/voting')
const { ONE_DAY, bn, bigExp, pct16 } = require('@aragon/contract-helpers-test')
const { ARAGON_OS_ERRORS, VOTING_ERRORS } = require('../helpers/errors')
const { assertBn, assertRevert, assertEvent, assertAmountOfEvents } = require('@aragon/contract-helpers-test/src/asserts')

const deployer = require('../helpers/deployer')(web3, artifacts)

contract('Voting settings', ([_, owner, anyone, holder51, holder20, holder29]) => {
  let voting

  const VOTE_DURATION = 5 * ONE_DAY
  const OVERRULE_WINDOW = ONE_DAY
  const EXECUTION_DELAY = 0
  const REQUIRED_SUPPORT = pct16(50)
  const MINIMUM_ACCEPTANCE_QUORUM = pct16(20)

  before('deploy and mint tokens', async () => {
    const token = await deployer.deployToken({})
    await token.generateTokens(holder51, bigExp(51, 18))
    await token.generateTokens(holder20, bigExp(20, 18))
    await token.generateTokens(holder29, bigExp(29, 18))
  })

  beforeEach('deploy voting', async () => {
    voting = await deployer.deployAndInitialize({ owner, supportRequired: REQUIRED_SUPPORT, minimumAcceptanceQuorum: MINIMUM_ACCEPTANCE_QUORUM, voteDuration: VOTE_DURATION, overruleWindow: OVERRULE_WINDOW, executionDelay: EXECUTION_DELAY })
  })

  describe('changeSupportRequiredPct', () => {
    context('when the sender is allowed', () => {
      const from = owner

      context('when the new value is below the minimum quorum', () => {
        const newSupport = MINIMUM_ACCEPTANCE_QUORUM.sub(bn(1))

        it('fails changing required support lower than minimum acceptance quorum', async () => {
          await assertRevert(voting.changeSupportRequiredPct(newSupport, { from }), VOTING_ERRORS.VOTING_CHANGE_SUPPORT_PCTS)
        })
      })

      context('when the new value is between the minimum quorum and 100%', () => {
        const newSupport = MINIMUM_ACCEPTANCE_QUORUM.add(bn(1))

        it('changes the required support', async () => {
          await voting.changeSupportRequiredPct(newSupport, { from })

          assertBn(await voting.supportRequiredPct(), newSupport, 'should have changed required support')
        })

        it('emits an event', async () => {
          const receipt = await voting.changeSupportRequiredPct(newSupport, { from })

          assertAmountOfEvents(receipt, 'ChangeSupportRequired')
          assertEvent(receipt, 'ChangeSupportRequired', { expectedArgs: { supportRequiredPct: newSupport } })
        })

        it('does not affect vote required support', async () => {
          const { voteId } = await createVote({ voting, from: holder51 })
          await voting.changeSupportRequiredPct(pct16(70), { from })

          // With previous required support at 50%, vote should be approved
          // with new required support at 70% it shouldn't have,
          // but since min quorum is snapshotted it will succeed

          await voting.vote(voteId, true, { from: holder51 })
          await voting.vote(voteId, false, { from: holder20 })
          await voting.vote(voteId, false, { from: holder29 })
          await voting.mockIncreaseTime(VOTE_DURATION)

          const { support } = await getVoteState(voting, voteId)
          assertBn(support, REQUIRED_SUPPORT, 'required support in vote should stay equal')
          await voting.executeVote(voteId) // exec doesn't fail
        })
      })

      context('when the new value is 100%', () => {
        const newSupport = pct16(100)

        it('reverts', async () => {
          await assertRevert(voting.changeSupportRequiredPct(newSupport, { from }), VOTING_ERRORS.VOTING_CHANGE_SUPP_TOO_BIG)
        })
      })

      context('when the new value is above 100%', () => {
        const newSupport = pct16(101)

        it('reverts', async () => {
          await assertRevert(voting.changeSupportRequiredPct(newSupport, { from }), VOTING_ERRORS.VOTING_CHANGE_SUPP_TOO_BIG)
        })
      })
    })

    context('when the sender is not allowed', () => {
      const from = anyone

      it('reverts', async () => {
        await assertRevert(voting.changeSupportRequiredPct(pct16(90), { from }), ARAGON_OS_ERRORS.APP_AUTH_FAILED)
      })
    })
  })

  describe('changeMinAcceptQuorumPct', () => {
    context('when the sender is allowed', () => {
      const from = owner

      const itChangesTheAcceptanceQuorum = newQuorum => {
        it('changes the minimum acceptance quorum', async () => {
          await voting.changeMinAcceptQuorumPct(newQuorum, { from })

          assertBn(await voting.minAcceptQuorumPct(), newQuorum, 'should have changed min acceptance quorum')
        })

        it('emits an event', async () => {
          const receipt = await voting.changeMinAcceptQuorumPct(newQuorum, { from })

          assertAmountOfEvents(receipt, 'ChangeMinQuorum')
          assertEvent(receipt, 'ChangeMinQuorum', { expectedArgs: { minAcceptQuorumPct: newQuorum } })
        })

        it('does not affect the vote min quorum', async () => {
          const { voteId } = await createVote({ voting, from: holder51 })
          await voting.changeMinAcceptQuorumPct(pct16(50), { from })

          // With previous min acceptance quorum at 20%, vote should be approved
          // with new minimum acceptance quorum at 50% it shouldn't have,
          // but since min quorum is snapshotted it will succeed

          await voting.vote(voteId, true, { from: holder29 })
          await voting.mockIncreaseTime(VOTE_DURATION)

          const { quorum } = await getVoteState(voting, voteId)
          assertBn(quorum, MINIMUM_ACCEPTANCE_QUORUM, 'acceptance quorum in vote should stay equal')
          await voting.executeVote(voteId) // exec doesn't fail
        })
      }

      context('when the new value is lower than the required support', () => {
        const newQuorum = REQUIRED_SUPPORT.sub(bn(1))

        itChangesTheAcceptanceQuorum(newQuorum)
      })

      context('when the new value is equal to the required support', () => {
        const newQuorum = REQUIRED_SUPPORT

        itChangesTheAcceptanceQuorum(newQuorum)
      })

      context('when the new value is greater than the required support', () => {
        const newQuorum = REQUIRED_SUPPORT.add(bn(1))

        it('reverts', async () => {
          await assertRevert(voting.changeMinAcceptQuorumPct(newQuorum, { from }), VOTING_ERRORS.VOTING_CHANGE_QUORUM_PCTS)
        })
      })
    })

    context('when the sender is not allowed', () => {
      const from = anyone

      it('reverts', async () => {
        await assertRevert(voting.changeMinAcceptQuorumPct(pct16(90), { from }), ARAGON_OS_ERRORS.APP_AUTH_FAILED)
      })
    })
  })

  describe('changeOverruleWindow', () => {
    context('when the sender is allowed', () => {
      const from = owner

      context('when the new window is valid', () => {
        const newWindow = ONE_DAY * 2

        it('changes the overrule window', async () => {
          await voting.changeOverruleWindow(newWindow, { from })

          assertBn(await voting.overruleWindow(), newWindow, 'overrule window does not match')
        })

        it('emits an event', async () => {
          const receipt = await voting.changeOverruleWindow(newWindow, { from })

          assertAmountOfEvents(receipt, 'ChangeOverruleWindow')
          assertEvent(receipt, 'ChangeOverruleWindow', { expectedArgs: { overruleWindow: newWindow } })
        })

        it('does not affect previous created votes', async () => {
          const { voteId } = await createVote({ voting, from: holder51 })

          await voting.changeOverruleWindow(newWindow, { from })

          const { overruleWindow } = await getVoteState(voting, voteId)
          assertBn(overruleWindow, OVERRULE_WINDOW, 'overrule window does not match')
        })
      })

      context('when the new window is not valid', () => {
        const newWindow = VOTE_DURATION + 1

        it('reverts', async () => {
          await assertRevert(voting.changeOverruleWindow(newWindow, { from }), VOTING_ERRORS.VOTING_INVALID_OVERRULE_WINDOW)
        })
      })
    })

    context('when the sender is not allowed', () => {
      const from = anyone
      const newWindow = ONE_DAY * 2

      it('reverts', async () => {
        await assertRevert(voting.changeOverruleWindow(newWindow, { from }), ARAGON_OS_ERRORS.APP_AUTH_FAILED)
      })
    })
  })

  describe('changeExecutionDelay', () => {
    const newDelay = ONE_DAY * 2

    context('when the sender is allowed', () => {
      const from = owner

      it('changes the overrule window', async () => {
        await voting.changeExecutionDelay(newDelay, { from })

        assertBn(await voting.executionDelay(), newDelay, 'execution delay does not match')
      })

      it('emits an event', async () => {
        const receipt = await voting.changeExecutionDelay(newDelay, { from })

        assertAmountOfEvents(receipt, 'ChangeExecutionDelay')
        assertEvent(receipt, 'ChangeExecutionDelay', { expectedArgs: { executionDelay: newDelay } })
      })

      it('does not affect previous created votes', async () => {
        const { voteId } = await createVote({ voting, from: holder51 })

        await voting.changeExecutionDelay(newDelay, { from })

        const { executionDelay } = await getVoteState(voting, voteId)
        assertBn(executionDelay, EXECUTION_DELAY, 'execution delay does not match')
      })
    })

    context('when the sender is not allowed', () => {
      const from = anyone

      it('reverts', async () => {
        await assertRevert(voting.changeExecutionDelay(newDelay, { from }), ARAGON_OS_ERRORS.APP_AUTH_FAILED)
      })
    })
  })
})
