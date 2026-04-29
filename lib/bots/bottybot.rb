require 'bots/bot'

# BottyBot is a closing-range intercept-aim bot.
#
# Strategy:
#   - Pursue the closest visible contact, driving directly at it.
#   - Track the target's velocity (EMA of position deltas) and solve a
#     decay-aware bullet intercept to lead shots.
#   - Hold fire when the intercept solution is unreachable (target moving
#     away faster than the bullet can catch, or beyond effective range).
#   - If we fail to damage the target for too long ("kited"), enter a
#     temporary disengage phase: pick another target if available, or
#     strafe perpendicular to break the chase pattern.
#   - Avoid walls by steering back toward the arena centre when within
#     a buffer zone of the play area edges.
#   - Detect being stuck (low movement over time) and break out with a
#     short randomised hard-turn manoeuvre.
class BottyBot < BattleBots::Bots::Bot
  # --- Movement / aim tuning ----------------------------------------------
  TURN_RATE             = 3      # degrees/tick chassis turn rate
  ALIGN_TOL_DEG         = 2      # turret must be within this of target before firing
  SCAN_AIM_RATE         = 15     # turret sweep rate while searching

  # --- Wall avoidance / unstick ------------------------------------------
  WALL_BUFFER           = 150    # px from playable edge that triggers steer-to-centre
  STUCK_THRESHOLD       = 1.5    # px/tick movement below which we count as "not moving"
  STUCK_TICKS           = 30     # consecutive stuck ticks before triggering unstick
  UNSTICK_DURATION      = 25     # ticks to spend in hard-turn unstick mode

  # --- Engagement / disengagement -----------------------------------------
  GIVE_UP_TICKS         = 180    # consecutive ticks engaging same target with no damage dealt
  DISENGAGE_TICKS       = 90     # cooldown duration after giving up on a target
  TARGET_MATCH_RADIUS   = 220    # px tolerance for matching last tick's lock to a contact
  BLACKLIST_RADIUS      = 300    # px around the runaway target to deprioritise during cooldown

  # --- Ballistics model ---------------------------------------------------
  BULLET_DECAY          = 0.95   # matches lib/bullets.rb (vel *= 0.95 per tick)
  ONE_MINUS_DECAY       = 1.0 - BULLET_DECAY
  MIN_IMPACT_VELOCITY   = 8.0    # below this we deem the shot not worth firing
  LEAD_VEL_EMA          = 0.6    # smoothing factor for enemy velocity estimate
  OWN_VEL_EMA           = 0.6    # smoothing factor for our own velocity estimate
  INTERCEPT_ITERATIONS  = 6      # max iterations for fixed-point intercept solver
  INTERCEPT_TOLERANCE   = 0.05   # ticks; convergence threshold for solver

  # Tags this bot's name colour in the UI. Returns one of :ai, :human, :builtin.
  def self.bot_source = :ai

  # Sets bot identity and skill matrix (must sum to 100), and zeroes all
  # per-tick state used across ticks (velocity estimates, lock, counters).
  def initialize
    @name = "BottyBot"
    @speed, @strength, @stamina, @sight = [42, 38, 10, 10]

    @last_x = @last_y = nil
    @own_vx = @own_vy = 0.0
    @stuck_counter = @unstick_ticks = 0
    @unstick_turn = 1

    @lock_x = @lock_y = @lock_health = nil
    @lock_vx = @lock_vy = 0.0
    @no_progress_ticks = @disengage_ticks = 0
    @blacklist_x = @blacklist_y = nil
    @strafe_dir = 1

    @turn = @drive = @aim = 0
    @shoot = false
  end

  # Per-tick decision pipeline called by the Proxy after observe().
  # Order matters:
  #   1. track_self     — updates own velocity estimate and stuck counter.
  #   2. unstick_step   — if currently in an unstick phase, apply that and skip the rest.
  #   3. pick_target    — choose closest visible enemy (with disengagement filter).
  #   4. update_lock    — update target velocity EMA and progress tracking.
  #   5. drive/strafe   — chase or break-pattern movement.
  #   6. aim_at         — compute lead intercept and decide whether to fire.
  #   7. avoid_walls    — overrides @turn/@drive if we're close to a wall.
  def think
    track_self

    if @unstick_ticks > 0
      unstick_step
      return
    end

    enemy = pick_target
    if enemy
      update_lock(enemy)
      bearing, distance = calculate_vector_to(enemy)
      disengaging_against?(enemy) ? strafe(bearing) : drive_toward(bearing)
      aim_at(enemy, distance)
    else
      clear_lock
      patrol
    end

    avoid_walls
  end

  private

  # Updates own velocity estimate (EMA) from position deltas, and tracks
  # whether we're moving enough to be considered "not stuck". When
  # stuck_counter exceeds STUCK_TICKS, schedules an unstick phase with a
  # randomised turn direction.
  def track_self
    if @last_x
      raw_vx  = @x - @last_x
      raw_vy  = @y - @last_y
      @own_vx = OWN_VEL_EMA * raw_vx + (1 - OWN_VEL_EMA) * @own_vx
      @own_vy = OWN_VEL_EMA * raw_vy + (1 - OWN_VEL_EMA) * @own_vy
      moved   = Math.sqrt(raw_vx * raw_vx + raw_vy * raw_vy)
      @stuck_counter = moved < STUCK_THRESHOLD ? @stuck_counter + 1 : 0
    end
    @last_x = @x
    @last_y = @y

    if @stuck_counter >= STUCK_TICKS
      @unstick_ticks = UNSTICK_DURATION
      @unstick_turn  = [-1, 1].sample
      @stuck_counter = 0
    end
  end

  # Hard-turn manoeuvre to escape getting wedged against a wall or another bot.
  # Drives forward while spinning chassis and turret in the same direction.
  # Decrements remaining duration so think() returns to normal logic when done.
  def unstick_step
    @drive = 1
    @turn  = @unstick_turn * TURN_RATE
    @aim   = @unstick_turn * SCAN_AIM_RATE
    @shoot = false
    @unstick_ticks -= 1
  end

  # Idle behaviour when no enemy is visible: drive toward arena centre while
  # sweeping the turret to acquire a contact.
  def patrol
    bearing_to_center, _ = calculate_vector_to(x: @arena_width / 2.0, y: @arena_height / 2.0)
    @drive = 1
    @turn  = turn_toward(bearing_to_center)
    @aim   = SCAN_AIM_RATE
    @shoot = false
  end

  # Drive straight at the given bearing.
  def drive_toward(bearing)
    @drive = 1
    @turn  = turn_toward(bearing)
  end

  # Drive perpendicular to the bearing (90° off in @strafe_dir direction).
  # Used during disengagement against a kiter when no other target is available.
  # Turret aim is handled separately by aim_at, so we keep firing on target.
  def strafe(bearing_to_enemy)
    perpendicular = (bearing_to_enemy + 90 * @strafe_dir) % 360
    @drive = 1
    @turn  = turn_toward(perpendicular)
  end

  # True when we're inside the disengagement window AND the supplied enemy
  # is the one we blacklisted. Used to switch from chase to strafe.
  def disengaging_against?(enemy)
    return false unless @disengage_ticks > 0 && @blacklist_x
    dist_to(enemy[:x], enemy[:y], @blacklist_x, @blacklist_y) < BLACKLIST_RADIUS
  end

  # Decay-aware iterative intercept. Returns [aim_x, aim_y, t] or nil.
  #
  # Bullet flies on a fixed bearing β with cumulative distance after t ticks
  #   S(t) = v0 * (1 - decay^t) / (1 - decay)
  # We want S(t) = |E(t) - P| where E(t) = E0 + Ev*t.
  # Iterate: pick t, compute predicted enemy point and its distance d, then
  # invert S to find how long the bullet really takes to cover d:
  #   t = log(1 - d * (1 - decay) / v0) / log(decay)
  # Returns nil if the bullet can never reach the predicted point regardless
  # of time (target outrunning the bullet's max range). Converges in ~3-4
  # iterations for normal closing geometry.
  def solve_intercept(enemy, v0)
    dx0 = enemy[:x] - @x
    dy0 = enemy[:y] - @y
    t   = Math.sqrt(dx0 * dx0 + dy0 * dy0) / v0

    INTERCEPT_ITERATIONS.times do
      px = enemy[:x] + @lock_vx * t
      py = enemy[:y] + @lock_vy * t
      d  = Math.sqrt((px - @x)**2 + (py - @y)**2)

      reach_ratio = d * ONE_MINUS_DECAY / v0
      return nil if reach_ratio >= 1.0

      t_new = Math.log(1.0 - reach_ratio) / Math.log(BULLET_DECAY)
      diff  = (t_new - t).abs
      t     = t_new
      break if diff < INTERCEPT_TOLERANCE
    end

    [enemy[:x] + @lock_vx * t, enemy[:y] + @lock_vy * t, t]
  end

  # Sets @aim and @shoot based on the intercept solver result. Fires only when:
  #   - intercept solution exists (target catchable),
  #   - flight time within max_flight_ticks (bullet still has damaging velocity),
  #   - predicted aim point within effective range,
  #   - turret aligned to within ALIGN_TOL_DEG of bearing.
  # Falls back to direct aim (without firing) if no intercept solution.
  def aim_at(enemy, _distance)
    bs       = effective_bullet_speed
    max_t    = max_flight_ticks(bs)
    max_dist = effective_range(bs)
    result   = solve_intercept(enemy, bs)

    if result && result[2] <= max_t
      aim_x, aim_y, _t = result
      bearing, predicted_distance = calculate_vector_to(x: aim_x, y: aim_y)
      worth_shot = predicted_distance < max_dist
    else
      bearing, _ = calculate_vector_to(enemy)
      worth_shot = false
    end

    delta   = signed_delta(@turret, bearing)
    @aim    = delta
    @shoot  = worth_shot && delta.abs < ALIGN_TOL_DEG
  end

  # Estimated bullet launch speed in px/tick.
  # Base = 100 * normalised_strength (proxy normalises skills by their sum).
  # Bullet x/y velocity components get +|own_vx|/|own_vy| added before the
  # turret cosine in lib/proxy.rb#fire!, so true speed depends on turret
  # bearing — we approximate with the average of |own_vx| and |own_vy|.
  def effective_bullet_speed
    total = (@speed + @strength + @stamina + @sight).to_f
    return 0.0 if total <= 0
    base  = 100.0 * (@strength / total)
    boost = (@own_vx.abs + @own_vy.abs) * 0.5
    base + boost
  end

  # Ticks until bullet velocity decays below MIN_IMPACT_VELOCITY:
  #   v0 * decay^t = v_min  =>  t = log(v_min/v0) / log(decay)
  def max_flight_ticks(v0)
    return 0 if v0 <= MIN_IMPACT_VELOCITY
    Math.log(MIN_IMPACT_VELOCITY / v0) / Math.log(BULLET_DECAY)
  end

  # Distance covered before bullet velocity drops to MIN_IMPACT_VELOCITY:
  #   sum_{i=0..t-1} v0 * decay^i  =  (v0 - v_min) / (1 - decay)
  def effective_range(v0)
    return 0 if v0 <= MIN_IMPACT_VELOCITY
    (v0 - MIN_IMPACT_VELOCITY) / ONE_MINUS_DECAY
  end

  # If we're inside WALL_BUFFER of any playable edge, override @turn/@drive
  # to steer back toward arena centre. Called after target/movement logic so
  # it always wins — prevents charging into corners while pursuing.
  def avoid_walls
    margin = [@arena_margin, 0].max
    return if @x.between?(margin + WALL_BUFFER, @arena_width  - margin - WALL_BUFFER) &&
              @y.between?(margin + WALL_BUFFER, @arena_height - margin - WALL_BUFFER)

    bearing_to_center, _ = calculate_vector_to(x: @arena_width / 2.0, y: @arena_height / 2.0)
    @turn  = turn_toward(bearing_to_center)
    @drive = 1
  end

  # Selects the closest visible contact, with a disengagement filter:
  # during a give-up cooldown, contacts within BLACKLIST_RADIUS of the
  # blacklisted (kiting) enemy's last known position are excluded — but
  # only if other contacts are available, so 1v1 still engages.
  # Decrements the cooldown timer and clears the blacklist when it expires.
  def pick_target
    @disengage_ticks -= 1 if @disengage_ticks > 0
    candidates = @contacts

    if @disengage_ticks > 0 && @blacklist_x && candidates.size > 1
      filtered = candidates.reject { |c| dist_to(c[:x], c[:y], @blacklist_x, @blacklist_y) < BLACKLIST_RADIUS }
      candidates = filtered unless filtered.empty?
    elsif @disengage_ticks <= 0
      @blacklist_x = @blacklist_y = nil
    end

    candidates.min_by { |c| (c[:x] - @x)**2 + (c[:y] - @y)**2 }
  end

  # Updates target tracking state. Identifies "same target" across ticks by
  # proximity to last lock position (since contacts have no IDs).
  # When same target is matched:
  #   - Computes raw velocity (position delta) and feeds it into the EMA.
  #   - If target's health dropped, resets no_progress_ticks (we hit them).
  #   - Otherwise increments — used for the give-up trigger.
  # When new/no target: resets velocity and progress counter.
  # If no_progress_ticks crosses GIVE_UP_TICKS, enters disengagement phase:
  # blacklists the runaway, picks a random strafe direction, clears lock.
  def update_lock(enemy)
    if @lock_x && dist_to(enemy[:x], enemy[:y], @lock_x, @lock_y) < TARGET_MATCH_RADIUS
      raw_vx = enemy[:x] - @lock_x
      raw_vy = enemy[:y] - @lock_y
      @lock_vx = LEAD_VEL_EMA * raw_vx + (1 - LEAD_VEL_EMA) * @lock_vx
      @lock_vy = LEAD_VEL_EMA * raw_vy + (1 - LEAD_VEL_EMA) * @lock_vy

      if @lock_health && enemy[:health] < @lock_health - 0.1
        @no_progress_ticks = 0
      else
        @no_progress_ticks += 1
      end
    else
      @lock_vx = @lock_vy = 0.0
      @no_progress_ticks = 0
    end

    @lock_x      = enemy[:x]
    @lock_y      = enemy[:y]
    @lock_health = enemy[:health]

    if @no_progress_ticks >= GIVE_UP_TICKS
      @disengage_ticks   = DISENGAGE_TICKS
      @blacklist_x       = enemy[:x]
      @blacklist_y       = enemy[:y]
      @strafe_dir        = [-1, 1].sample
      @no_progress_ticks = 0
      @lock_x = @lock_y = @lock_health = nil
      @lock_vx = @lock_vy = 0.0
    end
  end

  # Resets all target-related state. Called when no enemy is visible so we
  # don't carry stale velocity estimates into the next acquisition.
  def clear_lock
    @lock_x = @lock_y = @lock_health = nil
    @lock_vx = @lock_vy = 0.0
    @no_progress_ticks = 0
  end

  # Euclidean distance between two points.
  def dist_to(ax, ay, bx, by)
    Math.sqrt((ax - bx)**2 + (ay - by)**2)
  end

  # Shortest signed angular delta from `from` to `to` in degrees, in [-180, 180].
  # Positive means clockwise (matches the engine's convention: @heading += @turn
  # rotates clockwise, @turret += @aim rotates clockwise).
  def signed_delta(from, to)
    d = (to - from) % 360
    d > 180 ? d - 360 : d
  end

  # Returns ±TURN_RATE for the chassis, sign chosen so the heading rotates
  # toward the given bearing along the shorter arc.
  def turn_toward(bearing)
    signed_delta(@heading, bearing).positive? ? TURN_RATE : -TURN_RATE
  end
end
