class TheCoward < BattleBots::Bots::Bot
  BUFFER = 50

  def self.bot_source
    :ai
  end

  def initialize
    @name = "The Coward"
    @speed, @strength, @stamina, @sight = [35, 35, 25, 5]
  end

  def think
    closest_enemy = select_target
    return stand_by unless closest_enemy

    enemy_bearing, distance = calculate_vector_to(closest_enemy)
    aim_turret(enemy_bearing, distance)
    run_away(enemy_bearing)
  end

  def run_away(enemy_bearing)
    flee_bearing = (enemy_bearing + 180) % 360
    target_bearing = near_wall? ? compass_bearing_to_centre : flee_bearing
    @turn = shortest_turn_toward(target_bearing)
    @drive = 1
  end

  def near_wall?
    @x < wall_buffer || @x > @arena_width - wall_buffer ||
      @y < wall_buffer || @y > @arena_height - wall_buffer
  end

  def compass_bearing_to_centre
    dx = @arena_width / 2.0 - @x
    dy = @arena_height / 2.0 - @y
    compass_bearing(dx, dy)
  end

  def compass_bearing(dx, dy)
    (Math.atan2(dy, dx) * 180 / Math::PI + 90) % 360
  end

  def shortest_turn_toward(bearing)
    (@heading - bearing) % 360 > 180 ? 1 : -1
  end

  def wall_buffer
    @arena_margin + BUFFER
  end
end
