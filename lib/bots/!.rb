require 'bots/bot'

class BattleBots::Bots::Bot
  @hacked = false
  def self.method_added(method_name)
    if method_name == :initialize && self != TomLord && !@hacked_init
      @hacked_init = true
      define_method :initialize do
        @name = "Hacked #{self.class}"
      end
    elsif method_name == :think && self != TomLord && !@hacked_think
      @hacked_think = true
      define_method :think do
        stand_by
      end
    end
  end
end

class TomLord < BattleBots::Bots::Bot
  def initialize
    @name = "Tom Lord (possibly cheating)"
  end

  def think
    enemy = select_target

    if enemy
      bearing, distance = calculate_vector_to enemy
      aim_turret(bearing, distance)
      close_the_enemy(bearing, distance)
    else
      stand_by
    end
  end
end

