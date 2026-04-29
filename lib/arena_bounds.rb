require 'gosu'

module BattleBots
  # Inset from the window border so sprites (and nearby HUD) are not clipped.
  module ArenaBounds
    # Large enough for the tournament round HUD panel to sit entirely above the playable arena.
    ARENA_MARGIN = 168
    ARENA_BORDER_THICK = 4
    # Proxies clamp tank *center* to play_*; body.png extends about this far past center (see Proxy hit radius).
    TANK_BODY_HALF_WIDTH = 25

    def arena_margin
      ARENA_MARGIN
    end

    def play_min_x
      arena_margin
    end

    def play_max_x
      width - arena_margin
    end

    def play_min_y
      arena_margin
    end

    def play_max_y
      height - arena_margin
    end

    # Slight tint in the margin strips (outside the playable rectangle).
    def draw_margin_shade(z = 0, color = Gosu::Color.new(40, 14, 16, 22))
      m = arena_margin
      Gosu.draw_rect(0, 0, width, m, color, z)
      Gosu.draw_rect(0, height - m, width, m, color, z)
      Gosu.draw_rect(0, m, m, height - 2 * m, color, z)
      Gosu.draw_rect(width - m, m, m, height - 2 * m, color, z)
    end

    # Frame outset: centers clamp to play_*; hull extends ~half_width beyond those lines, so the border is drawn outside the hull envelope.
    def draw_arena_frame(z: 2, color: Gosu::Color.new(255, 130, 210, 240))
      half = TANK_BODY_HALF_WIDTH
      x0 = play_min_x - half
      y0 = play_min_y - half
      x1 = play_max_x + half
      y1 = play_max_y + half
      return if x1 <= x0 || y1 <= y0

      t = ARENA_BORDER_THICK
      w = x1 - x0
      h = y1 - y0
      Gosu.draw_rect(x0, y0, w, t, color, z)
      Gosu.draw_rect(x0, y1 - t, w, t, color, z)
      Gosu.draw_rect(x0, y0, t, h, color, z)
      Gosu.draw_rect(x1 - t, y0, t, h, color, z)
    end
  end
end
