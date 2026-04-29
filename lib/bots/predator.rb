require 'bots/bot'

# Predicts enemy movement, leads its shots at the intercept point, orbits at weapon
# range, and reverses strafe direction whenever it takes a hit.
class Predator < BattleBots::Bots::Bot
  def self.bot_source
    :ai
  end

  SPEED_PCT    = 30
  STRENGTH_PCT = 30
  STAMINA_PCT  = 30
  SIGHT_PCT    = 10

  BULLET_DECAY    = 0.95
  TRACK_TIMEOUT   = 90
  MATCH_RADIUS    = 100.0

  # Range bounds the orbital controller is allowed to pick between. The actual
  # preferred range is computed each frame from observed opponent behaviour — we
  # only constrain it to the band where our weapon is still effective and we are
  # close enough to provoke an exchange.
  MIN_RANGE     = 220.0
  DEFAULT_RANGE = 280.0
  COLD_START_RANGE = 380.0  # just inside the typical <400 fire trigger, so we provoke signal both ways
  # Past this our own bullets have decayed too far to bite. Stays just inside
  # effective_range so the clamp can't shove us back into the opponent's fire range.
  MAX_RANGE     = 460.0

  # The observed impact distance is *less* than where the opponent fired from
  # because their bullet flew while they (and we) kept moving. This buffer covers
  # bullet-flight closure plus a margin for our own orbital drift.
  FIRE_RANGE_BUFFER = 70.0

  # Minimum cumulative damage we treat as "real" signal (filters out noise from
  # a single graze before we change strategy). Describes the data, not any bot.
  SIGNAL_HP = 5.0

  def initialize
    @name = 'Predator'
    @speed = SPEED_PCT
    @strength = STRENGTH_PCT
    @stamina = STAMINA_PCT
    @sight = SIGHT_PCT
    @tracks = []
    @tick = 0
    @evade_dir = 1
    @last_health = 100.0
    @last_evade_flip_tick = 0

    # Opponent profile, built from observed signals only. No assumptions about
    # which bot we're facing — every value below comes from what we measure.
    @opponent_last_health = nil
    @damage_dealt_total = 0.0
    @damage_taken_total = 0.0
    @max_observed_fire_distance = 0.0  # furthest distance at which we've taken a hit
    @incoming_bullet_speed_ema = 0.0   # rolling estimate of their bullet velocity at impact
  end

  def think
    @tick += 1
    update_tracks
    update_combat_signals
    target = pick_target

    if target
      engage(target)
    else
      patrol
    end

    avoid_walls_if_near
    @last_health = @health
  end

  private

  def bullet_v0
    100.0 * STRENGTH_PCT / 100.0
  end

  def bullet_max_distance
    bullet_v0 / (1.0 - BULLET_DECAY)
  end

  # Below this distance the bullet's velocity is still well above the 5 px/tick decay
  # cutoff, so it actually arrives and deals appreciable damage.
  def effective_range
    bullet_max_distance * 0.78
  end

  # ----- enemy tracking -----

  def update_tracks
    matched = Array.new(@tracks.size, false)
    new_tracks = []

    @contacts.each do |contact|
      idx = nearest_track_index(contact, matched)
      if idx
        matched[idx] = true
        new_tracks << update_track(@tracks[idx], contact)
      else
        new_tracks << new_track(contact)
      end
    end

    @tracks.each_with_index do |prev, i|
      next if matched[i] || @tick - prev[:tick] > TRACK_TIMEOUT

      stale = prev.dup
      stale[:stale] = true
      new_tracks << stale
    end

    @tracks = new_tracks
  end

  def nearest_track_index(contact, matched)
    best_i = nil
    best_d = MATCH_RADIUS
    @tracks.each_with_index do |t, i|
      next if matched[i]

      d = Math.hypot(t[:x] - contact[:x], t[:y] - contact[:y])
      if d < best_d
        best_d = d
        best_i = i
      end
    end
    best_i
  end

  def update_track(prev, contact)
    dt = [@tick - prev[:tick], 1].max
    nvx = (contact[:x] - prev[:x]).to_f / dt
    nvy = (contact[:y] - prev[:y]).to_f / dt
    a = 0.5
    {
      x: contact[:x],
      y: contact[:y],
      vx: prev[:vx] * (1 - a) + nvx * a,
      vy: prev[:vy] * (1 - a) + nvy * a,
      health: contact[:health],
      heading: contact[:heading],
      turret: contact[:turret],
      tick: @tick,
      stale: false
    }
  end

  def new_track(contact)
    {
      x: contact[:x],
      y: contact[:y],
      vx: 0.0,
      vy: 0.0,
      health: contact[:health],
      heading: contact[:heading],
      turret: contact[:turret],
      tick: @tick,
      stale: false
    }
  end

  # ----- target selection -----

  def pick_target
    fresh = @tracks.reject { |t| t[:stale] }
    return nil if fresh.empty?

    if @health < 35.0
      fresh.min_by { |t| t[:health] }
    else
      fresh.min_by { |t| Math.hypot(t[:x] - @x, t[:y] - @y) }
    end
  end

  # ----- engagement -----

  def engage(target)
    px, py = predict_intercept(target)
    distance = Math.hypot(target[:x] - @x, target[:y] - @y)
    bearing = bearing_to(px, py)
    snap_turret_to(bearing)

    # snap_turret_to puts the turret on bearing within this same tick (Proxy applies
    # @aim before fire!), so once we've decided to engage we just need to be in range.
    @shoot = distance < effective_range

    move_to_engage(target)
  end

  def predict_intercept(track)
    px = track[:x]
    py = track[:y]
    4.times do
      d = Math.hypot(px - @x, py - @y)
      return [track[:x], track[:y]] if d >= bullet_max_distance * 0.99

      t = Math.log(1.0 - d / bullet_max_distance) / Math.log(BULLET_DECAY)
      px = track[:x] + track[:vx] * t
      py = track[:y] + track[:vy] * t
    end
    [px, py]
  end

  def bearing_to(x, y)
    arctan = Math.atan2(y - @y, x - @x) / Math::PI * 180.0
    arctan > 0 ? arctan + 90.0 : (arctan + 450.0) % 360.0
  end

  def angle_diff(from, to)
    d = (to - from) % 360.0
    d > 180.0 ? d - 360.0 : d
  end

  # Proxy#limit only clamps positive @aim against the +speed*10 cap; negative @aim
  # is unbounded. Setting @aim to the CCW arc to the bearing snaps the turret onto
  # target in a single tick.
  def snap_turret_to(bearing)
    @aim = -((@turret - bearing) % 360.0)
  end

  # ----- movement -----

  def move_to_engage(target)
    distance = Math.hypot(target[:x] - @x, target[:y] - @y)
    target_bearing = bearing_to(target[:x], target[:y])
    closure = opponent_closure_rate(target, distance)

    desired = orbit_heading(target_bearing, distance, adaptive_preferred_range, closure)
    update_evade_direction
    turn_heading_to(desired)
    @drive = 1
  end

  # Project the opponent's velocity onto our line of sight. Positive return value
  # means they are moving toward us — we use it to bias the orbit outward enough
  # to cancel their closure at the preferred distance.
  def opponent_closure_rate(track, distance)
    return 0.0 if distance < 1.0

    -((track[:vx] * (track[:x] - @x) + track[:vy] * (track[:y] - @y)) / distance)
  end

  # Picks a heading that holds the preferred range against an opponent that is
  # itself trying to close. The base offset is acos(-closure/my_speed), so at
  # preferred distance the radial component of our velocity exactly cancels their
  # closure rate. Distance error then biases us further inward or outward.
  def orbit_heading(target_bearing, distance, preferred, closure)
    closure_ratio = (closure / MY_TERMINAL_SPEED).clamp(-0.85, 0.85)
    base_offset = Math.acos(-closure_ratio) * 180.0 / Math::PI
    d_diff = distance - preferred
    offset_deg = base_offset - 90.0 * Math.tanh(d_diff / 50.0)
    (target_bearing + offset_deg * @evade_dir) % 360.0
  end

  MY_TERMINAL_SPEED = SPEED_PCT / 100.0 * 10.0

  # ----- opponent profiling -----

  # Reads three direct signals every tick: damage we took, damage we dealt, and
  # the distance at which incoming hits arrived. From these we infer the opponent's
  # effective fire range and roughly how hard they punch, with no assumption about
  # which bot is on the other side.
  def update_combat_signals
    record_incoming_damage
    record_outgoing_damage
  end

  def record_incoming_damage
    return unless @last_health && @health < @last_health - 0.001

    drop = @last_health - @health
    @damage_taken_total += drop

    nearest_d = @contacts.map { |c| Math.hypot(c[:x] - @x, c[:y] - @y) }.min
    return unless nearest_d

    @max_observed_fire_distance = [@max_observed_fire_distance, nearest_d].max

    # Damage = bullet_speed_at_impact * (1 - my_stamina) / 5  →  invert for the speed.
    inferred_speed = drop * 5.0 / (1.0 - my_stamina_v)
    @incoming_bullet_speed_ema = if @incoming_bullet_speed_ema.zero?
                                   inferred_speed
                                 else
                                   @incoming_bullet_speed_ema * 0.5 + inferred_speed * 0.5
                                 end
  end

  def record_outgoing_damage
    target = @contacts.first
    return unless target

    if @opponent_last_health && target[:health] < @opponent_last_health - 0.001
      @damage_dealt_total += @opponent_last_health - target[:health]
    end
    @opponent_last_health = target[:health]
  end

  def my_stamina_v
    STAMINA_PCT / 100.0
  end

  # Pick a preferred orbit range from the inferred opponent profile. Three regimes:
  #
  #   1. Cold start: no exchange yet → moderate range that invites both sides to fire.
  #   2. Kite zone exists: opponent's furthest observed fire distance + buffer is still
  #      inside our effective range → sit there, we hit them, they don't hit us.
  #   3. No kite zone: their reach exceeds ours → pick by cumulative damage trade.
  def adaptive_preferred_range
    # Once we have a single observed incoming hit, we know roughly how far the
    # opponent is firing from. Build a kite range from that.
    if @max_observed_fire_distance.positive?
      kite_floor = @max_observed_fire_distance + FIRE_RANGE_BUFFER

      if kite_floor < MAX_RANGE
        # Genuine kite zone: their reach + buffer fits inside our effective range.
        return kite_floor.clamp(MIN_RANGE, MAX_RANGE)
      end

      # Their reach exceeds ours. Kiting can't take us out of fire — sit at
      # default range where our own bullets still bite hard. Brute trade.
      return DEFAULT_RANGE
    end

    # No incoming hits yet. If we're already landing damage, hold default range.
    return DEFAULT_RANGE if @damage_dealt_total >= SIGNAL_HP

    # Neither side has scored yet — provoke the exchange at cold-start range.
    COLD_START_RANGE
  end

  # Flip strafe direction primarily in response to taking damage (breaks any lead
  # the opponent has on us), with a slow periodic flip as a fallback. 180° heading
  # swings interrupt distance maintenance, so we keep them rare.
  def update_evade_direction
    if @health < @last_health && @tick - @last_evade_flip_tick > 12
      @evade_dir = -@evade_dir
      @last_evade_flip_tick = @tick
    elsif (@tick % 180).zero?
      @evade_dir = -@evade_dir
    end
  end

  # Proportional control: closer to target heading → smaller correction. Capped so a
  # large bearing swing doesn't slam the heading round and break orbital geometry.
  TURN_RATE_CAP = 6.0

  def turn_heading_to(desired)
    diff = angle_diff(@heading, desired)
    @turn = diff.clamp(-TURN_RATE_CAP, TURN_RATE_CAP)
  end

  def patrol
    @drive = 1
    @aim = -20.0
    cx = @arena_width * 0.5
    cy = @arena_height * 0.5
    if Math.hypot(cx - @x, cy - @y) > 200
      turn_heading_to(bearing_to(cx, cy))
    else
      @turn = 1
    end
    @shoot = false
  end

  def avoid_walls_if_near
    margin = @arena_margin.to_f
    border = 130.0
    near = @x < margin + border ||
           @x > @arena_width - margin - border ||
           @y < margin + border ||
           @y > @arena_height - margin - border
    return unless near

    cx = @arena_width * 0.5
    cy = @arena_height * 0.5
    turn_heading_to(bearing_to(cx, cy))
    @drive = 1
  end
end
