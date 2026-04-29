lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'gosu'
require 'players'
require 'arena_bounds'
require 'bots/bot'

module BattleBots
  class Game < Gosu::Window
    include BattleBots::Players
    include BattleBots::ArenaBounds

    attr_accessor :bullets, :players, :explosions

    def initialize(x = 1800, y = 1200, resize = false)
      super
      @players = player_list
      @bullets = []
      @explosions = []
      @winner_played = false
      @font = Gosu::Font.new(200, name: Gosu::default_font_name)
    end

    def update
      bullets.each do |bullet|
        bullet.move
        bullet.decay
      end
      bullets.delete_if { |bullet| bullet.decayed? }      

      players.each do |player|
        player.hit? bullets
        player.play
      end
      players.delete_if { |player| player.dead? }
    end

    def draw
      draw_margin_shade(0)
      draw_arena_frame(z: 1)
      [players, bullets, explosions].each do |collection_of_drawables|
        collection_of_drawables.each { |drawable| drawable.draw }
      end

      if players.length == 1
        display_winner players.first 
      end 
    end

    def button_up(id)
    end

    def button_down(id)
      close if id == Gosu::KbEscape
    end

    private 

    def display_winner(proxy)
      @font.draw_text('WINNER!', 200, 300, 0, 1.0, 1.0, 0xff_ffff00)
      nm = proxy.bot.name
      sc = 0.42
      nc = BattleBots::Bots::Bot.name_color_for_source(proxy.bot.bot_source)
      @font.draw_text(nm, 200, 520, 0, sc, sc, nc)
      unless @winner_played
        @winner_played = true
      end
    end
  end
end

BattleBots::Game.new.show
