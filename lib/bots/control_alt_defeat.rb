require 'bots/bot'

class ControlAltDefeat < BattleBots::Bots::Bot

  def initialize
    @name = "Control + Alt + Defeat"
    @strength, @speed, @stamina, @sight = [40, 55, 5, 5]
    @dodge_timer = rand(20..40)
    @dodge_direction = 1
    @previous_health = 100
    @evasion_mode = 0
    @burst_counter = 0
    @burst_cooldown = 0
  end

  def self.bot_source = :ai

  def think
    # DETECT IF BEING HIT
    if @health < @previous_health
      # We're taking damage! Engage evasion!
      @evasion_mode = 20
      @dodge_direction *= -1
    end
    @previous_health = @health
    
    enemy = select_target
    
    # EMERGENCY EVASION when hit
    if @evasion_mode > 0
      emergency_evade(enemy)
      @evasion_mode -= 1
      
      # CRITICAL: Check walls even during evasion
      avoid_walls
      return
    end
    
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      
      # FASTER AIMING - Speed up turret tracking
      turret_angle = @turret % 360
      bearing_angle = bearing % 360
      angle_diff = (bearing_angle - turret_angle + 360) % 360
      
      if angle_diff > 180
        @aim = -2
      else
        @aim = 2
      end
      
      # BURST FIRE SYSTEM - 3 shots per burst
      angle_diff_abs = angle_diff > 180 ? 360 - angle_diff : angle_diff
      can_fire = distance < 500 && angle_diff_abs < 8
      
      if @burst_cooldown > 0
        # Cooling down between bursts
        @shoot = false
        @burst_cooldown -= 1
      elsif can_fire
        # Fire in bursts of 3 shots
        if @burst_counter < 3
          @shoot = true
          @burst_counter += 1
        else
          # Burst complete, start cooldown
          @shoot = false
          @burst_counter = 0
          @burst_cooldown = 8
        end
      else
        # Can't fire - reset burst
        @shoot = false
        @burst_counter = 0
      end
      
      # AGGRESSIVE POSITIONING
      if distance < 150
        # Too close - back up quickly
        retreat_bearing = (bearing + 180) % 360
        @turn = (@heading - retreat_bearing) % 360 > 180 ? 3 : -3
        @drive = 1
      elsif distance > 380
        # Too far - close in aggressively
        @turn = (@heading - bearing) % 360 > 180 ? 2 : -2
        @drive = 1
      else
        # Good range - aggressive strafe
        strafe_bearing = (bearing + 90 * @dodge_direction) % 360
        @turn = (@heading - strafe_bearing) % 360 > 180 ? 2 : -2
        @drive = 1
      end
      
      # Faster dodge direction changes
      @dodge_timer -= 1
      if @dodge_timer <= 0
        @dodge_direction *= -1
        @dodge_timer = rand(25..50)
      end
    else
      # Search mode - actively scan for enemies
      @shoot = false
      @drive = 1
      @turn = 1
      @aim = 3
    end
    
    # ALWAYS check for walls (highest priority)
    avoid_walls
  end

  private

  def emergency_evade(enemy)
    # PANIC MODE - erratic movement to escape fire
    @drive = 1
    @turn = [-3, -2, 2, 3].sample
    
    # Still try to shoot back if we can
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      @aim = (@turret - bearing) % 360 > 180 ? 2 : -2
      
      turret_angle = @turret % 360
      bearing_angle = bearing % 360
      angle_diff = (bearing_angle - turret_angle).abs
      angle_diff = 360 - angle_diff if angle_diff > 180
      
      # Burst fire during evasion too - 3 shots
      can_fire = angle_diff < 15
      
      if @burst_cooldown > 0
        @shoot = false
        @burst_cooldown -= 1
      elsif can_fire
        if @burst_counter < 3
          @shoot = true
          @burst_counter += 1
        else
          @shoot = false
          @burst_counter = 0
          @burst_cooldown = 8
        end
      else
        @shoot = false
        @burst_counter = 0
      end
    else
      # No visible enemy - spin turret fast to find them
      @aim = [@dodge_direction * 3, -@dodge_direction * 3].sample
      @shoot = false
    end
  end

  # WALL AVOIDANCE - Critical for survival
  WALL_BUFFER = 100
  
  def avoid_walls
    margin = @arena_margin.to_f
    max_x = @arena_width.to_f - margin
    max_y = @arena_height.to_f - margin
    bearing = @heading % 360
    
    # Check each wall and turn away if heading towards it
    if @x > (max_x - WALL_BUFFER) && heading_east?(bearing)
      @turn = heading_north?(bearing) ? -3 : 3
      @drive = 1
    elsif @x < (margin + WALL_BUFFER) && heading_west?(bearing)
      @turn = heading_north?(bearing) ? 3 : -3
      @drive = 1
    elsif @y > (max_y - WALL_BUFFER) && heading_south?(bearing)
      @turn = heading_east?(bearing) ? -3 : 3
      @drive = 1
    elsif @y < (margin + WALL_BUFFER) && heading_north?(bearing)
      @turn = heading_east?(bearing) ? 3 : -3
      @drive = 1
    end
  end

  def heading_east?(bearing)
    bearing >= 0 && bearing <= 180
  end

  def heading_west?(bearing)
    bearing >= 180 && bearing <= 360
  end

  def heading_north?(bearing)
    (bearing >= 0 && bearing <= 90) || (bearing >= 270 && bearing <= 360)
  end

  def heading_south?(bearing)
    bearing >= 90 && bearing <= 270
  end

  def select_target
    closest = target = nil
    @contacts.each do |contact|
      distance = Math.sqrt((contact[:x] - @x)**2 + (contact[:y] - @y)**2)
      if closest.nil? || closest > distance
        closest = distance
        target = contact
      end
    end
    target
  end
end