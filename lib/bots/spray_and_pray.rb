#require 'byebug'

class SprayAndPray < BattleBots::Bots::Bot

  def initialize
    @name = "Spray and Pray"

    @speed = 40
    @strength = 40
    @stamina = 0
    @sight = 20
  end

  def think
    if in_corner?
      shoot_nearest_enemy(true)
    else
      go_towards_corner
    end

    @turn ||= 0
    @drive ||= 0
    @aim ||= 0
  end

  private
  def in_corner?
    (@x - nearest_corner[:x]).abs < 75 && (@y - nearest_corner[:y]).abs < 75
  end

  # returns if the bot should move
  def shoot_nearest_enemy(can_move)
    enemy = select_target

    if enemy
      bearing, distance = calculate_vector_to(enemy)
      if distance < 500
        aim_turret(bearing, distance)
        if can_move
          close_the_enemy(bearing, distance)
          @turn *= 4
        end
      else
        if can_move
          close_the_enemy(bearing, distance)
          @turn *= 4
        end
      end
    else
      @aim = 1
    end
  end

  def go_towards_corner
    @aim = 0

    bearing, distance = calculate_vector_to(nearest_corner)
    @turn = (@heading - bearing) % 360 > 180 ? 3 : -3
    @drive = 1

    shoot_nearest_enemy(false)
  end

  # Nearest playable corner (same inset as Proxy clamp), so behaviour scales with arena size.
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
end
