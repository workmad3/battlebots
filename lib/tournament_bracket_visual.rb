require 'gosu'

module BattleBots
  # Geometric single-elimination bracket: columns merge upward; labels from opening
  # snapshot + results_log (inner columns use log round == column_index + 1).
  module TournamentBracketVisual
    extend self

    Z_BG = 13
    Z_LINE = 14
    Z_BOX = 15
    Z_TEXT = 16

    COL_BG = Gosu::Color.new(210, 28, 32, 42)
    COL_BORDER = Gosu::Color.new(255, 170, 185, 210)
    COL_BORDER_NEXT = Gosu::Color.new(255, 230, 120, 255)
    COL_LINE = Gosu::Color.new(200, 130, 150, 140)
    COL_TEXT = Gosu::Color.new(255, 236, 244, 255)
    COL_DIM = Gosu::Color.new(255, 150, 160, 150)
    COL_WIN = Gosu::Color.new(255, 210, 140, 255)
    COL_DRAW = Gosu::Color.new(255, 200, 120, 220)
    COL_TBD = Gosu::Color.new(220, 200, 210, 140)

    def abbrev(schedule, klass, max_len = 11)
      s = schedule.display_name(klass)
      s.length > max_len ? "#{s[0, max_len]}..." : s
    end

    def build_columns(pairs, margin_top, usable_h)
      n = pairs.size
      return [] if n.zero?

      y0 = n.times.map { |i| margin_top + (i + 0.5) * usable_h / n }
      leaves = pairs.zip(y0).map.with_index do |((a, b), y), i|
        { y: y, a: a, b: b, open_idx: i, col: 0 }
      end
      cols = [leaves]
      while cols.last.size > 1
        prev = cols.last
        nxt = []
        i = 0
        while i < prev.size
          if i + 1 < prev.size
            y = (prev[i][:y] + prev[i + 1][:y]) / 2.0
            nxt << { y: y, left: prev[i], right: prev[i + 1], col: prev[i][:col] + 1 }
            i += 2
          else
            nxt << { y: prev[i][:y], left: prev[i], right: nil, col: prev[i][:col] + 1 }
            i += 1
          end
        end
        cols << nxt
      end
      cols
    end

    def opening_events(schedule)
      schedule.results_log.select { |e| e[:round] == 1 }
    end

    def leaf_entry(schedule, open_idx)
      opening_events(schedule)[open_idx]
    end

    def inner_entry(schedule, col_idx, slot_idx)
      r = col_idx + 1
      schedule.results_log.select { |e| e[:round] == r }[slot_idx]
    end

    def leaf_line_colors(entry, schedule)
      return [COL_TEXT, COL_TEXT] unless entry

      case entry[:outcome]
      when :bye
        [COL_WIN, COL_DIM]
      when :draw
        [COL_DRAW, COL_DRAW]
      when :left
        [COL_WIN, COL_DIM]
      when :right
        [COL_DIM, COL_WIN]
      else
        [COL_TEXT, COL_TEXT]
      end
    end

    def inner_label(schedule, col_idx, slot_idx)
      ev = inner_entry(schedule, col_idx, slot_idx)
      return ['TBD', ''] unless ev

      case ev[:outcome]
      when :draw
        ['Draw', '']
      when :bye
        ["#{abbrev(schedule, ev[:a])} (bye)", '']
      when :left, :right
        w = ev[:winner]
        [abbrev(schedule, w), '']
      else
        ['?', '']
      end
    end

    def draw(window:, schedule:, title_font:, bracket_font:)
      pairs = schedule.first_round_snapshot
      return if pairs.empty?

      margin_top = 100
      margin_bottom = 100
      margin_x = 32
      usable_h = window.height - margin_top - margin_bottom
      cols = build_columns(pairs, margin_top, usable_h)
      num_cols = cols.size
      box_w = 108
      col_gap = 52
      box_h = 40
      arm = 26

      total_w = margin_x + num_cols * (box_w + col_gap) + 24
      sx = [1.0, (window.width * 0.94) / total_w].min

      x_for = ->(d) { margin_x + d * (box_w + col_gap) * sx }

      # Connectors + boxes (left -> right)
      (1...num_cols).each do |d|
        cols[d].each_with_index do |cell, j|
          lx = x_for.call(d - 1) + box_w * sx
          jx = lx + arm * sx
          px = x_for.call(d)

          if cell[:right]
            ly = cell[:left][:y]
            ry = cell[:right][:y]
            Gosu.draw_line(lx, ly, COL_LINE, jx, ly, COL_LINE, Z_LINE)
            Gosu.draw_line(lx, ry, COL_LINE, jx, ry, COL_LINE, Z_LINE)
            Gosu.draw_line(jx, ly, COL_LINE, jx, ry, COL_LINE, Z_LINE)
            mid_y = (ly + ry) / 2.0
            Gosu.draw_line(jx, mid_y, COL_LINE, px, cell[:y], COL_LINE, Z_LINE)
          elsif cell[:left]
            Gosu.draw_line(lx, cell[:left][:y], COL_LINE, px, cell[:y], COL_LINE, Z_LINE)
          end
        end
      end

      cols.each_with_index do |column, d|
        cx = x_for.call(d)
        column.each_with_index do |cell, j|
          if cell[:a]
            draw_leaf_cell(window, schedule, bracket_font, cx, cell[:y], box_w * sx, box_h, cell, sx)
          else
            draw_inner_cell(window, schedule, bracket_font, cx, cell[:y], box_w * sx, box_h, cell[:col], j, sx)
          end
        end
      end

      head = 'BRACKET'
      hx = (window.width - title_font.text_width(head)) / 2
      title_font.draw_text(head, hx, 40, Z_TEXT + 10, 1.0, 1.0, Gosu::Color.new(255, 255, 210, 255))
    end

    def draw_leaf_cell(window, schedule, font, cx, cy, w, h, cell, sx)
      entry = leaf_entry(schedule, cell[:open_idx])
      top = abbrev(schedule, cell[:a])
      bot = cell[:b] ? abbrev(schedule, cell[:b]) : 'BYE'
      c1, c2 = leaf_line_colors(entry, schedule)

      next_slot = schedule.round_number == 1 && cell[:open_idx] == schedule.match_index
      border = next_slot ? COL_BORDER_NEXT : COL_BORDER
      br = border

      x0 = cx
      y0 = cy - h / 2
      Gosu.draw_rect(x0, y0, w, h, COL_BG, Z_BG)
      Gosu.draw_rect(x0, y0, w, 2, br, Z_BOX)
      Gosu.draw_rect(x0, y0 + h - 2, w, 2, br, Z_BOX)
      Gosu.draw_rect(x0, y0, 2, h, br, Z_BOX)
      Gosu.draw_rect(x0 + w - 2, y0, 2, h, br, Z_BOX)

      ty = y0 + 4
      font.draw_text(top, x0 + 6, ty, Z_TEXT, sx, sx, c1)
      font.draw_text(bot, x0 + 6, ty + 18 * sx, Z_TEXT, sx, sx, c2)
    end

    def draw_inner_cell(window, schedule, font, cx, cy, w, h, col_idx, slot_idx, sx)
      line1, line2 = inner_label(schedule, col_idx, slot_idx)
      border = COL_BORDER
      x0 = cx
      y0 = cy - h / 2
      Gosu.draw_rect(x0, y0, w, h, COL_BG, Z_BG)
      Gosu.draw_rect(x0, y0, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0 + h - 2, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0, 2, h, border, Z_BOX)
      Gosu.draw_rect(x0 + w - 2, y0, 2, h, border, Z_BOX)

      c = line1 == 'TBD' ? COL_TBD : COL_TEXT
      font.draw_text(line1, x0 + 6, y0 + 10, Z_TEXT, sx, sx, c)
      font.draw_text(line2, x0 + 6, y0 + 26 * sx, Z_TEXT, sx, sx, c) if line2 && !line2.empty?
    end
  end
end
