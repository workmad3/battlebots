require 'gosu'
require 'bots/bot'

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

    # Column 0: one box per competitor (two per opening match, one for a bye). Higher columns
    # merge pairs into winner slots; :log_round is the schedule round for that match's log row.
    def build_columns(pairs, margin_top, usable_h)
      return [] if pairs.empty?

      slots = []
      pairs.each_with_index do |(a, b), i|
        if b.nil?
          slots << { fighter: a, open_idx: i }
        else
          slots << { fighter: a, open_idx: i }
          slots << { fighter: b, open_idx: i }
        end
      end

      n_slots = slots.size
      y0 = n_slots.times.map { |idx| margin_top + (idx + 0.5) * usable_h / n_slots }
      leaves = slots.zip(y0).map { |slot, y| slot.merge(col: 0, y: y) }
      cols = [leaves]
      while cols.last.size > 1
        prev = cols.last
        nxt = []
        i = 0
        while i < prev.size
          if i + 1 < prev.size
            l, r = prev[i], prev[i + 1]
            y = (l[:y] + r[:y]) / 2.0
            log_round = merge_log_round(l, r)
            nxt << { y: y, left: l, right: r, col: l[:col] + 1, log_round: log_round }
            i += 2
          else
            lone = prev[i]
            log_round = lone[:fighter] ? 1 : lone[:log_round] + 1
            nxt << { y: lone[:y], left: lone, right: nil, col: lone[:col] + 1, log_round: log_round }
            i += 1
          end
        end
        cols << nxt
      end
      cols
    end

    def merge_log_round(left, right)
      if fighter_pair?(left, right)
        1
      else
        [left[:log_round] || 0, right[:log_round] || 0].max + 1
      end
    end

    def fighter_pair?(a, b)
      a[:fighter] && b[:fighter] && a[:open_idx] == b[:open_idx]
    end

    # Log rows for a round are not guaranteed to be in bracket left-to-right order (shuffle
    # between rounds, completion order). Match inner slots by {a,b} vs subtree winners instead.
    def inner_label_for_cell(schedule, cell)
      unless cell[:right]
        w = match_winner_out_of_node(schedule, cell[:left])
        return ['TBD', ''] unless w

        return ["#{abbrev(schedule, w)} (bye)", '']
      end

      ev = inner_bracket_event(schedule, cell)
      return lines_from_event(schedule, ev) if ev

      if fighter_pair?(cell[:left], cell[:right])
        oi = cell[:left][:open_idx]
        a, b = schedule.first_round_snapshot[oi]
        return ["#{abbrev(schedule, a)} vs #{abbrev(schedule, b)}", ''] if b

        return ['TBD', '']
      end

      wl = match_winner_out_of_node(schedule, cell[:left])
      wr = match_winner_out_of_node(schedule, cell[:right])
      if wl && wr
        return ["#{abbrev(schedule, wl)} vs #{abbrev(schedule, wr)}", '']
      end

      ['TBD', '']
    end

    def inner_bracket_event(schedule, cell)
      return nil unless cell[:left] && cell[:right]

      r = cell[:log_round]
      if fighter_pair?(cell[:left], cell[:right])
        return r1_event_for_opening(schedule, cell[:left][:open_idx])
      end

      wl = match_winner_out_of_node(schedule, cell[:left])
      wr = match_winner_out_of_node(schedule, cell[:right])
      return nil unless wl && wr

      schedule.results_log.find { |e| e[:round] == r && same_pair?(e, wl, wr) }
    end

    def same_pair?(e, x, y)
      return false unless x && y

      ea = e[:a]
      eb = e[:b]
      (ea == x && eb == y) || (ea == y && eb == x)
    end

    def r1_event_for_opening(schedule, open_idx)
      pair = schedule.first_round_snapshot[open_idx]
      return nil unless pair

      a0, b0 = pair
      schedule.results_log.find do |e|
        next false unless e[:round] == 1

        if b0.nil?
          e[:a] == a0 && e[:b].nil?
        else
          (e[:a] == a0 && e[:b] == b0) || (e[:a] == b0 && e[:b] == a0)
        end
      end
    end

    def winner_from_event(e)
      return nil unless e

      case e[:outcome]
      when :draw
        nil
      when :bye, :left, :right
        e[:winner]
      else
        e[:winner]
      end
    end

    def match_winner_out_of_node(schedule, node)
      return nil unless node

      if node[:fighter]
        return opening_match_winner(schedule, node[:open_idx])
      end

      return match_winner_out_of_node(schedule, node[:left]) unless node[:right]

      ev = inner_bracket_event(schedule, node)
      winner_from_event(ev)
    end

    def opening_match_winner(schedule, open_idx)
      winner_from_event(r1_event_for_opening(schedule, open_idx))
    end

    def lines_from_event(schedule, ev)
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

      slot_n = cols.first.size
      comp_h = [[(usable_h / [slot_n, 1].max) * 0.72, box_h * 0.48].min, 22.0].max

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
          if cell[:fighter]
            draw_competitor_cell(window, schedule, bracket_font, cx, cell[:y], box_w * sx, comp_h, cell, sx)
          else
            draw_inner_cell(window, schedule, bracket_font, cx, cell[:y], box_w * sx, box_h, cell, sx)
          end
        end
      end

      head = 'BRACKET'
      hx = (window.width - title_font.text_width(head)) / 2
      title_font.draw_text(head, hx, 40, Z_TEXT + 10, 1.0, 1.0, Gosu::Color.new(255, 255, 210, 255))
    end

    def draw_competitor_cell(window, schedule, font, cx, cy, w, h, cell, sx)
      k = cell[:fighter]
      name = abbrev(schedule, k)
      col = competitor_name_color(schedule, cell)

      next_slot = schedule.round_number == 1 && cell[:open_idx] == schedule.match_index
      border = next_slot ? COL_BORDER_NEXT : COL_BORDER

      x0 = cx
      y0 = cy - h / 2
      Gosu.draw_rect(x0, y0, w, h, COL_BG, Z_BG)
      Gosu.draw_rect(x0, y0, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0 + h - 2, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0, 2, h, border, Z_BOX)
      Gosu.draw_rect(x0 + w - 2, y0, 2, h, border, Z_BOX)

      ty = y0 + [((h - 18 * sx) / 2.0), 3.0].max
      font.draw_text(name, x0 + 6, ty, Z_TEXT, sx, sx, col)
    end

    def competitor_name_color(schedule, cell)
      k = cell[:fighter]
      base = BattleBots::Bots::Bot.name_color_for_source(k.bot_source)
      ev = r1_event_for_opening(schedule, cell[:open_idx])
      return base unless ev

      w = winner_from_event(ev)
      return COL_DRAW if ev[:outcome] == :draw
      return base if ev[:outcome] == :bye
      return base if w.nil?

      w == k ? base : COL_DIM
    end

    def draw_inner_cell(window, schedule, font, cx, cy, w, h, cell, sx)
      line1, line2 = inner_label_for_cell(schedule, cell)
      ev = inner_bracket_event(schedule, cell)
      border = COL_BORDER
      x0 = cx
      y0 = cy - h / 2
      Gosu.draw_rect(x0, y0, w, h, COL_BG, Z_BG)
      Gosu.draw_rect(x0, y0, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0 + h - 2, w, 2, border, Z_BOX)
      Gosu.draw_rect(x0, y0, 2, h, border, Z_BOX)
      Gosu.draw_rect(x0 + w - 2, y0, 2, h, border, Z_BOX)

      c1 = inner_result_name_color(ev, line1)
      font.draw_text(line1, x0 + 6, y0 + 10, Z_TEXT, sx, sx, c1)
      font.draw_text(line2, x0 + 6, y0 + 26 * sx, Z_TEXT, sx, sx, c1) if line2 && !line2.empty?
    end

    def inner_result_name_color(entry, line1)
      return COL_TBD if line1 == 'TBD'
      return COL_DRAW if line1 == 'Draw'
      return COL_TEXT if line1 == '?'
      return COL_TEXT if entry.nil?

      case entry[:outcome]
      when :bye
        BattleBots::Bots::Bot.name_color_for_source(entry[:a].bot_source)
      when :left
        BattleBots::Bots::Bot.name_color_for_source(entry[:a].bot_source)
      when :right
        BattleBots::Bots::Bot.name_color_for_source(entry[:b].bot_source)
      else
        COL_TEXT
      end
    end
  end
end
