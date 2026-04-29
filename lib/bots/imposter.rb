require 'bots/bot'

class Tank < BattleBots::Bots::Bot
  def self.bot_source
    :human
  end

  def initialize
    @name = 'Tank'
    @strength = 40
    @speed = 10
    @stamina = 40
    @sight = 10
  end

  def think
    enemy = select_target
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      aim_turret(bearing, distance)
      close_the_enemy(bearing, distance)
    else
      stand_by
    end
  end

  def select_target
    target = nil
    @contacts.each do |contact|
      target ||= contact
      target = contact if target[:health] > contact[:health]
    end
    target
  end
end
