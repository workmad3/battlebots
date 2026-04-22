require 'gosu'
require 'players'
require 'arena_bounds'
require 'bots/bot'
require 'tournament_schedule'
require 'tournament_health_timeout'
require 'tournament_bracket_visual'

module BattleBots
  # Single-elimination 1v1 bracket: each match spawns two proxies; winner advances.
  class TournamentWindow < Gosu::Window
    include BattleBots::Players
    include BattleBots::ArenaBounds

    COOLDOWN_FRAMES = 0
    # Assumes ~60 updates/sec (vsync). If both survive, highest health wins unless both are undamaged.
    MATCH_TIME_SECONDS = 60
    MATCH_LIMIT_FRAMES = MATCH_TIME_SECONDS * 60
    INTRO_FRAMES = 180
    WIN_DISPLAY_FRAMES = 180
    BRACKET_DISPLAY_FRAMES = 240

    # Drawn after all overlays so round / match status stays readable.
    ROUND_PANEL_BASE_Z = 600

    attr_accessor :bullets, :players, :explosions

    def initialize(width = 1800, height = 1200, _resize = false)
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
      @audience_layout = []
      @audience_body = Gosu::Image.new('media/body.png')
      @audience_turret = Gosu::Image.new('media/turret.png')
      @audience_label_font = Gosu::Font.new(11, name: Gosu::default_font_name)
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
        finalize_round_and_prepare_next! if @win_display_remaining <= 0
      when :cooldown
        @cooldown_frames -= 1
        finalize_round_and_prepare_next! if @cooldown_frames <= 0
      when :complete
        # frozen — ESC to quit
      end
    end

    def draw
      draw_margin_shade(0)
      # Bottom margin only, z under arena frame and fighters so the round panel cannot cover it.
      draw_audience(0) if show_audience?
      draw_arena_frame(z: 1)

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

      draw_tournament_round_panel
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
      return unless @match_ticks_remaining&.positive?

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

      # Elimination: go straight to the next match (or champion screen); no cooldown ticker.
      bullets.clear
      explosions.clear
      @match_ticks_remaining = nil
      finalize_round_and_prepare_next!
    end

    def setup_next_match!
      loop do
        matchup = @schedule.current_matchup
        if matchup.nil?
          @current_pair = nil
          @audience_layout = []
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
        rebuild_audience_layout!
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
      @match_ticks_remaining = nil
      @win_display_remaining = 0
      @phase = :cooldown
      @cooldown_frames = COOLDOWN_FRAMES
    end

    def finalize_round_and_prepare_next!
      if @schedule.finished?
        @phase = :complete
        @players = []
        @current_pair = nil
        @audience_layout = []
      else
        setup_next_match!
      end
    end

    def draw_tournament_round_panel
      return if @phase == :bracket || @phase == :intro || @phase == :win_display

      white = 0xff_ffffff
      line_h = 26
      pad_x = 14
      pad_y = 10
      origin_x = 12
      origin_y = 8

      rows = []
      rows << [:title, "Tournament — Round #{@schedule.round_number}", white]

      if @schedule.void_tournament?
        rows << [:text, 'No champion (both undamaged at time limit)', white]
      elsif @schedule.champion
        rows << [:champion]
      elsif @current_pair
        rows << [:match]
      end

      if @phase == :fighting && @match_ticks_remaining&.positive?
        sec = (@match_ticks_remaining / 60.0).ceil
        rows << [:text, "Match time left: #{sec}s", white]
      end

      if @phase == :cooldown
        rows << [:text, "Next match in #{[@cooldown_frames, 0].max}...", white]
      end

      inner_w = rows.map { |r| round_panel_row_width(r) }.max
      inner_h = rows.size * line_h
      box_w = inner_w + pad_x * 2
      box_h = inner_h + pad_y * 2
      max_bottom = play_min_y - 8
      box_y = origin_y
      if box_y + box_h > max_bottom
        box_y = [origin_y, max_bottom - box_h].min
        box_y = 4 if box_y < 4
      end
      box_x = origin_x

      z0 = ROUND_PANEL_BASE_Z
      z_fill = z0
      z_border = z0 + 1
      z_text = z0 + 2

      fill = Gosu::Color.new(245, 22, 26, 40)
      edge = Gosu::Color.new(255, 120, 200, 240)
      Gosu.draw_rect(box_x, box_y, box_w, box_h, fill, z_fill)
      draw_round_panel_border(box_x, box_y, box_w, box_h, z_border, edge)

      tx = box_x + pad_x
      ty = box_y + pad_y
      rows.each do |row|
        case row[0]
        when :title, :text
          @hud_font.draw_text(row[1], tx, ty, z_text, 1.0, 1.0, row[2])
        when :champion
          draw_hud_champion_line(tx, ty, z_text)
        when :match
          draw_hud_match_line(tx, ty, z_text)
        end
        ty += line_h
      end
    end

    def round_panel_row_width(row)
      case row[0]
      when :title, :text
        @hud_font.text_width(row[1])
      when :champion
        k = @schedule.champion
        @hud_font.text_width('Champion: ') + @hud_font.text_width(k.new.name)
      when :match
        a, b = @current_pair
        ln = a.new.name
        rn = b.new.name
        @hud_font.text_width('Match: ') + @hud_font.text_width(ln) + @hud_font.text_width('  vs  ') + @hud_font.text_width(rn)
      else
        0
      end
    end

    def draw_round_panel_border(x, y, w, h, z, color)
      t = 2
      Gosu.draw_rect(x, y, w, t, color, z)
      Gosu.draw_rect(x, y + h - t, w, t, color, z)
      Gosu.draw_rect(x, y, t, h, color, z)
      Gosu.draw_rect(x + w - t, y, t, h, color, z)
    end

    def draw_champion_overlay
      k = @schedule.champion
      name = k.new.name
      title = 'CHAMPION'
      tx = (width - @big_font.text_width(title)) / 2
      @big_font.draw_text(title, tx, height / 2 - 100, 0, 1.0, 1.0, 0xff_ffcc00)
      nx = (width - @title_font.text_width(name)) / 2
      nc = BattleBots::Bots::Bot.name_color_for_source(k.bot_source)
      @title_font.draw_text(name, nx, height / 2 + 20, 0, 1.0, 1.0, nc)
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

      a, b = @current_pair
      left = a.new.name
      right = b.new.name
      lx = (width * 0.5) - @title_font.text_width(left) - 80
      rx = (width * 0.5) + 80
      @title_font.draw_text(left, lx, height * 0.44, 20, 1.0, 1.0, name_color_for_bot_class(a))
      @title_font.draw_text(right, rx, height * 0.44, 20, 1.0, 1.0, name_color_for_bot_class(b))

      pulse = 1.0 + 0.06 * Math.sin(Gosu.milliseconds * 0.005)
      vs = 'VS'
      vw = @big_font.text_width(vs) * pulse
      vx = (width - vw) / 2
      @big_font.draw_text(vs, vx, height * 0.42, 20, pulse, pulse, 0xff_ffee66)

      bar_w = width * 0.5 * @intro_remaining.to_f / INTRO_FRAMES
      Gosu.draw_rect((width - width * 0.5) / 2, height * 0.62, width * 0.5, 8, Gosu::Color.new(60, 40, 40, 40), 20)
      if bar_w.positive?
        Gosu.draw_rect((width - width * 0.5) / 2, height * 0.62, bar_w, 8, Gosu::Color.new(255, 90, 200, 120),
                       21)
      end

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

        k = @last_winner_class
        name = k.new.name
        nx = (width - @title_font.text_width(name)) / 2
        nc = BattleBots::Bots::Bot.name_color_for_source(k.bot_source)
        @title_font.draw_text(name, nx, height * 0.56, 20, 1.0, 1.0, nc)
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

    def draw_hud_champion_line(x, y, z)
      k = @schedule.champion
      nm = k.new.name
      pre = 'Champion: '
      white = 0xff_ffffff
      @hud_font.draw_text(pre, x, y, z, 1.0, 1.0, white)
      x2 = x + @hud_font.text_width(pre)
      @hud_font.draw_text(nm, x2, y, z, 1.0, 1.0, name_color_for_bot_class(k))
    end

    def draw_hud_match_line(x, y, z)
      a, b = @current_pair
      ln = a.new.name
      rn = b.new.name
      pre = 'Match: '
      mid = '  vs  '
      white = 0xff_ffffff
      @hud_font.draw_text(pre, x, y, z, 1.0, 1.0, white)
      x2 = x + @hud_font.text_width(pre)
      @hud_font.draw_text(ln, x2, y, z, 1.0, 1.0, name_color_for_bot_class(a))
      x2 += @hud_font.text_width(ln)
      @hud_font.draw_text(mid, x2, y, z, 1.0, 1.0, white)
      x2 += @hud_font.text_width(mid)
      @hud_font.draw_text(rn, x2, y, z, 1.0, 1.0, name_color_for_bot_class(b))
    end

    def name_color_for_bot_class(klass)
      BattleBots::Bots::Bot.name_color_for_source(klass.bot_source)
    end

    def show_audience?
      @current_pair && @phase != :complete
    end

    def rebuild_audience_layout!
      @audience_layout = []
      return unless @current_pair

      a, b = @current_pair
      extras = bot_classes.reject { |k| k == a || k == b }
      return if extras.empty?

      m = arena_margin
      n = extras.size

      # All audience in the bottom margin (below play_max_y) so the top round HUD never covers it.
      if n <= 8
        place_audience_row!(extras, height - m * 0.52)
      else
        half = (n + 1) / 2
        place_audience_row!(extras[0, half], height - m * 0.68)
        place_audience_row!(extras[half, n - half], height - m * 0.36)
      end
    end

    def place_audience_row!(list, y)
      m = arena_margin
      inner_w = width - 2 * m - 24
      gap = inner_w / [list.size, 1].max
      base_x = m + 12 + gap * 0.5
      list.each_with_index do |klass, i|
        x = base_x + gap * i
        yy = y
        @audience_layout << {
          klass: klass,
          name: klass.new.name,
          x: x,
          y: yy,
          base_heading: @rng.rand(360),
          base_turret: @rng.rand(360)
        }
      end
    end

    def draw_audience(z)
      return if @audience_layout.empty?

      eliminated = @schedule.eliminated_bot_classes
      t = Gosu.milliseconds * 0.004
      label_dy = @audience_body.height / 2 + 6
      @audience_layout.each do |slot|
        k = slot[:klass]
        cx = slot[:x]
        cy = slot[:y]
        col = BattleBots::Bots::Bot.name_color_for_source(k.bot_source)
        if eliminated.include?(k)
          @audience_body.draw_rot(cx, cy, z, slot[:base_heading], 0.5, 0.5, 1, 1)
        else
          heading = slot[:base_heading] + 18 * Math.sin(t + slot[:x] * 0.01)
          turret = slot[:base_turret] + 22 * Math.sin(t * 1.1 + slot[:y] * 0.01)
          @audience_body.draw_rot(cx, cy, z, heading, 0.5, 0.5, 1, 1)
          @audience_turret.draw_rot(cx, cy, z, turret, 0.5, 0.5, 1, 1)
        end
        nm = slot[:name]
        tw = @audience_label_font.text_width(nm)
        @audience_label_font.draw_text(nm, cx - tw / 2, cy + label_dy, z, 1.0, 1.0, col)
      end
    end
  end
end
