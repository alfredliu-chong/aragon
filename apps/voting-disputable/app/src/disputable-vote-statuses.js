export const VOTE_STATUS_ACTIVE = Symbol('VOTE_STATUS_ACTIVE')
export const VOTE_STATUS_PAUSED = Symbol('VOTE_STATUS_PAUSED')
export const VOTE_STATUS_CANCELLED = Symbol('VOTE_STATUS_CANCELLED')
export const VOTE_STATUS_CLOSED = Symbol('VOTE_STATUS_CLOSED')

export const DISPUTABLE_VOTE_STATUSES = new Map([
  ['0', VOTE_STATUS_ACTIVE],
  ['1', VOTE_STATUS_PAUSED],
  ['2', VOTE_STATUS_CANCELLED],
  ['3', VOTE_STATUS_CLOSED],
])

export const CHALLENGE_STATE_WAITING = Symbol('CHALLENGE_STATE_WAITING')
export const CHALLENGE_STATE_SETTLED = Symbol('CHALLENGE_STATE_SETTLED')
export const CHALLENGE_STATE_DISPUTED = Symbol('CHALLENGE_STATE_DISPUTED')
export const CHALLENGE_STATE_REJECTED = Symbol('CHALLENGE_STATE_REJECTED')
export const CHALLENGE_STATE_ACCEPTED = Symbol('CHALLENGE_STATE_ACCEPTED')
export const CHALLENGE_STATE_VOIDED = Symbol('CHALLENGE_STATE_VOIDED')

export const DISPUTABLE_CHALLENGE_STATES = new Map([
  ['0', CHALLENGE_STATE_WAITING],
  ['1', CHALLENGE_STATE_SETTLED],
  ['2', CHALLENGE_STATE_DISPUTED],
  ['3', CHALLENGE_STATE_REJECTED],
  ['4', CHALLENGE_STATE_ACCEPTED],
  ['5', CHALLENGE_STATE_VOIDED],
])
