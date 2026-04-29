require 'bots/bot'

# Loiters near centre; random insult rotation + pot-shots when something’s in arc.
class Heckler < BattleBots::Bots::Bot
  def self.bot_source = :ai

  BORDER = 80
  ORBIT_RADIUS = 96

  # Game ticks per insult (~180 ≈ 3s at 60fps before the bubble advances).
  INSULT_ROTATION_TICKS = 180

  # When in range band: pull trigger this often (ammo still caps real rate at ~1 shot / 50 ticks).
  SHOOT_CHANCE = 0.92

  # Slightly wider than Bot#aim_turret’s 400px so orbit fights actually shoot.
  SHOOT_DISTANCE_MAX = 455

  module InsultEngine
    module_function

    # Base bag — always eligible. When a nearest rival is visible, we append INSULTS_WITH_DIST (px) so
    # distance lines appear sprinkled in (~1 in 6 if ~40 static + ~10 dist).
    INSULTS = [
      'You move like buffering.',
      'Built like a placeholder.',
      'Aim assist couldn’t save that.',
      'You shoot in suggestions.',
      'Zero damage, full delusion.',
      'You’re the practice dummy with a bow tie.',
      'Loadout: regret.',
      'Stat sheet looks like an apology.',
      'Net result: vibes, no impact.',
      'You strafe like a Roomba in denial.',
      'Reload speed: tectonic.',
      'Couldn’t hit the broad side of your own ego.',
      'You haven’t earned a healthbar.',
      'Skill issue — chronic.',
      'You play like the demo of a worse game.',
      'Bot, please. You’re bait.',
      'Threat level: unread email.',
      'Fight you? I’m doing physio for laughing.',
      'Wrong pixel, wrong hour, wrong life.',
      'You miss like it’s a personality trait.',
      'I’ve seen target practice with more dignity.',
      'You’re a cardboard target with extra bugs.',
      'You couldn’t carry a 1v0.',
      'I forget you mid-sentence.',
      'You’re the participation trophy of tanks.',
      'Got the courage of a screensaver.',
      'You queue for fights and still no-show.',
      'Your turret moves like a rumour.',
      'Built in a tutorial. Still failed it.',
      'Volume up, threat down.',
      'You shoot pep talks at the wall.',
      'I’ve been more scared by a cough.',
      'Your aim cone is just regret.',
      'You tank in the marketing sense.',
      'Cute build. Tragic outcome.',
      'You whiff with conviction.',
      'You orbit competence.',
      'You missed me — I was right here, pal.'
    ].freeze

    INSULTS_WITH_DIST = [
      '%{d_round}px and still scared.',
      '%{d_round}px — closer than your aim ever gets.',
      '%{d_round}px between us. Still feels like a no-show.',
      'I can read your nameplate at %{d_round}px and I’m unimpressed.',
      '%{d_round}px and you’re the one breathing hard.',
      '%{d_round}px out — that’s emailing distance, coward.',
      '%{d_round}px and you’re still the worst angle on the map.',
      '%{d_round}px? Bold of you to be seen.',
      '%{d_round}px and somehow already losing.',
      'You parked %{d_round}px away to think — bad call.',
      '%{d_round}px — please rotate, please rethink.',
      '%{d_round}px and not one of them earns you a hit.'
    ].freeze

    def pick_line(bot, rng)
      contacts = bot.instance_variable_get(:@contacts)
      contacts = [] if contacts.nil?

      dist_lines = []
      if contacts.any?
        px = bot.instance_variable_get(:@x).to_f
        py = bot.instance_variable_get(:@y).to_f
        nearest = contacts.min_by { |c| Math.hypot(c[:x].to_f - px, c[:y].to_f - py) }
        _b, d = bot.send(:calculate_vector_to, nearest)
        dr = d.round
        dist_lines = INSULTS_WITH_DIST.map { |t| format(t, d_round: dr) }
      end

      (INSULTS + dist_lines).sample(random: rng)
    end
  end

  def initialize
    @name = "Josh's Heckler"
    # Heavier punch & wider arc (sight) — shave stamina slightly.
    @strength, @speed, @stamina, @sight = [12, 19, 58, 11]
    @bubble_tick = 0
    @insult_slot_persist = -1
    @insult_line_cache = InsultEngine::INSULTS.sample
  end

  def think
    @bubble_tick += 1

    cx = @arena_width * 0.5
    cy = @arena_height * 0.5
    t = @bubble_tick * 0.017
    wobble_x = Math.sin(t * 2.05) * 28
    wobble_y = Math.cos(t * 1.62) * 20
    tx = cx + Math.cos(t) * ORBIT_RADIUS + wobble_x
    ty = cy + Math.sin(t * 0.92) * ORBIT_RADIUS * 0.82 + wobble_y

    drive_toward(tx, ty, stop_within: 42)

    enemy = select_target
    if enemy
      bearing, distance = calculate_vector_to(enemy)
      aim_turret(bearing, distance)
      # Override aim_turret’s hard 400px gate — bit more reach + high willingness to fire.
      @shoot = distance < SHOOT_DISTANCE_MAX && rand < SHOOT_CHANCE
    else
      @aim = (@bubble_tick % 90 < 45) ? 1 : -1
      @shoot = false
    end

    stay_clear_of_walls
  end

  def speech_bubble_line
    slot = @bubble_tick / INSULT_ROTATION_TICKS
    if slot != @insult_slot_persist
      @insult_slot_persist = slot
      seed = slot * 982_451 ^ (@bubble_tick & 0xfff)
      rng = Random.new(seed)
      @insult_line_cache = InsultEngine.pick_line(self, rng)
    end
    @insult_line_cache
  end

  private

  def drive_toward(tx, ty, stop_within:)
    bearing, distance = calculate_vector_to({ x: tx, y: ty })
    if distance > stop_within
      @turn = (@heading - bearing) % 360 > 180 ? 1 : -1
      @drive = 1
    else
      @turn = 0
      @drive = 0
    end
  end

  def play_min_x
    @arena_margin.to_f
  end

  def play_max_x
    @arena_width.to_f - @arena_margin.to_f
  end

  def play_min_y
    @arena_margin.to_f
  end

  def play_max_y
    @arena_height.to_f - @arena_margin.to_f
  end

  def stay_clear_of_walls
    turn_right = 3
    turn_left = -3
    bearing = @heading % 360
    right = play_max_x
    left = play_min_x
    bottom = play_max_y
    top = play_min_y

    if @x > (right - BORDER) && east?(bearing) && north?(bearing)
      @turn = turn_left
    elsif @x > (right - BORDER) && east?(bearing) && south?(bearing)
      @turn = turn_right
    elsif @x < (left + BORDER) && west?(bearing) && north?(bearing)
      @turn = turn_right
    elsif @x < (left + BORDER) && west?(bearing) && south?(bearing)
      @turn = turn_left
    elsif @y > (bottom - BORDER) && south?(bearing) && east?(bearing)
      @turn = turn_left
    elsif @y > (bottom - BORDER) && south?(bearing) && west?(bearing)
      @turn = turn_right
    elsif @y < (top + BORDER) && north?(bearing) && east?(bearing)
      @turn = turn_right
    elsif @y < (top + BORDER) && north?(bearing) && west?(bearing)
      @turn = turn_left
    end
  end

  def east?(b)
    b >= 0 && b <= 180
  end

  def south?(b)
    b >= 90 && b <= 270
  end

  def west?(b)
    b >= 180 && b <= 360
  end

  def north?(b)
    (b >= 0 && b <= 90) || (b >= 270 && b <= 360)
  end
