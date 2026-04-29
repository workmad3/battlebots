require 'bots/bot'

class Spin_to_win < BattleBots::Bots::Bot
  def self.bot_source = :human

  def initialize
    @name = "SPIN. TO. WIN (FB)"
    @speed, @strength, @stamina, @sight = [35, 30, 20, 15]
    @drive = 5
  end

  def think
    enemy = select_target
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      keep_your_distance(bearing, distance)
      aim_turret(bearing, distance)
    else
      search_and_destroy
    end
  end

  private

  def keep_your_distance(new_bearing, distance)
    if distance < 300
      @turn = (@heading - new_bearing) % 180 > 0 ? -3 : 3
    else
      close_the_enemy(new_bearing, distance)
    end
  end

  def search_and_destroy
    @aim = 1
    if rand(1..10) > 7
      if @heading + 20 > 360
        @turn = 5
      else
        @turn = -5
      end
    else
      @turn = 0
    end
  end
end
