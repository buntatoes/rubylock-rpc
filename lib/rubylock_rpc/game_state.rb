# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "set"
require_relative "config"

module RubylockRpc
  module MatchMode
    UNKNOWN        = :unknown
    STANDARD       = :standard
    RANKED         = :ranked
    STREET_BRAWL   = :street_brawl
    BOT_MATCH      = :bot_match
    TRAINING_RANGE = :training_range
    HERO_LABS      = :hero_labs

    DISPLAY_NAMES = {
      UNKNOWN        => "In Match",
      STANDARD       => "Standard Match",
      RANKED         => "Ranked Match",
      STREET_BRAWL   => "Street Brawl",
      BOT_MATCH      => "Bot Match",
      TRAINING_RANGE => "Training Range",
      HERO_LABS      => "Hero Labs"
    }.freeze

    MAP_LOCATION_MODES = [STANDARD, RANKED, STREET_BRAWL, UNKNOWN].freeze

    module_function

    def display(mode)
      DISPLAY_NAMES.fetch(mode, "In Match")
    end

    def show_map_location?(mode)
      MAP_LOCATION_MODES.include?(mode)
    end
  end

  module GamePhase
    NOT_RUNNING = :not_running
    MAIN_MENU   = :main_menu
    HIDEOUT     = :hideout
    IN_QUEUE    = :in_queue
    MATCH_INTRO = :match_intro
    IN_MATCH    = :in_match
    POST_MATCH  = :post_match
    SPECTATING  = :spectating

    NON_HERO_PHASES = [NOT_RUNNING, MAIN_MENU, POST_MATCH, SPECTATING].freeze

    module_function

    def shows_hero?(phase)
      !NON_HERO_PHASES.include?(phase)
    end
  end

  class GameState
    attr_accessor :phase, :match_mode, :hero_key, :map_name, :party_size, :match_started_at,
                  :hero_window_open, :hideout_loaded, :local_account_id, :party_id,
                  :party_members, :party_unknown_members, :pending_player_count

    def self.format_match_elapsed(seconds)
      total = seconds.to_i
      hours = total / 3600
      mins  = (total % 3600) / 60
      secs  = total % 60
      if hours.positive?
        format("%d:%02d:%02d", hours, mins, secs)
      else
        format("%02d:%02d", mins, secs)
      end
    end

    def self.hideout_line(hideout_text, hero_name, status_cfg)
      if hideout_text && !hideout_text.empty?
        hideout_text.to_s
      else
        ConfigManager.apply_vars(status_cfg.in_hideout, hero: hero_name.to_s)
      end
    end

    def initialize
      reset
    end

    def reset
      @phase = GamePhase::NOT_RUNNING
      @match_mode = MatchMode::UNKNOWN
      @hero_key = nil
      @map_name = nil
      @party_size = 1
      @match_started_at = nil
      @hero_window_open = true
      @hideout_loaded = false
      @local_account_id = nil
      @party_id = nil
      @party_members = Set.new
      @party_unknown_members = 0
      @pending_player_count = 0
      self
    end

    def enter_hideout
      @phase = GamePhase::HIDEOUT
      @match_started_at = nil
      @hero_key = nil
      @hero_window_open = true
      @hideout_loaded = false
    end

    def enter_main_menu
      @phase = GamePhase::MAIN_MENU
      @match_started_at = nil
    end

    def enter_queue
      @phase = GamePhase::IN_QUEUE
      @match_started_at = nil
    end

    def leave_queue
      @phase = GamePhase::HIDEOUT
    end

    def enter_match_intro
      @phase = GamePhase::MATCH_INTRO
      @match_started_at = nil
      @match_mode = MatchMode::UNKNOWN
      @hero_key = nil
      @hero_window_open = true
      @pending_player_count = 0
    end

    def start_match(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      if @phase != GamePhase::IN_MATCH || @match_started_at.nil?
        @match_started_at = now
      end
      @phase = GamePhase::IN_MATCH
    end

    def end_match
      @phase = GamePhase::POST_MATCH
      @match_started_at = nil
    end

    def enter_spectating
      @phase = GamePhase::SPECTATING
      @match_started_at = nil
    end

    def match_elapsed(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return nil unless @phase == GamePhase::IN_MATCH && @match_started_at

      [now - @match_started_at, 0.0].max
    end

    def prepare_match_hero_tracking
      @hero_key = nil
      @hero_window_open = true
    end

    def clear_party
      @party_id = nil
      @party_members.clear
      @party_unknown_members = 0
      @party_size = 1
    end

    def apply_hideout_player_count(count)
      clamped = [count.to_i, 6].min
      @party_unknown_members = [clamped - @party_members.size, 0].max
      recompute_party_size
    end

    def apply_party_event(party_id, event_name, account_id)
      ev = event_name.to_s.downcase
      local = @local_account_id

      if ev.include?("joinedparty")
        if local && account_id == local
          @party_id = party_id
          @party_members = Set[account_id]
          @party_unknown_members = 1
        else
          if @party_id != party_id
            @party_id = party_id
            @party_members.clear
            @party_unknown_members = 0
            @party_members.add(local) if local
          end
          @party_members.add(account_id)
        end
        recompute_party_size
      elsif ev.include?("leftparty") || ev.include?("removedfromparty") || ev.include?("kickedfromparty")
        if local && account_id == local
          clear_party
        else
          unless @party_members.delete?(account_id)
            @party_unknown_members = [@party_unknown_members - 1, 0].max
          end
          recompute_party_size
        end
      elsif ev.include?("disband")
        clear_party
      end
    end

    def apply_hero_signal(new_hero_key)
      return if @phase == GamePhase::SPECTATING

      case @phase
      when GamePhase::MATCH_INTRO, GamePhase::IN_MATCH
        free_swap = [MatchMode::TRAINING_RANGE, MatchMode::HERO_LABS].include?(@match_mode)
        unless free_swap
          if @hero_key
            return if new_hero_key != @hero_key
          elsif !@hero_window_open
            return
          end
        end
        @hero_key = new_hero_key.to_s
        @hero_window_open = false
      when GamePhase::HIDEOUT
        @hero_key = new_hero_key.to_s
      when GamePhase::MAIN_MENU, GamePhase::POST_MATCH
        # Do not override hero in main menu or post match
      else
        @hero_key = new_hero_key.to_s
      end
    end

    def presence_status(hideout_text, hero_name, timer, status_cfg)
      case @phase
      when GamePhase::NOT_RUNNING
        status_cfg.game_not_running
      when GamePhase::MAIN_MENU
        status_cfg.in_main_menu
      when GamePhase::HIDEOUT
        self.class.hideout_line(hideout_text, hero_name, status_cfg)
      when GamePhase::IN_QUEUE
        status_cfg.in_matchmaking
      when GamePhase::MATCH_INTRO
        if @match_mode == MatchMode::UNKNOWN
          ConfigManager.apply_vars(status_cfg.loading_into_match, mode: "")
                       .gsub(/\A[\s-]+|[\s-]+\z/, "")
        else
          ConfigManager.apply_vars(status_cfg.loading_into_match, mode: MatchMode.display(@match_mode))
        end
      when GamePhase::IN_MATCH
        mode_str = MatchMode.display(@match_mode)
        uses_template = MatchMode.show_map_location?(@match_mode)
        status = if uses_template
                   ConfigManager.apply_vars(
                     status_cfg.in_match,
                     mode: mode_str,
                     location: status_cfg.match_location_label,
                     timer: timer.to_s
                   )
                 else
                   mode_str
                 end
        placed = uses_template && status_cfg.in_match.include?("{timer}")
        if timer && !timer.empty? && !placed
          status = "#{status} - #{timer}"
        end
        status
      when GamePhase::POST_MATCH
        status_cfg.post_match
      when GamePhase::SPECTATING
        status_cfg.spectating
      else
        status_cfg.game_not_running
      end
    end

    private

    def recompute_party_size
      known = [@party_members.size, 6].min
      @party_size = (known + @party_unknown_members).clamp(1, 6)
    end
  end
end
