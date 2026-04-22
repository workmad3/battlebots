require 'players'
require 'tournament_schedule'
require 'tournament_health_timeout'
require 'tournament_bracket_visual'

module BattleBots
  # Single-elimination 1v1 bracket: each match spawns two proxies; winner advances.
  class TournamentWindow < Gosu::Window
    include BattleBots::Players

    COOLDOWN_FRAMES = 85
    # Assumes ~60 updates/sec (vsync). If both survive, highest health wins unless both are undamaged.
    MATCH_TIME_SECONDS = 90
    MATCH_LIMIT_FRAMES = MATCH_TIME_SECONDS * 60
    INTRO_FRAMES = 120
    WIN_DISPLAY_FRAMES = 96
    BRACKET_DISPLAY_FRAMES = 200

    attr_accessor :bullets, :players, :explosions

    def initialize(width = 1200, height = 800, _resize = false)
      super(width, height)
      self.caption = 'BattleBots — Tournament'
      @bullets = []
      @explosions = []
      @players = []
      @rng = Random.new
      @schedule = TournamentSchedule.new(bot_classes, rng: @rng)
      @phase = :intro
      @intro_remaining = 0
      @cooldown_frames = 0
      @win_display_remaining = 0
      @last_result = nil
      @last_winner_class = nil
      @current_pair = nil
      @hud_font = Gosu::Font.new(28, name: Gosu::default_font_name)
      @title_font = Gosu::Font.new(56, name: Gosu::default_font_name)
      @big_font = Gosu::Font.new(120, name: Gosu::default_font_name)
      @bracket_font = Gosu::Font.new(18, name: Gosu::default_font_name)
      @bracket_remaining = 0
      setup_next_match!
    end

    def update
      case @phase
      when :bracket
        @bracket_remaining -= 1
        @phase = :intro if @bracket_remaining <= 0
      when :intro
        @intro_remaining -= 1
        @phase = :fighting if @intro_remaining <= 0
      when :fighting
        update_fight
        tick_match_timeout! if @phase == :fighting
      when :win_display
        @win_display_remaining -= 1
        enter_cooldown! if @win_display_remaining <= 0
      when :cooldown
        @cooldown_frames -= 1
        if @cooldown_frames <= 0
          if @schedule.finished?
            @phase = :complete
            @players = []
          else
            setup_next_match!
          end
        end
      when :complete
        # frozen — ESC to quit
      end
    end

    def draw
      draw_hud
      [players || [], bullets, explosions].each do |collection|
        collection.each(&:draw)
      end
      draw_bracket_overlay if @phase == :bracket
      draw_intro_overlay if @phase == :intro
      draw_match_result_overlay if @phase == :win_display
      if @phase == :complete
        draw_champion_overlay if @schedule.champion
        draw_void_overlay if @schedule.void_tournament?
      end
    end

    def button_down(id)
      close if id == Gosu::KbEscape
      return unless id == Gosu::KbSpace

      case @phase
      when :bracket
        @phase = :intro
        @intro_remaining = INTRO_FRAMES
      when :intro
        @phase = :fighting
      when :win_display
        enter_cooldown!
      end
    end

    private

    def tick_match_timeout!
      return unless @match_ticks_remaining

      @match_ticks_remaining -= 1
      return if @match_ticks_remaining.positive?

      resolve_match_timeout!
    end

    def resolve_match_timeout!
      result = :win
      winner_class = nil

      case players.size
      when 2
        p0, p1 = players
        case TournamentHealthTimeout.outcome(p0.health, p1.health, rng: @rng)
        when :draw
          @schedule.record_match_draw
          result = :draw
        when :first
          winner_class = p0.bot.class
          @schedule.record_match_winner(winner_class)
        when :second
          winner_class = p1.bot.class
          @schedule.record_match_winner(winner_class)
        end
      when 1
        winner_class = players.first.bot.class
        @schedule.record_match_winner(winner_class)
      else
        a, b = @current_pair
        winner_class = @rng.rand(2).zero? ? a : b
        @schedule.record_match_winner(winner_class)
      end

      bullets.clear
      explosions.clear
      @match_ticks_remaining = nil
      start_win_display!(result, winner_class)
    end

    def update_fight
      bullets.each do |bullet|
        bullet.move
        bullet.decay
      end
      bullets.delete_if(&:decayed?)

      players.each do |player|
        player.hit? bullets
        player.play
      end
      players.delete_if(&:dead?)

      return if players.size >= 2

      winner_class = nil
      if players.size == 1
        winner_class = players.first.bot.class
        @schedule.record_match_winner(winner_class)
      elsif players.empty?
        a, b = @current_pair
        winner_class = @rng.rand(2).zero? ? a : b
        @schedule.record_match_winner(winner_class)
      end

      # Elimination: no post-match countdown; clock and arena clear immediately.
      bullets.clear
      explosions.clear
      @match_ticks_remaining = nil
      enter_cooldown!
    end

    def setup_next_match!
      loop do
        matchup = @schedule.current_matchup
        if matchup.nil?
          @phase = :complete if @schedule.finished?
          @players = []
          return
        end

        a, b = matchup
        if b.nil?
          @schedule.record_match_winner(a)
          next
        end

        @current_pair = [a, b]
        @players = [Proxy.new(self, a), Proxy.new(self, b)]
        @match_ticks_remaining = MATCH_LIMIT_FRAMES
        bullets.clear
        explosions.clear
        if @schedule.take_opening_bracket! || @schedule.take_round_bracket_flag!
          @phase = :bracket
          @bracket_remaining = BRACKET_DISPLAY_FRAMES
        else
          @phase = :intro
          @intro_remaining = INTRO_FRAMES
        end
        return
      end
    end

    def start_win_display!(result, winner_class)
      @last_result = result
      @last_winner_class = winner_class
      @win_display_remaining = WIN_DISPLAY_FRAMES
      @phase = :win_display
    end

    def enter_cooldown!
      @win_display_remaining = 0
      @phase = :cooldown
      @cooldown_frames = COOLDOWN_FRAMES
    end

    def draw_hud
      lines = []
      lines << "Tournament — Round #{@schedule.round_number}"
      if @schedule.void_tournament?
        lines << 'No champion (both undamaged at time limit)'
      elsif @schedule.champion
        lines << "Champion: #{@schedule.champion.new.name}"
      elsif @current_pair
        left = @current_pair[0].new.name
        right = @current_pair[1].new.name
        lines << "Match: #{left}  vs  #{right}"
      end
      if @phase == :fighting && @match_ticks_remaining
        sec = (@match_ticks_remaining / 60.0).ceil
        lines << "Match time left: #{sec}s"
      end
      lines << (@phase == :cooldown ? "Next match in #{[@cooldown_frames, 0].max}..." : '')
      if @phase == :bracket || @phase == :intro || @phase == :win_display
        lines << 'Space - skip bracket / title / winner animation'
      end

      y = 8
      lines.each do |line|
        next if line.empty?

        @hud_font.draw_text(line, 12, y, 0, 1.0, 1.0, 0xff_ffffff)
        y += 32
      end
    end

    def draw_champion_overlay
      name = @schedule.champion.new.name
      title = 'CHAMPION'
      tx = (width - @big_font.text_width(title)) / 2
      @big_font.draw_text(title, tx, height / 2 - 100, 0, 1.0, 1.0, 0xff_ffcc00)
      nx = (width - @title_font.text_width(name)) / 2
      @title_font.draw_text(name, nx, height / 2 + 20, 0, 1.0, 1.0, 0xff_ffffff)
    end

    def draw_void_overlay
      title = 'NO CHAMPION'
      sub = 'Timed out with both bots undamaged'
      tx = (width - @big_font.text_width(title)) / 2
      @big_font.draw_text(title, tx, height / 2 - 100, 0, 1.0, 1.0, 0xff_cccccc)
      sx = (width - @title_font.text_width(sub)) / 2
      @title_font.draw_text(sub, sx, height / 2 + 30, 0, 1.0, 1.0, 0xff_cccccc)
    end

    def draw_intro_overlay
      dim = Gosu::Color.new(210, 8, 10, 24)
      Gosu.draw_rect(0, 0, width, height, dim, 10)
      k = 'NEXT MATCH'
      kx = (width - @big_font.text_width(k)) / 2
      @big_font.draw_text(k, kx, height * 0.18, 20, 1.0, 1.0, 0xff_ffdd88)

      r = "Round #{@schedule.round_number}"
      rx = (width - @title_font.text_width(r)) / 2
      @title_font.draw_text(r, rx, height * 0.30, 20, 1.0, 1.0, 0xff_eeeeee)

      left = @current_pair[0].new.name
      right = @current_pair[1].new.name
      lx = (width * 0.5) - @title_font.text_width(left) - 80
      rx = (width * 0.5) + 80
      @title_font.draw_text(left, lx, height * 0.44, 20, 1.0, 1.0, 0xff_ccf5ff)
      @title_font.draw_text(right, rx, height * 0.44, 20, 1.0, 1.0, 0xff_ffccf5)

      pulse = 1.0 + 0.06 * Math.sin(Gosu.milliseconds * 0.005)
      vs = 'VS'
      vw = @big_font.text_width(vs) * pulse
      vx = (width - vw) / 2
      @big_font.draw_text(vs, vx, height * 0.42, 20, pulse, pulse, 0xff_ffee66)

      bar_w = width * 0.5 * @intro_remaining.to_f / INTRO_FRAMES
      Gosu.draw_rect((width - width * 0.5) / 2, height * 0.62, width * 0.5, 8, Gosu::Color.new(60, 40, 40, 40), 20)
      Gosu.draw_rect((width - width * 0.5) / 2, height * 0.62, bar_w, 8, Gosu::Color.new(255, 90, 200, 120), 21) if bar_w.positive?

      sec = (@intro_remaining / 60.0).ceil
      t = "Starting in #{sec}s..."
      tx = (width - @hud_font.text_width(t)) / 2
      @hud_font.draw_text(t, tx, height * 0.70, 20, 1.0, 1.0, 0xff_cccccc)
    end

    def draw_match_result_overlay
      dim = Gosu::Color.new(200, 10, 8, 18)
      Gosu.draw_rect(0, 0, width, height, dim, 10)

      if @last_result == :draw
        t = 'DRAW'
        tx = (width - @big_font.text_width(t)) / 2
        @big_font.draw_text(t, tx, height * 0.36, 20, 1.0, 1.0, 0xff_cccccc)
        sub = 'No bracket winner - both undamaged'
        sx = (width - @title_font.text_width(sub)) / 2
        @title_font.draw_text(sub, sx, height * 0.52, 20, 1.0, 1.0, 0xff_bbbbbb)
      else
        rw = 'ROUND WIN'
        rwx = (width - @title_font.text_width(rw)) / 2
        @title_font.draw_text(rw, rwx, height * 0.28, 20, 1.0, 1.0, 0xff_ddeeff)

        pulse = 1.0 + 0.12 * Math.sin(Gosu.milliseconds * 0.006)
        w = 'WINNER'
        wx = (width - @big_font.text_width(w) * pulse) / 2
        @big_font.draw_text(w, wx, height * 0.38, 20, pulse, pulse, 0xff_ffcc44)

        name = @last_winner_class.new.name
        nx = (width - @title_font.text_width(name)) / 2
        @title_font.draw_text(name, nx, height * 0.56, 20, 1.0, 1.0, 0xff_ffffff)
      end

      hint = 'Next match follows...'
      hx = (width - @hud_font.text_width(hint)) / 2
      @hud_font.draw_text(hint, hx, height * 0.72, 20, 1.0, 1.0, 0xff_999999)
    end

    def draw_bracket_overlay
      dim = Gosu::Color.new(215, 6, 8, 20)
      Gosu.draw_rect(0, 0, width, height, dim, 12)
      sub = 'BRACKET VIEW'
      sx = (width - @title_font.text_width(sub)) / 2
      @title_font.draw_text(sub, sx, 72, 12, 0.55, 0.55, 0xff_ccccdd)

      BattleBots::TournamentBracketVisual.draw(
        window: self,
        schedule: @schedule,
        title_font: @title_font,
        bracket_font: @bracket_font
      )

      bar_w = width * 0.55 * @bracket_remaining.to_f / BRACKET_DISPLAY_FRAMES
      bx = (width - width * 0.55) / 2
      by = height - 52
      Gosu.draw_rect(bx, by, width * 0.55, 6, Gosu::Color.new(55, 50, 50, 55), 21)
      Gosu.draw_rect(bx, by, bar_w, 6, Gosu::Color.new(240, 120, 200, 160), 22) if bar_w.positive?

      hint = 'Space - continue to match intro'
      tx = (width - @hud_font.text_width(hint)) / 2
      @hud_font.draw_text(hint, tx, height - 28, 20, 1.0, 1.0, 0xff_bbbbbb)
    end
  end
end
