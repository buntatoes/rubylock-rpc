# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "socket"
require_relative "deadlock_rpc/logger"
require_relative "deadlock_rpc/toml"
require_relative "deadlock_rpc/config"
require_relative "deadlock_rpc/game_state"
require_relative "deadlock_rpc/log_watcher"
require_relative "deadlock_rpc/hero_api"
require_relative "deadlock_rpc/discord_ipc"
require_relative "deadlock_rpc/steam"
require_relative "deadlock_rpc/process_watcher"
require_relative "deadlock_rpc/launcher"

module DeadlockRpc
  VERSION = "1.0.1"
  DISCORD_APP_ID = "1566683259763429509"
  SINGLE_INSTANCE_PORT = 47_782
  MIN_TIMER_REFRESH_SECS = 5

  class Application
    def self.try_acquire_single_instance_lock
      TCPServer.new("127.0.0.1", SINGLE_INSTANCE_PORT)
    rescue StandardError
      nil
    end

    def initialize(argv = ARGV)
      @argv = argv.dup
    end

    def run
      flags, game_command = split_args(@argv)

      if flags.include?("--version") || flags.include?("-v")
        puts "deadlock-rpc-ruby v#{VERSION}"
        return 0
      end

      if flags.include?("--help") || flags.include?("-h")
        print_help
        return 0
      end

      if flags.include?("--generate-config")
        File.write(ConfigManager.config_path, ConfigManager::DEFAULT_TOML)
        puts "Wrote default config.toml"
        return 0
      end

      RpcLogger.init
      cfg = ConfigManager.load
      RpcLogger.info("[config] Loaded from config.toml")
      shared = SharedBools.new(cfg)

      instance_lock = self.class.try_acquire_single_instance_lock
      no_launch = flags.include?("--no-launch")

      launch_mode = if flags.include?("--launch-with-command")
                      if game_command.empty?
                        RpcLogger.warn("[deadlock-rpc] --launch-with-command needs a command after --, e.g. -- %command%. Exiting.")
                        return 1
                      end
                      [:command, game_command]
                    elsif no_launch || !cfg.general.launch_game_on_start
                      [:none, nil]
                    else
                      [:steam, nil]
                    end

      if instance_lock.nil?
        if launch_mode[0] == :command
          RpcLogger.info("[deadlock-rpc] Another instance is running. Launching the game and waiting for it to exit.")
          pid = Launcher.launch_deadlock_with_command(launch_mode[1])
          Process.wait(pid) if pid
        elsif !no_launch
          RpcLogger.info("[deadlock-rpc] Another instance is running - re-triggering launch.")
          Launcher.launch_deadlock
        else
          RpcLogger.info("[deadlock-rpc] Another instance is already running. Exiting.")
        end
        return 0
      end

      case launch_mode[0]
      when :steam
        Launcher.launch_deadlock
      when :command
        Launcher.launch_deadlock_with_command(launch_mode[1])
      end

      log_path = Steam.find_console_log(cfg.general.game_folder)
      RpcLogger.info("[deadlock-rpc] Monitoring: #{log_path}")

      state = GameState.new
      mutex = Mutex.new

      Thread.new { LogWatcher.new(log_path, cfg.general.game_log_poll_interval_ms).run(state, mutex) }
      Thread.new { ProcessWatcher.run(state, mutex) }

      run_rpc_loop(state, mutex, cfg, shared)
    ensure
      instance_lock&.close rescue nil
    end

    private

    def split_args(argv)
      if (idx = argv.index("--"))
        [argv[0...idx], argv[(idx + 1)..] || []]
      else
        [argv, []]
      end
    end

    def print_help
      puts <<~HELP
        Deadlock Rich Presence for Discord (Ruby Edition v#{VERSION}, GPL-3.0)
        Usage: deadlock-rpc [OPTIONS] [-- <game command>]

        Options:
          --no-launch                    Skip launching Deadlock on startup
          --no-shortcut                  Skip shortcut installation prompt
          --launch-with-command -- <cmd> Launch game command with -condebug appended
          --generate-config              Write default config.toml and exit
          -v, --version                  Show version
          -h, --help                     Show this help message
      HELP
    end

    def connect_discord
      client = DiscordIpcClient.new(DISCORD_APP_ID)
      loop do
        client.connect
        RpcLogger.info("[discord] Connected!")
        return client
      rescue StandardError => e
        RpcLogger.warn("[discord] Connect failed: #{e.message}. Make sure Discord is open. Retrying in 10s...")
        sleep(10)
      end
    end

    def run_rpc_loop(state, mutex, cfg, shared)
      RpcLogger.info("[discord] Connecting...")
      client = connect_discord
      current_portrait = cfg.presence.hero_portrait_style
      hero_cache = HeroCache.new(current_portrait)
      last_state = nil
      game_was_running = false
      rpc_start_time = Time.now.to_i

      update_interval = [cfg.general.discord_update_interval_s.to_i, 1].max
      timer_refresh_secs = [update_interval, MIN_TIMER_REFRESH_SECS].max

      trap("INT")  { client.clear_activity; client.close; exit(0) }
      trap("TERM") { client.clear_activity; client.close; exit(0) }

      loop do
        phase, match_mode, hero_key, party_size, map_name, account_id, timer_text, timer_bucket =
          mutex.synchronize do
            elapsed = shared.show_match_timer ? state.match_elapsed : nil
            bucket = elapsed ? (elapsed.to_i / timer_refresh_secs) : nil
            t_text = elapsed ? GameState.format_match_elapsed(elapsed) : nil
            [
              state.phase,
              state.match_mode,
              state.hero_key,
              state.party_size,
              state.map_name,
              state.local_account_id,
              t_text,
              bucket
            ]
          end

        if phase != GamePhase::NOT_RUNNING
          game_was_running = true
        elsif game_was_running
          RpcLogger.info("[deadlock-rpc] Game closed.")
          if shared.exit_when_game_closes
            client.clear_activity
            client.close
            exit(0)
          end
        end

        current = [phase, match_mode, hero_key, party_size, map_name, account_id, timer_bucket]
        if last_state == current && !shared.consume_dirty!
          sleep(update_interval)
          next
        end

        new_portrait = shared.hero_portrait_style
        if new_portrait != current_portrait
          hero_cache.portrait_style = new_portrait
          current_portrait = new_portrait
        end

        effective_hero_data = if shared.show_hero_image && GamePhase.shows_hero?(phase) && hero_key
                                hero_cache.get_or_fetch(hero_key)
                              end

        hero_name = effective_hero_data&.name
        hideout_text = effective_hero_data&.hideout_text

        game_status = mutex.synchronize do
          state.presence_status(hideout_text, hero_name, timer_text, cfg.presence.status)
        end

        show_party = (phase == GamePhase::HIDEOUT && party_size > 1)

        top_line = if phase == GamePhase::IN_QUEUE
                     GameState.hideout_line(hideout_text, hero_name, cfg.presence.status)
                   elsif phase == GamePhase::IN_MATCH && hero_name
                     ConfigManager.apply_vars(cfg.presence.details_with_hero, hero: hero_name)
                   else
                     ""
                   end

        details, state_opt = if phase == GamePhase::HIDEOUT
                               [game_status, show_party ? "In a Party" : nil]
                             elsif top_line.empty?
                               [game_status, nil]
                             else
                               [top_line, game_status]
                             end

        statlocker_status = if shared.show_statlocker_button
                              account_id ? "enabled" : "awaiting-id"
                            else
                              "disabled"
                            end

        RpcLogger.info(
          "[rpc] phase=#{phase} hero=#{hero_key || 'none'} details=\"#{details}\" " \
          "state=\"#{state_opt || 'none'}\" party=#{party_size} " \
          "account=#{account_id || 'none'} statlocker=#{statlocker_status}"
        )

        act = DiscordIpcClient.build_activity_payload(
          details: details,
          hero_data: effective_hero_data,
          state: state_opt,
          start_time: rpc_start_time,
          party_size: show_party ? party_size : nil,
          img_cfg: cfg.images,
          statlocker_account_id: account_id,
          show_statlocker_button: shared.show_statlocker_button
        )

        begin
          client.set_activity(act)
          last_state = current
        rescue StandardError => e
          RpcLogger.warn("[rpc] set_activity error: #{e.message}. Reconnecting...")
          begin
            client.reconnect
          rescue StandardError
            # Will retry on next iteration
          end
        end

        sleep(update_interval)
      end
    end
  end
end
