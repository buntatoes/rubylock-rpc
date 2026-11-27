# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "socket"
require_relative "rubylock_rpc/logger"
require_relative "rubylock_rpc/toml"
require_relative "rubylock_rpc/config"
require_relative "rubylock_rpc/game_state"
require_relative "rubylock_rpc/log_watcher"
require_relative "rubylock_rpc/hero_api"
require_relative "rubylock_rpc/discord_ipc"
require_relative "rubylock_rpc/steam"
require_relative "rubylock_rpc/process_watcher"
require_relative "rubylock_rpc/launcher"
require_relative "rubylock_rpc/updater"
require_relative "rubylock_rpc/tray"

module RubylockRpc
  VERSION = "1.3.0"
  # Public Discord Application ID (not a personal user ID); can be overridden via config.toml
  DEFAULT_DISCORD_APP_ID = "1566683259763429509"
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
        puts "rubylock-rpc v#{VERSION}"
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

      if flags.include?("--check-update")
        return run_check_update
      end

      if flags.include?("--update")
        return run_manual_update(silent: flags.include?("--silent"))
      end

      if flags.include?("--uninstall")
        return run_uninstall(silent: flags.include?("--silent"))
      end

      instance_lock = self.class.try_acquire_single_instance_lock
      cfg = ConfigManager.load
      no_launch = flags.include?("--no-launch")

      launch_mode = if flags.include?("--launch-with-command")
                      if game_command.empty?
                        RpcLogger.warn("[rubylock-rpc] --launch-with-command needs a command after --, e.g. -- %command%. Exiting.")
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
          RpcLogger.info("[rubylock-rpc] Another instance is running. Launching the game and waiting for it to exit.")
          pid = Launcher.launch_deadlock_with_command(launch_mode[1])
          Process.wait(pid) if pid
        elsif !no_launch
          RpcLogger.info("[rubylock-rpc] Another instance is running - re-triggering launch.")
          Launcher.launch_deadlock
        else
          RpcLogger.info("[rubylock-rpc] Another instance is already running. Exiting.")
        end
        return 0
      end

      RpcLogger.init
      RpcLogger.info("[config] Loaded from config.toml")
      shared = SharedBools.new(cfg)
      @shutdown_requested = false

      @tray = if flags.include?("--no-tray")
                Tray::NullTray.new
              else
                start_tray(shared, instance_lock)
              end

      unless flags.include?("--no-update-check")
        Thread.new do
          Updater.check_and_apply(auto_update: cfg.general.auto_update) do
            shutdown_and_exit(instance_lock)
          end
        rescue StandardError => e
          RpcLogger.warn("[updater] Background update check failed: #{e.message}")
        end
      end

      case launch_mode[0]
      when :steam
        Launcher.launch_deadlock
      when :command
        Launcher.launch_deadlock_with_command(launch_mode[1])
      end

      log_path = Steam.find_console_log(cfg.general.game_folder)
      RpcLogger.info("[rubylock-rpc] Monitoring: #{log_path}")

      state = GameState.new
      mutex = Mutex.new

      Thread.new { LogWatcher.new(log_path, cfg.general.game_log_poll_interval_ms).run(state, mutex) }
      Thread.new { ProcessWatcher.run(state, mutex) }

      run_rpc_loop(state, mutex, cfg, shared)
    ensure
      @tray&.stop rescue nil
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
        RubyLock RPC — Deadlock Rich Presence for Discord (v#{VERSION}, GPL-3.0)
        Usage: rubylock-rpc [OPTIONS] [-- <game command>]

        Options:
          --no-launch                    Skip launching Deadlock on startup
          --no-tray                      Run without a system tray icon
          --no-update-check              Skip background GitHub release update check
          --check-update                 Check GitHub for a newer release and exit
          --update                       Download and install the latest GitHub release
          --uninstall                    Uninstall RubyLock RPC (GUI if desktop active)
          --silent                       Run --update or --uninstall non-interactively
          --no-shortcut                  Skip shortcut installation prompt
          --launch-with-command -- <cmd> Launch game command with -condebug appended
          --generate-config              Write default config.toml and exit
          -v, --version                  Show version
          -h, --help                     Show this help message
      HELP
    end

    def start_tray(shared, instance_lock)
      icon_ico = File.expand_path("../assets/icon.ico", __dir__)
      Tray.start(
        shared: shared,
        version: VERSION,
        icon_ico_path: icon_ico,
        callbacks: {
          launch: -> { Launcher.launch_deadlock },
          toggle_exit: lambda {
            new_val = !shared.exit_when_game_closes
            shared.exit_when_game_closes = new_val
            ConfigManager.set_config_value("general", "exit_when_game_closes", new_val)
          },
          toggle_auto_update: lambda {
            new_val = !shared.auto_update
            shared.auto_update = new_val
            ConfigManager.set_config_value("general", "auto_update", new_val)
          },
          check_update: lambda {
            result = Updater.check_and_apply(auto_update: false) do
              shutdown_and_exit(instance_lock)
            end
            if result == :up_to_date
              Updater.notify_user("RubyLock RPC", "You are already running the latest version (v#{VERSION}).")
            end
          },
          open_config: lambda {
            dir = RpcLogger.resolve_data_dir
            if Gem.win_platform?
              Process.detach(Process.spawn("explorer.exe", dir.tr("/", "\\")))
            else
              Process.detach(Process.spawn("xdg-open", dir))
            end
          },
          quit: -> { shutdown_and_exit(instance_lock) }
        }
      )
    end

    def shutdown_and_exit(instance_lock = nil)
      @shutdown_requested = true
      @active_client&.clear_activity rescue nil
      @active_client&.close rescue nil
      @tray&.stop rescue nil
      instance_lock&.close rescue nil
      exit(0)
    end

    def run_check_update
      release = Updater.check_latest
      if release
        puts "Update available: #{release.tag_name} (current: v#{VERSION}) - #{release.html_url}"
      else
        puts "RubyLock RPC v#{VERSION} is up to date."
      end
      0
    end

    def run_manual_update(silent:)
      release = Updater.check_latest
      unless release
        puts "RubyLock RPC v#{VERSION} is already up to date."
        return 0
      end

      puts "Updating RubyLock RPC from v#{VERSION} to #{release.tag_name}..."
      result = Updater.install_update(release, silent: silent)
      if result == :launched_installer
        puts "Installer launched for #{release.tag_name}."
      else
        puts "Successfully updated RubyLock RPC to #{release.tag_name}."
      end
      0
    rescue StandardError => e
      warn "Update failed: #{e.message}"
      1
    end

    def run_uninstall(silent:)
      if Gem.win_platform?
        setup_exe = File.join(File.expand_path("..", __dir__), "RubyLock-RPC-Setup.exe")
        unless File.exist?(setup_exe)
          warn "Uninstaller not found at #{setup_exe}. Use Windows Installed Apps to uninstall."
          return 1
        end
        args = ["--uninstall"]
        args << "--silent" if silent
        pid = Process.spawn(setup_exe, *args)
        Process.detach(pid)
        return 0
      end

      app_root = File.expand_path("..", __dir__)
      uninstaller = [
        File.join(app_root, "uninstall.sh"),
        File.join(app_root, "packaging", "linux", "uninstall.sh")
      ].find { |p| File.exist?(p) }

      unless uninstaller
        warn "Linux uninstaller script not found."
        return 1
      end

      prefix = Updater.detect_linux_install_prefix(app_root)
      args = ["sh", uninstaller, "--prefix", prefix]
      args << "--silent" if silent
      exec({ "PREFIX" => prefix }, *args)
    end

    def connect_discord(app_id)
      client = DiscordIpcClient.new(app_id)
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
      app_id = cfg.general.discord_app_id || DEFAULT_DISCORD_APP_ID
      RpcLogger.info("[discord] Connecting...")
      client = connect_discord(app_id)
      @active_client = client
      current_portrait = cfg.presence.hero_portrait_style
      hero_cache = HeroCache.new(current_portrait)
      last_state = nil
      game_was_running = false
      rpc_start_time = Time.now.to_i

      update_interval = [cfg.general.discord_update_interval_s.to_i, 1].max
      timer_refresh_secs = [update_interval, MIN_TIMER_REFRESH_SECS].max

      trap("INT")  { shutdown_and_exit }
      trap("TERM") { shutdown_and_exit }
      @tray&.update_status("Waiting for Deadlock")

      loop do
        break if @shutdown_requested

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
          RpcLogger.info("[rubylock-rpc] Game closed.")
          if shared.exit_when_game_closes
            shutdown_and_exit
          else
            client.clear_activity
            game_was_running = false
            last_state = nil
            @tray&.update_status("Waiting for Deadlock")
            sleep(update_interval)
            next
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
          tray_status = state_opt ? "#{details} — #{state_opt}" : details
          @tray&.update_status(tray_status)
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
