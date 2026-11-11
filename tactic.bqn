# A starter robot for rules v2, on the installed Clunkyard BQN adapter.
# It sweeps a medium scan to find a robot, or points it
# where a passive contact was heard, narrows the scan to hold it, leads it
# with shots whose power suits the range, fires only when the turret is on
# target, keeps battery back for driving and keeps out of the storm.
#
# The trade-offs (game has the numbers from hello):
#   scan     a narrow arc reaches further; a wide one finds robots nearby
#   power    heavy shots hit harder for less battery, but fly slowly
#   battery  shots and driving share it, and it refills slowly
#   turret   it turns at a limited rate; state.self.aim is where it points now
#   cues     passive contacts (a ping, a scan beam, a shot heard) say which
#            way to look, not where to shoot: they have no id and a noisy
#            bearing, so cy.Nearest leaves them out
# Clunkyard robot API 2.0.0: one core under every language, the same
# answers everywhere. Facts (a call shows its arguments):
# match: mode ruleset control robots is_3d tick_rate max_ticks
#   robot_id(slot)
# clock: tick seconds remaining_ticks
# arena: size gravity terrain_kind ground_height(x y)
# me: health position velocity heading pitch roll angular_velocity
#   attitude grounded altitude applied
# battery: charge capacity regen sustainable_drive compute
#   drive_cost(fraction)
# drive: hover_lift
# gun: aim_now cooldown_ticks spread max_power damage_scale
#   can_fire(power reserve) shot_speed(power) shot_cost(power)
#   reload_ticks(power) shot_damage(power) power_for_speed(speed)
#   power_for_flight_time(range seconds) lead(contact power)
#   lead_point(position velocity power)
# scanner: last proximity_range reach(arc) arc_for_reach(range)
# sensors: contacts nearest cues contact(slot) position_of(contact)
# tracker: cue nearest_bearing_rate velocity(slot) position(slot)
#   last_seen(slot)
# nav: zone zone.margin(point) zone.contains(point margin)
#   zone.distance_from(point) storm storm.margin(point)
#   storm.contains(point margin) storm.distance_from(point) hill
#   hill.margin(point) hill.contains(point margin)
#   hill.distance_from(point) pickups nearest_pickup(kind)
#   field_distance(a b)
# score: me best armour
# angles: normalize(degrees) angle_diff(target current)
#   bearing_to(from to) elevation_to(from to) direction(heading pitch)
#   distance(a b) clamp(value low high)
# raw: number(path) text(path) has(path) flag(path) count(path) line()
# Controls: drive.set(throttle turn pitch_turn)
#   drive.forces(thrust strafe lift yaw_torque pitch_torque roll_torque brake)
#   gun.aim(heading pitch) gun.fire(power) scanner.set(heading arc pitch)
#   tracker.configure(smoothing forget_ticks cue_ticks)
#   status.set(text value) raw.extra(json)
# Every control argument is optional; a second call keeps what the first
# set. Absent facts are your language's none. Names are snake_case here;
# your language cases them its own way. Angles are degrees from the +x
# axis; pitch is positive up.
# Manual: https://clunkyard.com/manual#sdk
cy ← ⊑•args

searchTurn ← 0.33  # enough to turn against the brake in the force rulesets
free ← 0           # flying free, robots may be above or below

Start ⇐ {𝕊 game: free ↩ ("3d"≡game.match.mode)∧0=2⊑game.arena.gravity}

# The turn from heading h toward heading b, full once it is per degrees away.
Toward ← {h‿per 𝕊 b: cy.Clamp per÷˜b cy.AngleDiff h}

Track ← {game‿state 𝕊 c:
  me ← state.self ⋄ range ← c.range
  drive ← cy.Drive ⟨((range>350)+2×range<200)⊑0.2‿0.7‿¯0.4, me.heading‿45 Toward c.bearing, cy.Clamp 45÷˜c.elevation-me.pitch⟩
  scan ← cy.Scan c.bearing‿20‿c.elevation  # narrow: holds it, reaching about 735
  # The heaviest shot that still covers the range in about a second, aimed
  # where the target will be, lobbed under gravity.
  power ← game cy.PowerForFlightTime range
  h‿p ← 2↑(game‿state cy.Lead ⟨state cy.Position c, c.velocity, power⟩)∾c.bearing‿c.elevation
  onTarget ← (3>|h cy.AngleDiff me.aim.heading)∧3>|p-me.aim.pitch
  drive∾scan∾(cy.Aim h‿p)∾((onTarget∧game‿state cy.CanFire power‿10)/cy.Fire power)∾"TRACK" cy.Status range
}

# Head for where it was heard, sweeping an arc that still reaches it across
# the bearing's error (and, flying free, the elevation's).
FollowCue ← {game‿state 𝕊 cue:
  me ← state.self
  bearing ← me.position cy.BearingTo cue.position
  distance ← me.position cy.Distance cue.position
  elevation ← free×me.position cy.ElevationTo cue.position
  error ← 30⌊cue.bearingError
  across ← error×2÷˜2-˜5|state.tick
  up ← free×error×2÷˜1-˜3|⌊state.tick÷5
  (cy.Drive ⟨0.7, me.heading‿45 Toward bearing, cy.Clamp 45÷˜elevation-me.pitch⟩)∾(cy.Scan ⟨bearing+across, game cy.ArcForReach distance+100, elevation+up⟩)∾"CUE" cy.Status distance
}

# Sweeps the circle in half a second, flying free at three heights in turn.
Sweep ← {game‿state 𝕊 x:
  (cy.Drive ⟨0.5, searchTurn, cy.Clamp 45÷˜-state.self.pitch⟩)∾(cy.Scan ⟨360|state.scan.heading+36, 40, free×35×1-˜3|⌊state.tick÷10⟩)∾cy.Status "SEARCH"
}

Turn ⇐ {game 𝕊 state:
  me ← state.self ⋄ t ← cy.Nearest state
  act ← ("brake" cy.Set 0.2)∾{
    0≤t ? game‿state Track t⊑state.contacts ;
    state.hasCue ? game‿state FollowCue state.cue ;
    game‿state Sweep @
  }
  # Low battery: drive gently so the shots can still be paid for.
  act ∾↩ (me.battery<game.battery.capacity÷4)/cy.Drive 0.5×act cy.Get "throttle"
  # The storm hurts inside: drive straight away from its centre.
  act ∾↩ {state.hasStorm ? (state.storm‿60 cy.Contains me.position)/cy.Drive 0.8‿(me.heading‿30 Toward state.storm.center cy.BearingTo me.position) ; ⟨⟩}
  # Sudden death: head back inside the safe zone.
  act ∾ {state.hasZone ? z←state.zone ⋄ climb←("sphere"≡z.shape)×me.position cy.ElevationTo z.center ⋄
    (60>z cy.Margin me.position)/cy.Drive ⟨0.8, me.heading‿30 Toward me.position cy.BearingTo z.center, cy.Clamp 30÷˜climb-me.pitch⟩ ; ⟨⟩}
}
