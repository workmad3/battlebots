module BattleBots
  # When a 1v1 hits the clock with both bots alive: best health wins unless both are still full.
  module TournamentHealthTimeout
    STARTING_HEALTH = 100.0
    FULL_HEALTH_EPS = 1e-3

    module_function

    # Returns :draw (no bracket winner), :first, or :second for players[0] / players[1].
    def outcome(health_a, health_b, rng: Random.new)
      full = ->(h) { h >= STARTING_HEALTH - FULL_HEALTH_EPS }

      return :draw if full.call(health_a) && full.call(health_b)
      return :first if health_a > health_b
      return :second if health_b > health_a

      rng.rand(2).zero? ? :first : :second
    end
  end
end
