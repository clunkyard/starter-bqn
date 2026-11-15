# A starter robot for rules v2, on the installed Clunkyard BQN adapter.
# It sweeps a medium scan to find a robot, or points it
# where a passive contact was heard, narrows the scan to hold it, leads it
# with shots whose power suits the range, fires only when the turret is on
# target, keeps battery back for driving and keeps out of the storm.
#
# Bearing is earned: a scan contact's bearing is off by up to its
# bearingError (degrees, a fixed share of the arc), so a wide beam finds a
# robot and a narrow one aims at it. The robot narrows the beam, holds it
# on the target and aims along a line fitted through its recent sightings.
# Contacts within 120 units are exact.
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
#   attitude grounded altitude applied hull_mounts to_mount(heading pitch)
#   from_mount(heading pitch) mount_toward(point)
# battery: charge capacity regen sustainable_drive compute
#   drive_cost(fraction)
# drive: hover_lift
# gun: aim_now cooldown_ticks spread max_power damage_scale
#   can_fire(power reserve) shot_speed(power) shot_cost(power)
#   reload_ticks(power) shot_damage(power) power_for_speed(speed)
#   power_for_flight_time(range seconds) lead(contact power)
#   lead_point(position velocity power)
# scanner: last proximity_range reach(arc) arc_for_reach(range) is_on
# sensors: contacts nearest cues contact(slot) position_of(contact)
# tracker: cue nearest_bearing_rate velocity(slot) position(slot)
#   history(slot) last_seen(slot)
# nav: zone zone.margin(point) zone.contains(point margin)
#   zone.distance_from(point) storm storm.margin(point)
#   storm.contains(point margin) storm.distance_from(point) hill
#   hill.margin(point) hill.contains(point margin)
#   hill.distance_from(point) pickups nearest_pickup(kind)
#   field_distance(a b)
# score: me best armour
# angles: normalize(degrees) angle_diff(target current)
#   bearing_to(from to) elevation_to(from to) direction(heading pitch)
#   distance(a b) to_chassis(heading pitch attitude)
#   from_chassis(heading pitch attitude) clamp(value low high)
# raw: number(path) text(path) has(path) flag(path) count(path) line()
# Controls: drive.set(throttle turn pitch_turn)
#   drive.forces(thrust strafe lift yaw_torque pitch_torque roll_torque brake)
#   gun.aim(heading pitch) gun.fire(power) scanner.set(heading arc pitch)
#   scanner.power(on) tracker.configure(smoothing forget_ticks cue_ticks)
#   status.set(text value) raw.extra(json)
# Every control argument is optional; a second call keeps what the first
# set. Absent facts are your language's none. Names are snake_case here;
# your language cases them its own way. Angles are degrees from the +x
# axis; pitch is positive up.
# Manual: https://clunkyard.com/manual#sdk
cy ← ⊑•args

searchTurn ← 0.33  # enough to turn against the brake in the force rulesets
searchArc ← 40     # degrees: sweeps the circle in half a second
holdWidth ← 60     # units across at the target: it stays in the beam from tick to tick
minArc ← 6         # degrees: the narrowest the beam holds
window ← 12        # ticks of sightings the aim averages
sightings ← 8      # narrow sightings in the window before a shot
lookEvery ← 40     # ticks between looks around the target, for a nearer robot
reacquireTicks ← 10  # ticks to look again where a lost target was
free ← 0           # flying free, robots may be above or below
slot ← 0           # the last target's slot, for looking again where it was lost
# Dodges taken, and the tick the current one ends.
dodges ← 0 ⋄ dodgeEnd ← 0

Start ⇐ {𝕊 game: free ↩ ("3d"≡game.match.mode)∧0=2⊑game.arena.gravity}

# The turn from heading h toward heading b, full once it is per degrees away.
Toward ← {h‿per 𝕊 b: cy.Clamp per÷˜b cy.AngleDiff h}

# A straight line through the narrowest of the last window ticks' sightings:
# ⟨where the robot is now, how fast it moves, how many sightings it rests on⟩,
# or @ for fewer than two. Each sighting is off by its bearingError; the line
# averages that out. Positions form a table, a row each, so one sum fits all three axes.
Fit ← {tick‿rate 𝕊 slot:
  history ← cy.TrackerHistory slot
  recent ← ((tick-window)<{𝕩.tick}¨history)/history
  error ← {𝕩.bearingError}¨recent
  seen ← (error≤1.5×⌊´error)/recent  # the narrow ones
  {2>≠seen ? @ ;
    ticks ← {𝕩.tick}¨seen ⋄ t0 ← (+´ticks)÷≠seen
    dt ← ticks-t0
    positions ← >{𝕩.position}¨seen
    slope ← (+˝dt×positions)÷+´dt×dt  # per tick: the ticks about their mean sum to zero
    ⟨((+˝positions)÷≠seen)+slope×tick-t0, slope×rate, ≠seen⟩}
}

