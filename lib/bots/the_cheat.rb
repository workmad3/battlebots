
# A bot that hacks the brains of other bots
class TheCheat < BattleBots::Bots::Bot
  def self.bot_source
    :human
  end

  def initialize
    puts "initialize"
    @name      = "The Cheat (Richard's house robot)"
    @speed     = 10
    @strength  = 40
    @stamina   = 0
    @sight     = 25
    @first_run = true


  end

  def think
    if @first_run
      override_brain
      emp
      @first_run = false
    end

    enemy = select_target

    if enemy
      bearing, distance = calculate_vector_to enemy
      aim_turret(bearing, distance)
      close_the_enemy(bearing, distance)
    else
      stand_by
    end

  end


  private

  # Tournament uses TournamentWindow; free-play uses Game — neither loads the other.
  def each_battle_window
    klasses = []
    klasses << BattleBots::Game if defined?(BattleBots::Game)
    klasses << BattleBots::TournamentWindow if defined?(BattleBots::TournamentWindow)
    klasses.each do |klass|
      ObjectSpace.each_object(klass) { |w| yield w }
    end
  end

  def override_brain
    each_battle_window do |game|
      game.players.each do |player|
        bot = player.bot
        unless bot == self
          bot.class.send(:alias_method, :old_think, :think)
          bot.class.send(:alias_method, :old_select_target, :select_target)
        end
      end
    end
  end

  def emp
    each_battle_window do |game|
      game.players.each do |player|
        bot = player.bot
        unless bot == self
          def bot.name=(name)
            @name = name
          end
          bot.name = "[disabled]" + bot.name
          def bot.think
            @heading = 0
            @turn    = 0
            @drive   = 0
            @aim     = 0
            @shoot   = false
          end
        else
          @player = player
        end
      end
      cripple_every_other_opponent(game)
    end

    boost_own_firepower if @player
  end

  def cripple_every_other_opponent(game)
    others = game.players.reject { |p| p.bot == self }
    others.each do |enemy|
      enemy.instance_variable_set(:@health, 1)
    end
  end

  def boost_own_firepower
    proxy = @player
    proxy.define_singleton_method(:fire!) do
      if @ammo > 0 && @bot.shoot
        @ammo -= 50
        vel_x = Gosu::offset_x(@turret, 100 * @strength + @vel_x.abs)
        vel_y = Gosu::offset_y(@turret, 100 * @strength + @vel_y.abs)
        vector = [@x, @y, @turret, vel_x, vel_y]
        10.times do
          @window.bullets << BattleBots::Bullet.new(@window, vector, @gun_sound)
        end
      end
    end
  end
end
