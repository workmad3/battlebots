require 'bullets'
require 'explosion'
require 'bots/bot'

module BattleBots
  class Proxy

    MAGAZINE_CAPACITY = 5000

    attr_reader :bot, :x, :y, :health, :heading, :turret

    def initialize(window, name)
      set_environmentals window

      @bot = name.new
      @name = @bot.name
      validate_skill_profile! @bot

      @health = 100
      @ammo = 0
      @heading = rand * 360
      @turret = rand * 360
      track = @bot.sound || 'media/ow.wav'
      @sound = Gosu::Sample.new(track)
    end

    def play
      reload
      observe_battlespace
      query_bot
      move_bot
      aim_turret
      fire!
      play_sounds
    end

    def hit?(bullets)
      bullets.reject! do |bullet|
        if Gosu::distance(@x, @y, bullet.x, bullet.y) < 25
          impact = Math.sqrt( bullet.vel_x ** 2 + bullet.vel_y ** 2 ) * (1 - @stamina)
          @health -= impact / 5
          true
        end
      end
    end

    def draw
      if @health > 0
        @body_image.draw_rot(@x, @y, 1, @heading)
        @turret_image.draw_rot(@x, @y, 1, @turret)
        label = "#{@bot.name}: "
        hx = @x - 50
        hy = @y + 25
        z = 0
        name_col = BattleBots::Bots::Bot.name_color_for_source(@bot.bot_source)
        @font.draw_text(label, hx, hy, z, 1.0, 1.0, name_col)
        @font.draw_text(@health.to_i.to_s, hx + @font.text_width(label), hy, z, 1.0, 1.0, 0xff_eeeeee)
      end
    end

    def dead?
      if @health < 1
        @window.explosions << BattleBots::Explosion.new(@x, @y, @bang, @flames)
        true
      end
    end


    private

    def set_environmentals(window)
      @window = window
      @body_image = Gosu::Image.new("media/body.png")
      @turret_image = Gosu::Image.new("media/turret.png")
      @font = Gosu::Font.new(20, name: Gosu::default_font_name)
      @bang = Gosu::Sample.new("media/bang.mp3")
      @flames = BattleBots::Explosion.frames.map do |i|
        Gosu::Image.new("media/explosions/explosion2-#{i}.png")
      end
      @gun_sound = Gosu::Sample.new('media/gun.wav')
      if window.respond_to?(:play_min_x)
        w = window.play_max_x - window.play_min_x
        h = window.play_max_y - window.play_min_y
        @x = window.play_min_x + w * rand
        @y = window.play_min_y + h * rand
      else
        @x = window.width * rand
        @y = window.height * rand
      end
      @vel_x = @vel_y = 0.0
    end

    def validate_skill_profile!(bot)
      skill_total = apply_dirty_cheater_penalty bot.skill_profile
      mad_skills = bot.skill_profile.map { |skill| skill / skill_total }
      @speed, @strength, @stamina, @sight = mad_skills
    end

    def apply_dirty_cheater_penalty(mad_skills)
      total = mad_skills.map(&:to_f).reduce(:+)
      total *= 1.5 if total > 100
      total
    end

    def reload
      @ammo += 1 if @ammo < MAGAZINE_CAPACITY
    end

    def query_bot
      @bot.think
    end

    def play_sounds
      @sound.play if @bot.play_sounds
    end

    def observe_battlespace
      m = @window.respond_to?(:arena_margin) ? @window.arena_margin : 0
      battlespace = {
        x: @x, y: @y, health: @health, turret: @turret, heading: @heading, contacts: [],
        width: @window.width, height: @window.height,
        arena_margin: m
      }

      @window.players.each do |enemy|
        unless @x == enemy.x && @y == enemy.y
          if player_can_see? enemy
            battlespace[:contacts] << {
              x: enemy.x, y: enemy.y, 
              health: enemy.health, 
              heading: enemy.heading, turret: enemy.turret }
          end
        end
      end

      @bot.observe battlespace
    end

    def player_can_see?(enemy)
      arctan = (Math.atan2(enemy.y - @y, enemy.x - @x) / Math::PI * 180)
      bearing = arctan > 0 ? arctan + 90 : (arctan + 450) % 360
      lower_limit = (@turret - 180 * @sight) % 360
      upper_limit = (@turret + 180 * @sight) % 360
      true if (bearing - lower_limit) % 360 <= (upper_limit - lower_limit) % 360
    end

    def move_bot
      @heading += (@bot.turn || 0)
      vel = limit(@bot.drive || 0, 1.0) * @speed

      @vel_x += Gosu::offset_x(@heading, vel)
      @vel_y += Gosu::offset_y(@heading, vel)

      @x += @vel_x
      @y += @vel_y

      # The world is flat but it has walls (inset from the window when ArenaBounds is used).
      if @window.respond_to?(:play_min_x)
        @x = @window.play_min_x if @x < @window.play_min_x
        @y = @window.play_min_y if @y < @window.play_min_y
        @x = @window.play_max_x if @x > @window.play_max_x
        @y = @window.play_max_y if @y > @window.play_max_y
      else
        @x = 0 if @x < 0
        @y = 0 if @y < 0
        @x = @window.width if @x > @window.width
        @y = @window.height if @y > @window.height
      end

      # Add a velocity decay
      @vel_x *= 0.9
      @vel_y *= 0.9
    end

    def aim_turret
      @turret += limit(@bot.aim, @speed * 10)
    end

    def fire!
      if @ammo > 0 && @bot.shoot
        @ammo -= 50
        @window.bullets << Bullet.new(@window, [@x, @y, @turret, Gosu::offset_x(@turret, 100 * @strength + @vel_x.abs), Gosu::offset_y(@turret, 100 * @strength + @vel_y.abs)], @gun_sound)
      end
    end

    def limit(value, limit)
      return 0 if value.nil? || limit.nil?

      value = limit if value > limit && limit > 0
      value = limit if value < limit && limit < 0
      value
    end
  end
end