end

unless BattleBots::Proxy.instance_methods(false).include?(:draw_without_speech_bubble__heckler)
  BattleBots::Proxy.class_eval do
    alias_method :draw_without_speech_bubble__heckler, :draw

    def draw
      draw_without_speech_bubble__heckler
      return unless @health.to_f > 0
      return unless @bot.respond_to?(:speech_bubble_line)

      line = @bot.speech_bubble_line
      return if line.nil? || (s = line.to_s.strip).empty?

      scale = 0.962 # ~0.74 × 1.3 — text size
      pad_x = 16    # ~12 × 1.3 — bubble padding
      pad_y = 9     # ~7 × 1.3
      tw = @font.text_width(s) * scale + pad_x * 2
      th = @font.height * scale + pad_y * 2
      left = @x - (tw / 2.0)
      top = @y - 57 - th # ~44 × 1.3 — clearance above hull
      z = 3
      c_fill = 0xff_fffcf5
      c_edge = 0xff_2a2a2a
      c_text = 0xff_1a1a1a

      Gosu.draw_rect(left - 4, top - 4, tw + 8, th + 8, c_edge, z)
      Gosu.draw_rect(left, top, tw, th, c_fill, z + 1)
      @font.draw_text(s, left + pad_x, top + pad_y, z + 2, scale, scale, c_text)

      y_base = top + th
      Gosu.draw_triangle(
        @x - 9, y_base, c_fill,
        @x + 9, y_base, c_fill,
        @x, y_base + 18, c_fill,
        z + 1
      )
    end
  end
end
