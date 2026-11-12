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
  }
}

const robot = new Starter(path.join(__dirname, 'tactic.bqn'));
cy.run(robot,{bindingName:'clunkyard-bqn'}).finally(()=>robot.bqn.close());
