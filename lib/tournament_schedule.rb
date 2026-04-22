module BattleBots
  # Single-elimination bracket for bot classes (no Gosu). Byes auto-advance one slot.
  class TournamentSchedule
    attr_reader :round_number, :champion, :first_round_snapshot, :results_log, :match_index

    def initialize(bot_classes, rng: Random.new)
      @rng = rng
      @round_number = 1
      @entrants = bot_classes.dup.shuffle(random: @rng)
      @matches = self.class.pair(@entrants, rng: @rng)
      @first_round_snapshot = @matches.map { |pair| [pair[0], pair[1]] }
      @match_index = 0
      @round_winners = []
      @champion = nil
      @void_tournament = false
      @results_log = []
      @name_cache = {}
      @show_opening_bracket = true
      @round_bracket_flag = false
    end

    def void_tournament?
      @void_tournament
    end

    def finished?
      !@champion.nil? || @void_tournament
    end

    def take_opening_bracket!
      v = @show_opening_bracket
      @show_opening_bracket = false
      v
    end

    def take_round_bracket_flag!
      v = @round_bracket_flag
      @round_bracket_flag = false
      v
    end

    def display_name(klass)
      @name_cache[klass] ||= (klass.respond_to?(:new) ? klass.new.name : klass.to_s)
    end

    # Lines for a full-screen bracket summary (opening + between rounds).
    def bracket_overlay_lines(max_lines = 44)
      lines = []
      lines << 'TOURNAMENT BRACKET'
      lines << "Highlight round: #{@round_number}"
      lines << ''
      lines << '--- Opening pairings ---'
      @first_round_snapshot.each do |a, b|
        lines << (b.nil? ? "  #{display_name(a)}  (bye)" : "  #{display_name(a)}  vs  #{display_name(b)}")
      end

      lines << ''
      lines << '--- Finished fights ---'
      if @results_log.empty?
        lines << '  (none yet)'
      else
        @results_log.group_by { |e| e[:round] }.sort.each do |r, events|
          lines << "Round #{r}:"
          events.each { |e| lines << format_result_line(e) }
          lines << ''
        end
      end

      lines << '--- This round schedule ---'
      @matches.each_with_index do |(a, b), i|
        tag =
          if i < @match_index
            '[ done ]'
          elsif i == @match_index
            '[ next ]'
          else
            '[ wait ]'
          end
        lines << (b.nil? ? "  #{tag}  #{display_name(a)}  (bye)" : "  #{tag}  #{display_name(a)}  vs  #{display_name(b)}")
      end

      trim(lines, max_lines)
    end

    # Next fight: [Class, Class] or [Class, nil] for a bye, or nil if tournament finished.
    def current_matchup
      return nil if finished?

      @matches[@match_index]
    end

    # Winner must be one of the two entrants (or the sole entrant on a bye).
    def record_match_winner(winner_class)
      raise ArgumentError, 'tournament already complete' if finished?

      a, b = @matches[@match_index]
      if b.nil?
        raise ArgumentError, 'bye winner mismatch' unless winner_class == a

        log_match(a, b, :bye, a)
        @round_winners << a
      else
        unless winner_class == a || winner_class == b
          raise ArgumentError, 'winner not in this match'
        end

        log_match(a, b, winner_class == a ? :left : :right, winner_class)
        @round_winners << winner_class
      end

      @match_index += 1
      advance_round_if_needed
    end

    # Timed draw / stalemate: neither bot advances (not valid for a bye).
    def record_match_draw
      raise ArgumentError, 'tournament already complete' if finished?

      a, b = @matches[@match_index]
      raise ArgumentError, 'bye matches cannot draw' if b.nil?

      log_match(a, b, :draw, nil)
      @match_index += 1
      advance_round_if_needed
    end

    def self.pair(entrants, rng: Random.new)
      s = entrants.shuffle(random: rng)
      out = []
      i = 0
      while i < s.size
        out << if i + 1 < s.size
                 [s[i], s[i + 1]]
               else
                 [s[i], nil]
               end
        i += 2
      end
      out
    end

    private

    def log_match(a, b, outcome, winner_class)
      @results_log << {
        round: @round_number,
        a: a,
        b: b,
        outcome: outcome,
        winner: winner_class
      }
    end

    def format_result_line(e)
      a = e[:a]
      b = e[:b]
      case e[:outcome]
      when :bye
        "  #{display_name(a)} advances (bye)"
      when :draw
        "  #{display_name(a)} vs #{display_name(b)} - draw (no advance)"
      when :left
        "  #{display_name(a)} def. #{display_name(b)}"
      when :right
        "  #{display_name(b)} def. #{display_name(a)}"
      else
        '  (unknown result)'
      end
    end

    def trim(lines, max)
      return lines if lines.size <= max

      lines[0, max - 1] + ['  …']
    end

    def advance_round_if_needed
      return if @match_index < @matches.size

      if @round_winners.size == 1
        # Only the final pairing (one match in the round) produces a champion.
        if @matches.size == 1
          @champion = @round_winners.first
          return
        end

        @round_bracket_flag = true
        @entrants = @round_winners.dup
        @round_winners = []
        @matches = self.class.pair(@entrants, rng: @rng)
        @match_index = 0
        @round_number += 1
        return
      end

      if @round_winners.empty?
        @void_tournament = true
        return
      end

      @round_bracket_flag = true
      @entrants = @round_winners.dup.shuffle(random: @rng)
      @round_winners = []
      @matches = self.class.pair(@entrants, rng: @rng)
      @match_index = 0
      @round_number += 1
    end
  end
end
