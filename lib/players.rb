require 'proxy'
require 'bots/bot'

module BattleBots
  module Players
    def self.register_bot(bot) = bot_classes << bot
    def self.bot_classes = @bot_classes ||= []

    def bot_classes = BattleBots::Players.bot_classes

    def player_list
      bot_classes.shuffle.map { |klass| Proxy.new(self, klass) }
    end
  end
end

Dir["#{File.dirname(__FILE__)}/bots/*.rb"].each { |bot| require bot }