Track ← {game‿state 𝕊 c:
  me ← state.self ⋄ range ← c.range ⋄ slot ↩ c.slot
  drive ← cy.Drive ⟨((range>350)+2×range<200)⊑0.2‿0.7‿¯0.4, me.heading‿45 Toward c.bearing, cy.Clamp 45÷˜c.elevation-me.pitch⟩
  # Halve the beam each tick until it is holdWidth across at the target: narrow
  # enough for a precise bearing, wide enough to keep it in. In a crowd a narrow
  # beam sees one robot: every lookEvery ticks, widen it for a tick, and a
  # nearer robot it finds becomes the target.
  hold ← minArc⌈(360÷π)×•math.Atan (holdWidth÷2)÷range
  arc ← {0=lookEvery|state.tick ? searchArc ; hold⌈searchArc⌊2÷˜state.scan.arc}
  scan ← cy.Scan c.bearing‿arc‿c.elevation
  # The heaviest shot that still covers the range in about a second, aimed
  # where the target will be, lobbed under gravity.
  power ← game cy.PowerForFlightTime range
  # An exact contact: cy.Lead is the intercept if the target holds course. A
  # noisy one: lead the fitted line, and fire only once it rests on enough sightings.
  noisy ← 0<c.bearingError
  line ← {noisy ? ⟨state.tick, game.match.tickRate⟩ Fit c.slot ; @}
  ready ← (¬noisy)∨{@≡line ? 0 ; sightings≤2⊑line}
  aim ← {noisy ? {@≡line ? ⟨⟩ ; game‿state cy.Lead (2↑line)∾⟨power⟩} ; game‿state cy.Lead ⟨state cy.Position c, c.velocity, power⟩}
  h‿p ← 2↑aim∾c.bearing‿c.elevation
  onTarget ← (3>|h cy.AngleDiff me.aim.heading)∧3>|p-me.aim.pitch
  drive∾scan∾(cy.Aim h‿p)∾((ready∧onTarget∧game‿state cy.CanFire power‿10)/cy.Fire power)∾(ready⊑"NARROW"‿"TRACK") cy.Status range
}

# Lost it: look again where it was last seen, widening the beam, before searching.
Reacquire ← {game‿state 𝕊 remembered:
  me ← state.self
  where ← (@≡remembered)⊑remembered‿me.position
  bearing ← me.position cy.BearingTo where
  elevation ← free×me.position cy.ElevationTo where
  (cy.Drive ⟨0.5, me.heading‿45 Toward bearing, cy.Clamp 45÷˜elevation-me.pitch⟩)∾(cy.Scan ⟨bearing, searchArc⌊2×state.scan.arc, elevation⟩)∾cy.Status "REACQUIRE"
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
  (cy.Drive ⟨0.5, searchTurn, cy.Clamp 45÷˜-state.self.pitch⟩)∾(cy.Scan ⟨360|state.scan.heading+36, searchArc, free×35×1-˜3|⌊state.tick÷10⟩)∾cy.Status "SEARCH"
}

Turn ⇐ {game 𝕊 state:
  me ← state.self ⋄ t ← cy.Nearest state
  seen ← {0=slot ? @ ; cy.TrackerLastSeen slot}
  lost ← {@≡seen ? 0 ; reacquireTicks≥state.tick-seen}
  act ← ("brake" cy.Set 0.2)∾{
    0≤t ? game‿state Track t⊑state.contacts ;
    lost ? game‿state Reacquire cy.TrackerPosition slot ;
    state.hasCue ? game‿state FollowCue state.cue ;
    game‿state Sweep @
  }
  # A simple dodge: vary it, or predict the shooter. A shot heard once the
  # last dodge is over starts the next for 10 ticks.
  {(state.tick≥dodgeEnd)∧∨´{"muzzle"≡𝕩.source}¨state.contacts ? dodges +↩ 1 ⋄ dodgeEnd ↩ state.tick+10 ; @}
  # Off the line of fire: left, then right next time (turn is positive left, strafe positive right).
  side ← ¯1⋆1+2|dodges  # 1 left, ¯1 right
  move ← {"forces"≡game.match.control ? (cy.Drive ⟨0.5⟩)∾"strafe" cy.Set -side ; cy.Drive 1‿side}
  act ∾↩ (state.tick<dodgeEnd)/move∾("dodge:"∾(side=1)⊑"right"‿"left") cy.Status dodges
  # Low battery: drive gently so the shots can still be paid for.
  act ∾↩ (me.battery<game.battery.capacity÷4)/cy.Drive 0.5×act cy.Get "throttle"
  # The storm hurts inside: drive straight away from its centre.
  act ∾↩ {state.hasStorm ? (state.storm‿60 cy.Contains me.position)/cy.Drive 0.8‿(me.heading‿30 Toward state.storm.center cy.BearingTo me.position) ; ⟨⟩}
  # Sudden death: head back inside the safe zone.
  act ∾ {state.hasZone ? z←state.zone ⋄ climb←("sphere"≡z.shape)×me.position cy.ElevationTo z.center ⋄
    (60>z cy.Margin me.position)/cy.Drive ⟨0.8, me.heading‿30 Toward me.position cy.BearingTo z.center, cy.Clamp 30÷˜climb-me.pitch⟩ ; ⟨⟩}
}
