require 'bots/bot'

class Tank < BattleBots::Bots::Bot
  def self.bot_source
    :human
  end

  def initialize
    @name = 'mattf'
    # @strength = 20
    # @speed = 20
    # @stamina = 20
    # @sight = 20

    @tick = nil
    @action = nil
    stand_by
  end

  def think
    if @tick.nil? || @tick == 20
      @tick = 0
      @action = rand(4)
    end

    case @action
    when 0
      enemy = select_target
      if enemy
        bearing, distance = calculate_vector_to(enemy)
        aim_turret(bearing, distance)
      end
    when 1
      enemy = select_target
      if enemy
        bearing, distance = calculate_vector_to(enemy)
        close_the_enemy(bearing, distance)
      end
    when 2
      enemy = select_target
      if enemy
        bearing, distance = calculate_vector_to(enemy)
        run_away(bearing, distance)
      end
    when 3
      stand_by
    end

    @tick += 1
  end
end
