require 'bots/bot'

# Tuned for tournament 1v1: two fighters, ~60s clock, winner by KO or higher HP on timeout.
# Corner anchor + disciplined aim; high sight so the lone opponent stays in cone.
# When behind on trades or pinned (close + losing), bail to open field / run — Chicken-style escape.
# When ahead: hull steers toward the opponent's nearest corner (herd into pocket), not only ours.
class AmansTank < BattleBots::Bots::Bot
  def self.bot_source = :ai

  BORDER = 70
  CORNER_RADIUS = 75

  # Hull navigates toward enemy pocket — herd them toward edges when we're winning trades.
  PIN_ADVANTAGE_GAP = 10

  # HP gap vs opponent before we stop anchoring and fight toward centre / escape knife fights.
  RECOVER_IF_HEALTH_BEHIND_BY = 14
  # Knife-range: trigger escape sooner even when HP gap is still modest.
  CLOSE_PRESSURE_GAP = 9
  ESCAPE_CLOSE_RANGE = 138
  DESPERATE_HEALTH = 34

  THINKER_PURSUITS_WITHIN = 250
  THINKER_FIRE_WITHIN = 200

  # Burst cadence by distance: close = max rate; mid/long throttle ammo (Proxy spends ammo per shot).
  CLOSE_FULL_RATE_RANGE = 260
  MID_RANGE_DISTANCE = 400
  BURST_INTERVAL_MID = 11
  BURST_INTERVAL_LONG = 26

  LOCK_ANGLE_DEG = 5
  HULL_TURRET_SAFE_DEG = 6

  ROTATE_LEFT = -1
  ROTATE_RIGHT = 1

  def initialize
    @name = 'AmansTank'
    # Sum 100 — prioritize sight (1v1: must acquire), then damage + trades + aim-rate via speed.
    @speed, @strength, @stamina, @sight = [26, 34, 18, 22]
    @drive = 1
    @turn = 0
    @aim = 0
    @shoot = false
    @tick = 0
    @last_turret_direction = ROTATE_RIGHT
  end

  def think
    @tick += 1
    @tick = 0 if @tick >= 10_000

    enemy = select_target

    if enemy.nil?
      drive_to_corner_and_sweep
      @shoot = false
    elsif recover_position?(enemy)
      recover_open_field(enemy)
    elsif in_corner?
      duel_from_corner(enemy)
    else
      drive_to_corner_while_tracking(enemy)
    end

    stay_clear_of_walls
    remember_last_turret_direction
  end

  private

  def shortest_turn_deg(from_deg, to_deg)
    f = from_deg % 360.0
    t = to_deg % 360.0
    ((t - f + 540) % 360) - 180
  end

  def hull_points_into_shot?
    shortest_turn_deg(@heading, @turret).abs < HULL_TURRET_SAFE_DEG
  end

  # TheBully-style: finish low targets — in 1v1 this is just the opponent when visible.
  def select_target
    target = nil
    @contacts.each do |contact|
      if target.nil? || target[:health] > contact[:health]
        target = contact
      end
    end
    target
  end

  def nearest_corner
    mx = @arena_margin.to_f
    aw = @arena_width.to_f
    ah = @arena_height.to_f
    max_x = aw - mx
    max_y = ah - mx
    mid_x = aw * 0.5
    mid_y = ah * 0.5
    { x: (@x < mid_x ? mx : max_x), y: (@y < mid_y ? mx : max_y) }
  end

  # Same geometry as nearest_corner but from enemy coords — their closest playable corner (pressure anchor).
  def enemy_nearest_corner_coords(enemy)
    mx = @arena_margin.to_f
    aw = @arena_width.to_f
    ah = @arena_height.to_f
    max_x = aw - mx
    max_y = ah - mx
    mid_x = aw * 0.5
    mid_y = ah * 0.5
    ex = enemy[:x].to_f
    ey = enemy[:y].to_f
    { x: (ex < mid_x ? mx : max_x), y: (ey < mid_y ? mx : max_y) }
  end

  def advantage?(enemy)
    enemy && @health.to_f >= enemy[:health].to_f + PIN_ADVANTAGE_GAP
  end

  def pressure_opponent?(enemy)
    advantage?(enemy) && !recover_position?(enemy)
  end

  def enemy_in_pocket?(enemy)
    ec = enemy_nearest_corner_coords(enemy)
    dx = (enemy[:x].to_f - ec[:x]).abs
    dy = (enemy[:y].to_f - ec[:y]).abs
    dx < CORNER_RADIUS + 40 && dy < CORNER_RADIUS + 40
  end

  def hull_drive_goal(enemy)
    pressure_opponent?(enemy) ? enemy_nearest_corner_coords(enemy) : nearest_corner
  end

  def in_corner?
    c = nearest_corner
    (@x - c[:x]).abs < CORNER_RADIUS && (@y - c[:y]).abs < CORNER_RADIUS
  end

  def recover_position?(enemy)
    return false unless enemy

    gap = enemy[:health].to_f - @health.to_f
    _, dist = calculate_vector_to(enemy)

    gap > RECOVER_IF_HEALTH_BEHIND_BY ||
      @health.to_f <= DESPERATE_HEALTH ||
      (gap > CLOSE_PRESSURE_GAP && dist < ESCAPE_CLOSE_RANGE)
  end

  # Aim at threat; hull opens space (Speedy centre rally + Chicken run_away when pinned).
  def recover_open_field(enemy)
    bearing, distance = calculate_vector_to(enemy)
    aim_turret_duel(bearing)

    desperate_flee = @health.to_f <= DESPERATE_HEALTH && distance < ESCAPE_CLOSE_RANGE + 40
    pinned = distance < ESCAPE_CLOSE_RANGE && (enemy[:health].to_f - @health.to_f) > RECOVER_IF_HEALTH_BEHIND_BY

    if desperate_flee || pinned
      run_away(bearing, distance)
    else
      mx = @arena_width * 0.5
      my = @arena_height * 0.5
      bc, dc = calculate_vector_to({ x: mx, y: my })
      close_the_enemy(bc, dc)
      @turn *= 2
    end

    @shoot = shoot_gate?(bearing, distance)
  end

  def drive_to_corner_and_sweep
    cb, = calculate_vector_to(nearest_corner)
    @turn = (@heading - cb) % 360 > 180 ? 3 : -3
    @drive = 1
    scan_for_enemy
  end

  def drive_to_corner_while_tracking(enemy)
    goal = hull_drive_goal(enemy)
    cb, = calculate_vector_to(goal)
    @turn = (@heading - cb) % 360 > 180 ? 3 : -3
    @drive = 1
    bearing, distance = calculate_vector_to(enemy)
    aim_turret_duel(bearing)
    @shoot = shoot_gate?(bearing, distance)
  end

  def duel_from_corner(enemy)
    bearing, distance = calculate_vector_to(enemy)
    aim_turret_duel(bearing)
    close_the_enemy(bearing, distance)
    press = advantage?(enemy) && enemy_in_pocket?(enemy) ? 4 : 3
    @turn *= press
    @shoot = shoot_gate?(bearing, distance)
  end

  def aim_turret_duel(bearing)
    @aim = shortest_turn_deg(@turret, bearing)
  end

  def shoot_gate?(bearing, distance)
    locked = shortest_turn_deg(@turret, bearing).abs < LOCK_ANGLE_DEG && distance < 420
    want = locked && (distance > THINKER_PURSUITS_WITHIN || distance < THINKER_FIRE_WITHIN)
    want && burst_allows_shot?(distance) && !hull_points_into_shot?
  end

  def burst_allows_shot?(distance)
    return true if distance <= CLOSE_FULL_RATE_RANGE

    interval = distance <= MID_RANGE_DISTANCE ? BURST_INTERVAL_MID : BURST_INTERVAL_LONG
    (@tick % interval).zero?
  end

  def remember_last_turret_direction
    @last_turret_direction ||= ROTATE_RIGHT
    @last_turret_direction = ROTATE_RIGHT if @aim > 0
    @last_turret_direction = ROTATE_LEFT if @aim < 0
  end

  def scan_for_enemy
    @last_turret_direction ||= ROTATE_RIGHT
    @aim = @last_turret_direction * 15
  end

  def play_min_x
    @arena_margin.to_f
  end

  def play_max_x
    @arena_width.to_f - @arena_margin.to_f
  end

  def play_min_y
    @arena_margin.to_f
  end

  def play_max_y
    @arena_height.to_f - @arena_margin.to_f
  end

  def stay_clear_of_walls
    turn_right = 3
    turn_left = -3
    bearing = @heading % 360
    right = play_max_x
    left = play_min_x
    bottom = play_max_y
    top = play_min_y

    if @x > (right - BORDER) && east?(bearing) && north?(bearing)
      @turn = turn_left
    elsif @x > (right - BORDER) && east?(bearing) && south?(bearing)
      @turn = turn_right
    elsif @x < (left + BORDER) && west?(bearing) && north?(bearing)
      @turn = turn_right
    elsif @x < (left + BORDER) && west?(bearing) && south?(bearing)
      @turn = turn_left
    elsif @y > (bottom - BORDER) && south?(bearing) && east?(bearing)
      @turn = turn_left
    elsif @y > (bottom - BORDER) && south?(bearing) && west?(bearing)
      @turn = turn_right
    elsif @y < (top + BORDER) && north?(bearing) && east?(bearing)
      @turn = turn_right
    elsif @y < (top + BORDER) && north?(bearing) && west?(bearing)
      @turn = turn_left
    end
  end

  def east?(bearing)
    bearing >= 0 && bearing <= 180
  end

  def south?(bearing)
    bearing >= 90 && bearing <= 270
  end

  def west?(bearing)
    bearing >= 180 && bearing <= 360
  end

  def north?(bearing)
    (bearing >= 0 && bearing <= 90) || (bearing >= 270 && bearing <= 360)
  end
end
