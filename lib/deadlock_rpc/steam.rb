# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "config"
require_relative "logger"

module DeadlockRpc
  module Steam
    DEADLOCK_APP_ID    = "1422450"
    GAME_DIR_MARKER    = File.join("game", "citadel").freeze
    CONSOLE_LOG_SUFFIX = File.join("game", "citadel", "console.log").freeze

    PATH_RE       = /"path"\s+"([^"]+)"/.freeze
    INSTALLDIR_RE = /"installdir"\s+"([^"]+)"/.freeze

    module_function

    def find_console_log(game_folder_override = nil)
      folder = game_folder_override.to_s.strip
      unless folder.empty?
        if deadlock_install?(folder)
          unless File.basename(folder).casecmp("Deadlock").zero?
            RpcLogger.warn("[steam] game_folder does not end with \"Deadlock\": #{folder}")
          end
          path = File.join(folder, CONSOLE_LOG_SUFFIX)
          RpcLogger.info("[steam] Using configured game_folder: #{path}")
          return path
        end

        RpcLogger.warn("[steam] Configured game_folder is no longer a Deadlock install: #{folder}. Re-detecting.")
        if (detected = try_find_console_log)
          persist_game_root(detected)
          return detected
        end

        fallback = File.join(folder, CONSOLE_LOG_SUFFIX)
        RpcLogger.warn("[steam] Re-detection failed. Keeping configured game_folder: #{fallback}")
        return fallback
      end

      if (detected = try_find_console_log)
        persist_game_root(detected)
        detected
      else
        fallback = File.join(default_fallback, CONSOLE_LOG_SUFFIX)
        RpcLogger.warn("[steam] Deadlock not found in Steam library. Using fallback path: #{fallback}")
        fallback
      end
    end

    def deadlock_install?(game_dir)
      File.directory?(File.join(game_dir.to_s, GAME_DIR_MARKER))
    end

    def persist_game_root(console_log_path)
      game_root = File.dirname(File.dirname(File.dirname(console_log_path)))
      RpcLogger.info("[steam] Auto-detected game folder saved to config: #{game_root}")
      ConfigManager.set_config_value("general", "game_folder", game_root)
    end

    def try_find_console_log
      steam_vdf_locations.each do |vdf_path|
        next unless File.exist?(vdf_path)

        content = File.read(vdf_path, encoding: "UTF-8")
        content.scan(PATH_RE) do |match|
          lib_path = match[0].gsub("\\\\", "\\")
          manifest = File.join(lib_path, "steamapps", "appmanifest_#{DEADLOCK_APP_ID}.acf")
          next unless File.exist?(manifest)

          mtext = File.read(manifest, encoding: "UTF-8")
          if (m = INSTALLDIR_RE.match(mtext))
            game_path = File.join(lib_path, "steamapps", "common", m[1])
            return File.join(game_path, CONSOLE_LOG_SUFFIX) if File.exist?(game_path)
          end
        end
      rescue StandardError
        next
      end

      hardcoded_fallbacks.find { |p| File.directory?(File.dirname(p)) }
    end

    def steam_exe_path
      if Gem.win_platform?
        root = steam_root_windows
        root ? File.join(root, "steam.exe") : nil
      else
        ENV.fetch("PATH", "").split(":").each do |dir|
          candidate = File.join(dir, "steam")
          return candidate if File.exist?(candidate)
        end
        home = Dir.home rescue ""
        [
          File.join(home, ".local/share/Steam/steam.sh"),
          File.join(home, ".steam/steam.sh"),
          "/usr/bin/steam",
          "/usr/local/bin/steam"
        ].find { |p| File.exist?(p) }
      end
    end

    def steam_root_windows
      if Gem.win_platform?
        begin
          require "win32/registry"
          Win32::Registry::HKEY_CURRENT_USER.open('Software\Valve\Steam') do |reg|
            path = reg["SteamPath"].to_s
            return path if !path.empty? && File.directory?(path)
          end
        rescue StandardError
          # Fall back to common install locations
        end
      end

      [
        'C:\Program Files (x86)\Steam',
        'C:\Program Files\Steam'
      ].find { |p| File.directory?(p) }
    end

    def steam_vdf_locations
      if Gem.win_platform?
        root = steam_root_windows
        root ? [File.join(root, "steamapps", "libraryfolders.vdf")] : []
      else
        home = Dir.home rescue ""
        [
          File.join(home, ".steam/steam/steamapps/libraryfolders.vdf"),
          File.join(home, ".local/share/Steam/steamapps/libraryfolders.vdf")
        ]
      end
    end

    def hardcoded_fallbacks
      if Gem.win_platform?
        root = steam_root_windows || 'C:\Program Files (x86)\Steam'
        [File.join(root, "steamapps", "common", "Deadlock", CONSOLE_LOG_SUFFIX)]
      else
        home = Dir.home rescue ""
        [
          File.join(home, ".steam/steam/steamapps/common/Deadlock", CONSOLE_LOG_SUFFIX),
          File.join(home, ".local/share/Steam/steamapps/common/Deadlock", CONSOLE_LOG_SUFFIX)
        ]
      end
    end

    def default_fallback
      if Gem.win_platform?
        root = steam_root_windows || 'C:\Program Files (x86)\Steam'
        File.join(root, "steamapps", "common", "Deadlock")
      else
        home = Dir.home rescue ""
        File.join(home, ".local/share/Steam/steamapps/common/Deadlock")
      end
    end
  end
end
