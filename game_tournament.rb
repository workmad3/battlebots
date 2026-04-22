lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'gosu'
require 'players'
require 'tournament_window'

BattleBots::TournamentWindow.new.show
