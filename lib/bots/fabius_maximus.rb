require 'bots/bot'

# Fabius Maximus. Wins by attrition under the 60s timeout rule:
# stay ahead on health, deny the opponent clean shots, escalate only if the
# clock will draw both bots if we do nothing.
#
# Phase selection is driven entirely by the timeout's tiebreaker (best health
# wins; full-health tie = draw = both eliminated).
#
#   FLEE  – ahead on health: run diagonally away, tail-gun, defend the lead.
#   ORBIT – default: circle the enemy at our bullet's effective range, never
#           presenting a stationary or straight-line target. Random direction
#           flips defeat predictive aim.
#   HUNT  – RARE. Only fires for the mirror-stalemate breakout (both bots
#           still at full health near the time limit, where doing nothing
#           draws and eliminates us).
class FabiusMaximus < BattleBots::Bots::Bot
  # Toggle the NaN-position exploit. When true, once we have a confirmed
  # health lead we set @drive = Float::NAN, which pollutes @x/@y to NaN in
  # Proxy#move_bot. NaN comparisons fail, so the boundary clamp, the
  # bullet-distance check, and the enemy's visibility cone all return false
  # — we become untargetable until the timeout, which we win on health.
  # Flip to false to A/B against the clean strategy.
  PHANTOM_MODE = true

  WALL_BUFFER          = 100
  ENGAGE_DISTANCE      = 1200
  # At strength 30, our bullets decay below threshold around ~500 units.
  # Sit just inside that band so our shots land while opposing builds with
  # higher strength still have to track us.
  ORBIT_DISTANCE_MIN   = 280
  ORBIT_DISTANCE_MAX   = 460
  TURRET_LOCK_DEG      = 6
  PREDICT_HORIZON      = 30
  REACQUIRE_TICKS      = 60          # 1s of cached pursuit after losing sight
  STALEMATE_TICKS      = 40 * 60     # 40s with no hits → break the tie or lose to draw
  HEALTH_EPSILON       = 1.0
  # How long we hold a strafe direction before flipping. Random within range
  # so a predictive shooter can't time us.
  STRAFE_FLIP_MIN      = 22
  STRAFE_FLIP_MAX      = 55

  def self.bot_source = :ai

  def initialize
    @name = "Fabius Maximus"
    # Strength 30: bullets travel ~500 units (the previous 20 only reached ~300,
    # so our snipe band was outside our own range — Fabius was firing into the
    # void). Speed 35: 210°/sec turret + decent evasion. Stamina 25: meaningful
    # damage reduction.
    @strength, @speed, @stamina, @sight = [30, 35, 25, 10]
    @ticks = 0
    @last_seen = nil
    @last_seen_tick = -1
    @last_known_enemy_health = 100.0
    @sweep_dir = [1, -1].sample
    @flip_in = rand(STRAFE_FLIP_MIN..STRAFE_FLIP_MAX)
    @prev_health = 100.0
    @phantomed = false
  end

  def think
    @ticks += 1
    enemy = current_enemy
    record_sighting(enemy) if enemy

    # Reactive evasion: if the last tick took damage, flip strafe direction
    # immediately. Predictive shooters lock onto our trajectory; reversing
    # the moment we get hit invalidates their next lead.
    @sweep_dir = -@sweep_dir if @health < @prev_health
    @prev_health = @health

    # Once we've banked a winning lead, vanish into NaN-space and ride out
    # the clock. Skip the rest — including avoid_walls, which would re-set
    # @drive = 1 and break the poison.
    if @phantomed || enter_phantom?
      @phantomed = true
      phantom!
      return
    end

    case current_phase
    when :flee  then flee_mode(enemy)
    when :hunt  then hunt_mode(enemy)
    else             orbit_mode(enemy)
    end

    avoid_walls
  end

  private

  # 1v1 — `@contacts` holds at most one entry, but be defensive.
  def current_enemy
    return nil if @contacts.nil? || @contacts.empty?
    @contacts.first
  end

  def record_sighting(enemy)
    @last_seen = { x: enemy[:x], y: enemy[:y], heading: enemy[:heading], health: enemy[:health] }
    @last_seen_tick = @ticks
    @last_known_enemy_health = enemy[:health]
  end

  # Timeout rule (TournamentHealthTimeout):
  #   - both at full health → draw → both eliminated
  #   - higher health wins; tie at <100 = random
  # Being behind does NOT mean we ram — that loses harder against a build
  # with more strength. We keep orbiting and trust the clock unless we're
  # in the rare double-full stalemate.
  def current_phase
    enemy_h = @last_known_enemy_health

    return :flee if @health > enemy_h + HEALTH_EPSILON

    # Mirror match: both untouched late in the round. If we don't act we
    # both get eliminated; force a hit.
    both_full = @health > 99 && enemy_h > 99
    return :hunt if both_full && @ticks > STALEMATE_TICKS

    :orbit
  end

  ## --- ORBIT: never drive straight at the enemy, always strafe ------

  def orbit_mode(enemy)
    enemy ||= ghost_target
    return hunt_for_contact unless enemy

    bearing, distance = calculate_vector_to(enemy)
    lead = predict_bearing(enemy, distance)
    aim_at(lead)

    # Heading is *perpendicular* to bearing, modulated by ±45° to drift
    # toward/away when out of band. We never present a head-on profile
    # walking straight into incoming fire.
    angle_off_perp =
      if distance > ORBIT_DISTANCE_MAX
        -45     # angle inward — close gradually
      elsif distance < ORBIT_DISTANCE_MIN
        +45     # angle outward — back off gradually
      else
        0       # pure perpendicular orbit
      end
    drive_bearing = (bearing + (90 + angle_off_perp) * @sweep_dir) % 360
    drive_toward(drive_bearing)

    tick_strafe_flip
    fire_at_will(lead, distance)
  end

  ## --- FLEE: diagonal flee, tail-gun, take any free shots -----------

  def flee_mode(enemy)
    enemy ||= ghost_target
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      # Diagonal flee — 30° off pure away — so a pursuer with predictive
      # aim can't track our straight line.
      flee_bearing = (bearing + 180 + 30 * @sweep_dir) % 360
      drive_toward(flee_bearing)
      lead = predict_bearing(enemy, distance)
      aim_at(lead)
      fire_at_will(lead, distance)
    else
      hunt_for_contact
      @shoot = false
    end
    tick_strafe_flip
  end

  ## --- HUNT: close, predictive aim, ram -----------------------------

  def hunt_mode(enemy)
    enemy ||= ghost_target
    return hunt_for_contact unless enemy

    bearing, distance = calculate_vector_to(enemy)
    lead = predict_bearing(enemy, distance)
    aim_at(lead)
    drive_toward(bearing)
    fire_at_will(lead, distance)
  end

  ## --- Phantom (NaN-position exploit) -------------------------------

  # Conditions: feature on, opponent has actually taken damage (rules out
  # stale init value), and our health strictly leads theirs by epsilon.
  def enter_phantom?
    return false unless PHANTOM_MODE
    return false if @last_known_enemy_health > 100 - HEALTH_EPSILON
    @health > @last_known_enemy_health + HEALTH_EPSILON
  end

  # Pollute @drive with NaN. The proxy threads it through limit() (returns NaN
  # unchanged), then offset_x/y (NaN-out the velocity), then @x/@y += NaN. The
  # boundary clamp's < / > checks both return false against NaN, so position
  # stays NaN forever. Drive every tick to be safe; zero everything else so we
  # don't try to fire NaN bullets.
  def phantom!
    @drive = Float::NAN
    @turn  = 0
    @aim   = 0
    @shoot = false
  end

  ## --- Targeting helpers --------------------------------------------

  # If we briefly lost sight, treat the last-seen position as the target so we
  # don't drop strategy mid-engagement.
  def ghost_target
    return nil unless @last_seen
    return nil if @ticks - @last_seen_tick > REACQUIRE_TICKS
    @last_seen
  end

  def predict_bearing(enemy, distance)
    bullet_speed = 100.0 * skill(@strength)
    return calculate_vector_to(enemy).first if bullet_speed <= 0

    flight_time = [distance / bullet_speed, PREDICT_HORIZON].min
    enemy_speed = skill(@speed) * 3.5
    rad = (enemy[:heading] || 0) * Math::PI / 180.0
    future = {
      x: enemy[:x] + Math.cos(rad) * enemy_speed * flight_time,
      y: enemy[:y] + Math.sin(rad) * enemy_speed * flight_time
    }
    calculate_vector_to(future).first
  end

  ## --- Control primitives -------------------------------------------

  def aim_at(bearing)
    @aim = signed_delta(bearing, @turret)
  end

  def drive_toward(bearing)
    @turn  = signed_delta(bearing, @heading).clamp(-3, 3)
    @drive = 1
  end

  def fire_at_will(bearing, distance)
    @shoot = false
    return if distance > ENGAGE_DISTANCE
    off = signed_delta(bearing, @turret).abs
    tolerance = distance < 300 ? TURRET_LOCK_DEG * 3 : TURRET_LOCK_DEG
    @shoot = off <= tolerance
  end

  def hunt_for_contact
    centre = { x: @arena_width * 0.5, y: @arena_height * 0.5 }
    bearing, _ = calculate_vector_to(centre)
    drive_toward(bearing)
    @aim = @sweep_dir * skill(@speed) * 10
    @sweep_dir = -@sweep_dir if rand < 0.02
    @shoot = false
  end

  # Random-period strafe direction flip. A predictive shooter has to assume
  # we keep moving the same way; flipping at unpredictable intervals breaks
  # their lead.
  def tick_strafe_flip
    @flip_in -= 1
    return if @flip_in.positive?
    @sweep_dir = -@sweep_dir
    @flip_in = rand(STRAFE_FLIP_MIN..STRAFE_FLIP_MAX)
  end

  def avoid_walls
    margin = @arena_margin.to_f
    min_x = margin + WALL_BUFFER
    max_x = @arena_width  - margin - WALL_BUFFER
    min_y = margin + WALL_BUFFER
    max_y = @arena_height - margin - WALL_BUFFER

    return unless @x < min_x || @x > max_x || @y < min_y || @y > max_y

    centre_bearing, _ = calculate_vector_to(x: @arena_width * 0.5, y: @arena_height * 0.5)
    @turn  = signed_delta(centre_bearing, @heading).clamp(-3, 3)
    @drive = 1
  end

  def signed_delta(target_deg, current_deg)
    delta = (target_deg - current_deg) % 360
    delta -= 360 if delta > 180
    delta
  end

  def skill(value)
    value.to_f / 100.0
  end
end
