require 'bots/bot'

class Craig9000 < BattleBots::Bots::Bot
  BORDER = 90
  CLOSE_RANGE = 110
  FIRE_RANGE = 900
  ROTATE_RIGHT = 1
  ROTATE_LEFT = -1

  def initialize
    @name = 'Craig 9000'
    @strength, @speed, @stamina, @sight = [50, 10, 110, -70]
    @drive, @turn, @aim, @shoot = [1, 0, ROTATE_RIGHT, false]
    @scan_direction = ROTATE_RIGHT
  end

  def think
    @shoot = false
    enemy = select_target

    if enemy
      bearing, distance = calculate_vector_to(enemy)
      aim_at(bearing)
      pressure_enemy(bearing, distance)
      @shoot = distance < FIRE_RANGE
    else
      patrol
    end

    stay_clear_of_walls
    remember_scan_direction
  end

  private

  def select_target
    @contacts.min_by do |contact|
      bearing, distance = calculate_vector_to(contact)
      aim_error = angular_difference(@turret, bearing).abs
      (contact[:health] * 8) + distance + (aim_error * 4)
    end
  end

  def aim_at(bearing)
    @aim = angular_difference(@turret, bearing).positive? ? -1 : 1
  end

  def pressure_enemy(bearing, distance)
    @turn = angular_difference(@heading, bearing).positive? ? -1 : 1
    @drive = distance < CLOSE_RANGE ? 0 : 1
  end

  def patrol
    @aim = @scan_direction
    @drive = 1
    @turn = 1
  end

  def stay_clear_of_walls
    bearing = @heading % 360
    return unless near_wall?

    escape_bearing = calculate_vector_to(center_point).first
    @turn = angular_difference(bearing, escape_bearing).positive? ? -2 : 2
    @drive = 1
  end

  def near_wall?
    @x < play_min_x + BORDER ||
      @x > play_max_x - BORDER ||
      @y < play_min_y + BORDER ||
      @y > play_max_y - BORDER
  end

  def center_point
    { x: @arena_width * 0.5, y: @arena_height * 0.5 }
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

  def remember_scan_direction
    @scan_direction = ROTATE_RIGHT if @aim.positive?
    @scan_direction = ROTATE_LEFT if @aim.negative?
  end

  def angular_difference(from, to)
    ((from - to + 540) % 360) - 180
  end
end
