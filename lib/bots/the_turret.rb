require 'bots/bot'

# DeathRoomba by Elliott
class TheTurret < BattleBots::Bots::Bot
  def initialize
    @name = 'DW: The Turret'
    @speed = 0
    @strength = 25
    @stamina = 25
    @sight = 50
  end

  def self.bot_source
    :human
  end

  def think
    enemy = select_target
    return unless enemy

    bearing, distance = calculate_vector_to(enemy)
    aim_turret(bearing, distance)
    @shoot = distance < 400
  end
end
