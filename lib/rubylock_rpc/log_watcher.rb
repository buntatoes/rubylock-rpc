# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "game_state"
require_relative "logger"

module RubylockRpc
  class LogWatcher
    HIDEOUT_MAPS = ["dl_hideout"].freeze
    RESYNC_BYTES = 10 * 1024 * 1024
    MATCH_STALE_SECS = 300

    PATTERNS = {
      map_info: /\[Client\] Map:\s+"([^"]+)"/,
      map_created_physics: /\[Client\] Created physics for\s+([^\s]+)/,
      host_activate: /\[HostStateManager\] Host activate:.*\(([^)]+)\)/,
      loop_mode_menu: /LoopMode:\s*menu/,
      change_game_state: /ChangeGameState:\s+(\w+)\s+\((\d+)\)/,
      precaching_heroes: /Precaching (\d+) heroes in CCitadelGameRules/,
      lobby_created: /Lobby\s+\d+\s+for\s+Match\s+\d+\s+created/,
      lobby_destroyed: /Lobby\s+\d+\s+for\s+Match\s+\d+\s+destroyed/,
      spectate_broadcast: /Playing Broadcast/,
      server_connect: /\[Client\] CL:\s+Connected to '([^']+)'/,
      server_disconnect: /\[Client\] Disconnecting from server:\s+(\S+)/,
      server_shutdown: /\[Server\] SV:\s+Server shutting down:\s+(\S+)/,
      loaded_hero: /\[Server\] Loaded hero \d+\/(hero_\w+)/,
      client_hero_vmdl: /VMDL Camera Pose Success!.*models\/heroes(?:_wip|_staging)?\/(\w+)\//,
      player_info: /\[Client\] Players:\s+(\d+)\s+\(\d+ bots\)\s+\/\s+\d+ humans/,
      bot_init: /Initializing bot for player slot \d+:\s+k_ECitadelBotDifficulty_\w+/,
      hideout_lobby_state: /\[Hideout\] Hideout Lobby Connection State:\s+(\w+)\s+\((-?\d+)\)/,
      party_event: /CMsgGCToClientPartyEvent:\s+\{\s*party_id:\s+(\d+)\s+event:\s+(k_e\w+)\s+initiator_account_id:\s+(\d+)\s*\}/,
      local_account_id: /\[U:1:(\d+)\]/
    }.freeze

    def self.normalize_hero_key(raw)
      s = raw.to_s.downcase
      if (pos = s.rindex("_"))
        suffix = s[(pos + 1)..]
        if suffix.start_with?("v") && suffix.length > 1 && suffix[1..].match?(/\A\d+\z/)
          s = s[0...pos]
        end
      end
      s.start_with?("hero_") ? s : "hero_#{s}"
    end

    def self.try_infer_mode(state)
      return if state.match_mode != MatchMode::UNKNOWN || state.pending_player_count.zero?
      return unless state.map_name == "dl_midtown"

      if state.pending_player_count >= 9
        state.match_mode = MatchMode::STANDARD
      elsif state.pending_player_count >= 4
        state.match_mode = MatchMode::STREET_BRAWL
      else
        return
      end
      RpcLogger.info("[mode] inferred #{state.match_mode} from dl_midtown + #{state.pending_player_count} players")
    end

    def self.apply_map(state, map_name)
      return if state.phase == GamePhase::SPECTATING

      map_lower = map_name.to_s.downcase
      return if map_lower.empty? || map_lower == "<empty>"

      if HIDEOUT_MAPS.include?(map_lower)
        state.enter_hideout
        state.map_name = map_lower
        return
      end

      state.map_name = map_lower
      state.match_mode = MatchMode::UNKNOWN

      case map_lower
      when "new_player_basics"
        state.match_mode = MatchMode::TRAINING_RANGE
      when "street_test", "street_test_bridge"
        state.match_mode = MatchMode::STANDARD
      end

      if [
        GamePhase::MATCH_INTRO,
        GamePhase::IN_QUEUE,
        GamePhase::MAIN_MENU,
        GamePhase::HIDEOUT,
        GamePhase::IN_MATCH,
        GamePhase::POST_MATCH
      ].include?(state.phase)
        state.phase = GamePhase::IN_MATCH
        state.prepare_match_hero_tracking
        state.hideout_loaded = false
        try_infer_mode(state)
      end
    end

    def self.process_line(line, state)
      if state.local_account_id.nil? && (m = PATTERNS[:local_account_id].match(line))
        id = m[1].to_i
        state.local_account_id = id if id.positive?
      end

      if (m = PATTERNS[:party_event].match(line))
        state.apply_party_event(m[1].to_i, m[2], m[3].to_i)
      end

      is_hideout_map = HIDEOUT_MAPS.include?(state.map_name)

      if (m = PATTERNS[:map_created_physics].match(line))
        apply_map(state, m[1])
      elsif (m = PATTERNS[:map_info].match(line)) && m[1] != "start"
        apply_map(state, m[1])
      elsif line.include?("k_EMsgClientToGCStartMatchmaking")
        state.enter_queue if [GamePhase::HIDEOUT, GamePhase::MAIN_MENU].include?(state.phase)
      elsif line.include?("k_EMsgClientToGCStopMatchmaking")
        state.leave_queue if state.phase == GamePhase::IN_QUEUE
      elsif PATTERNS[:lobby_created].match?(line)
        state.prepare_match_hero_tracking
        if [GamePhase::MAIN_MENU, GamePhase::HIDEOUT, GamePhase::IN_QUEUE, GamePhase::MATCH_INTRO].include?(state.phase)
          state.enter_match_intro
        end
      elsif PATTERNS[:lobby_destroyed].match?(line)
        state.end_match
      elsif PATTERNS[:spectate_broadcast].match?(line)
        state.enter_spectating
        state.hideout_loaded = false
      elsif (m = PATTERNS[:server_connect].match(line))
        addr = m[1].downcase
        unless addr.include?("loopback")
          state.prepare_match_hero_tracking
          if [GamePhase::MAIN_MENU, GamePhase::HIDEOUT, GamePhase::IN_QUEUE, GamePhase::MATCH_INTRO].include?(state.phase)
            state.enter_match_intro
          end
        end
      elsif (m = PATTERNS[:loaded_hero].match(line))
        hero = normalize_hero_key(m[1])
        if state.phase != GamePhase::HIDEOUT || state.hideout_loaded
          state.apply_hero_signal(hero)
        end
      elsif (m = PATTERNS[:client_hero_vmdl].match(line))
        state.apply_hero_signal(normalize_hero_key(m[1]))
      elsif (m = PATTERNS[:server_disconnect].match(line))
        reason = m[1].upcase
        if reason.include?("EXITING")
          state.reset
        elsif !reason.include?("LOOPDEACTIVATE") &&
              [GamePhase::IN_MATCH, GamePhase::MATCH_INTRO, GamePhase::SPECTATING].include?(state.phase)
          state.end_match
        end
      elsif PATTERNS[:loop_mode_menu].match?(line)
        if [GamePhase::IN_MATCH, GamePhase::MATCH_INTRO, GamePhase::SPECTATING].include?(state.phase)
          state.end_match
        end
      elsif (m = PATTERNS[:change_game_state].match(line))
        name = m[1].downcase
        id = m[2].to_i
        if state.phase != GamePhase::SPECTATING && !is_hideout_map && !state.hideout_loaded
          if name == "matchintro" || id == 4
            state.enter_match_intro
          elsif name == "gameinprogress" || name == "inprogress" || id == 7
            state.start_match
          elsif name == "postgame" || id == 6
            state.end_match
          end
        end
      elsif (m = PATTERNS[:hideout_lobby_state].match(line))
        lobby_id = m[2].to_i
        state.clear_party if lobby_id.zero? && state.phase == GamePhase::HIDEOUT
      elsif (m = PATTERNS[:host_activate].match(line))
        map = m[1].downcase
        state.hideout_loaded = true if HIDEOUT_MAPS.include?(map)
      elsif (m = PATTERNS[:server_shutdown].match(line))
        state.reset if m[1].upcase.include?("EXITING")
      elsif line.include?("Dispatching EventAppShutdown_t") || line.include?("Source2Shutdown")
        state.reset
      elsif (m = PATTERNS[:precaching_heroes].match(line))
        state.hideout_loaded = false if m[1].to_i.positive?
      elsif (m = PATTERNS[:player_info].match(line))
        count = m[1].to_i
        if state.phase == GamePhase::HIDEOUT && is_hideout_map && count.positive?
          state.apply_hideout_player_count(count)
        elsif [GamePhase::MATCH_INTRO, GamePhase::IN_MATCH].include?(state.phase)
          state.pending_player_count = [state.pending_player_count, count].max if count.positive?
          try_infer_mode(state) if state.phase == GamePhase::IN_MATCH
        end
      elsif PATTERNS[:bot_init].match?(line)
        if [GamePhase::MATCH_INTRO, GamePhase::IN_MATCH].include?(state.phase) &&
           state.match_mode == MatchMode::UNKNOWN
          state.match_mode = MatchMode::BOT_MATCH
        end
      end
    end

    def initialize(log_path, poll_interval_ms)
      @log_path = log_path
      @poll_interval_s = [poll_interval_ms.to_f / 1000.0, 0.05].max
    end

    def run(state, mutex)
      last_pos = 0
      initialized = false
      last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      logged_waiting = false
      session_start = nil

      loop do
        unless File.exist?(@log_path)
          if initialized
            elapsed = session_start ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - session_start).to_i : 0
            RpcLogger.info("[watcher] Game session ended after #{elapsed / 60}m #{elapsed % 60}s - resetting state")
            mutex.synchronize { state.reset }
            initialized = false
            last_pos = 0
            logged_waiting = false
            session_start = nil
          elsif !logged_waiting
            RpcLogger.info("[watcher] Waiting for Deadlock log at: #{@log_path}")
            logged_waiting = true
          end
          sleep(2)
          next
        end

        file_size = File.size(@log_path) rescue 0

        unless initialized
          RpcLogger.info("[watcher] Found console.log - reading game state")
          session_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          start_offset = [file_size - RESYNC_BYTES, 0].max
          lines = read_lines_from(@log_path, start_offset, start_offset.positive?)
          mutex.synchronize do
            state.enter_main_menu
            lines.each { |line| self.class.process_line(line.strip, state) }
            RpcLogger.info(
              "[resync] phase=#{state.phase} map=#{state.map_name.inspect} " \
              "mode=#{state.match_mode} hero=#{state.hero_key.inspect} party=#{state.party_size} (#{lines.size} lines)"
            )
          end
          last_pos = file_size
          last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          initialized = true
          next
        end

        if file_size < last_pos
          RpcLogger.warn("[watcher] Log truncated, resyncing...")
          initialized = false
          last_pos = 0
          next
        end

        if file_size > last_pos
          last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          lines = read_lines_from(@log_path, last_pos, false)
          unless lines.empty?
            mutex.synchronize do
              prev_phase = state.phase
              prev_hero  = state.hero_key
              prev_party = state.party_size
              lines.each do |line|
                trimmed = line.strip
                self.class.process_line(trimmed, state) unless trimmed.empty?
              end
              RpcLogger.info("[state] #{prev_phase} -> #{state.phase}") if state.phase != prev_phase
              RpcLogger.info("[hero]  #{prev_hero.inspect} -> #{state.hero_key.inspect}") if state.hero_key != prev_hero
              RpcLogger.info("[party] #{prev_party} -> #{state.party_size}") if state.party_size != prev_party
            end
          end
          last_pos = file_size
        else
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          in_active = mutex.synchronize { [GamePhase::IN_MATCH, GamePhase::MATCH_INTRO].include?(state.phase) }
          if in_active && (now - last_activity) > MATCH_STALE_SECS
            RpcLogger.warn("[watcher] No log activity for #{MATCH_STALE_SECS}s during active match - assuming crash")
            mutex.synchronize { state.reset }
            initialized = false
            last_pos = 0
            last_activity = now
            session_start = nil
          end
        end

        sleep(@poll_interval_s)
      end
    end

    private

    def read_lines_from(path, offset, skip_partial)
      File.open(path, "rb") do |f|
        f.seek(offset, IO::SEEK_SET)
        raw = f.read.to_s
        text = raw.encode("UTF-8", invalid: :replace, undef: :replace)
        lines = text.lines.map(&:chomp)
        lines.shift if skip_partial && !lines.empty?
        lines
      end
    rescue StandardError
      []
    end
  end
end
