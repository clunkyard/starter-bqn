// A starter robot for rules v2, in BQN: tactic.bqn decides each tick with
// the functions in clunkyard.bqn, and clunkyard_bqn.js runs it in CBQN on the
// installed Clunkyard JavaScript core binding, which speaks the protocol.
// The arena supplies the adapter and binding. Read tactic.bqn first.
'use strict';
const path = require('node:path');
const cy = require('clunkyard');
const { Tactic } = require('clunkyard_bqn');

class Starter extends Tactic {
  onTurn() {
    super.onTurn();
    // Only the arena's rate calibration sends calibration.work; it times this
    // language on the same work as every other. Safe to delete.
    const work = this.raw.number('state.calibration.work');
    if (Number.isInteger(work) && work > 0) this.status.set({text:'WORK',value:calibrationWork(work,this.clock.tick)});
  }
}

// The calibration kernel, xorshift-sqrt v1: work rounds of a 64-bit
// xorshift, kept as two 32-bit halves, and a square-root sum.
function calibrationWork(work, tick) {
  let hi = 0x0139408d, lo = (0xcbbf7a44 ^ tick) >>> 0, sum = 0;
  for (let i = 0; i < work; i++) {
    hi = (hi ^ ((hi << 13) | (lo >>> 19))) >>> 0; lo = (lo ^ (lo << 13)) >>> 0;
    lo = (lo ^ ((lo >>> 7) | (hi << 25))) >>> 0; hi = (hi ^ (hi >>> 7)) >>> 0;
    hi = (hi ^ ((hi << 17) | (lo >>> 15))) >>> 0; lo = (lo ^ (lo << 17)) >>> 0;
    sum += Math.sqrt(hi * 2097152 + (lo >>> 11));
  }
  return (Math.floor(sum) + (hi >>> 8)) % 1000000;
}

const robot = new Starter(path.join(__dirname, 'tactic.bqn'));
cy.run(robot,{bindingName:'clunkyard-bqn'}).finally(()=>robot.bqn.close());
