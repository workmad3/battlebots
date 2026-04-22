require 'bots/bot'

# DeathRoomba by Elliott
class DeathRoomba < BattleBots::Bots::Bot
  def initialize
    @name = "DeathRoomba"
    @speed, @strength, @stamina, @sight = [35, 35, 25, 5]
    @drive, @turn, @aim, @shoot = [1, 0, 0, false]
    @rand_counter = rand(1..150)
  end

  def think
    scan_for_enemy
    enemy = select_target
    if enemy
      #estimated_position = estimate_position(enemy)
      bearing, distance = calculate_vector_to(enemy)
      aim_turret(bearing, distance) if distance < 400
      @shoot = true if target_locked?(bearing, distance)
    else
      @shoot = false
    end
    crazy_dance
    stay_clear_of_walls
    remember_last_turret_direction
  end

  private

  ## ERRATIC MOVEMENT AND CONFUSION SYSTEM
  def crazy_dance
    @drive = 1
    @rand_counter ||= 100
    @rand_counter -= 1
    if @rand_counter <= 0
      @turn = [-1,0,1].sample
      @rand_counter = rand(1..100)
    end
  end

  ## ULTIMATE ENEMY ANNIHILATION SYSTEM
  def select_target
    closest = target = nil
    @contacts.each do |contact|
      attack_distance = Math.sqrt((contact[:x] - @x).abs**2 + (contact[:y]-@y)**2)
      if closest.nil? || closest > attack_distance
        closest = attack_distance
        target = contact
      end
    end
    target
  end
  def estimate_position(enemy)
    velocity = 25 # hardcoded value for now
    time = 1     # hardcoded value for now
    radians = enemy[:heading] * Math::PI / 180
    { 
      x: enemy[:x] + velocity * time * Math.cos(radians),
      y: enemy[:y] + velocity * time * Math.sin(radians),
      heading: enemy[:heading]
    }
  end
  def aim_turret(bearing, distance)
    turret = @turret % 360
    bearing = bearing % 360
    @aim = bearing - turret
  end
  def target_locked?(bearing, distance)
    turret = @turret % 360
    bearing = bearing % 360
    (bearing - turret).abs < 1 && distance < 350
  end

  # ENHANCED ENEMY DETECTION ALGORITHM
  ROTATE_LEFT = -1
  ROTATE_RIGHT = 1
  def remember_last_turret_direction
    @last_turret_direction ||= ROTATE_RIGHT
    @last_turret_direction = ROTATE_RIGHT if @aim > 0
    @last_turret_direction = ROTATE_LEFT if @aim < 0
  end
  def scan_for_enemy
    @last_turret_direction ||= ROTATE_RIGHT
    @aim = @last_turret_direction * 15
  end

  ## DEADZONE AVOIDANCE SYSTEM
  BORDER = 70

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
    # far east
    if @x > (right - BORDER) && east?(bearing) && north?(bearing)
      @turn = turn_left
    elsif @x > (right - BORDER) && east?(bearing) && south?(bearing)
      @turn = turn_right
    # far west
    elsif @x < (left + BORDER) && west?(bearing) && north?(bearing)
      @turn = turn_right
    elsif @x < (left + BORDER) && west?(bearing) && south?(bearing)
      @turn = turn_left
    # far south
    elsif @y > (bottom - BORDER) && south?(bearing) && east?(bearing)
      @turn = turn_left
    elsif @y > (bottom - BORDER) && south?(bearing) && west?(bearing)
      @turn = turn_right
    # far north
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
