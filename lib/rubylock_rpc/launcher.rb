# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "process_watcher"
require_relative "steam"
require_relative "logger"

module RubylockRpc
  module Launcher
    DEADLOCK_APP_ID = "1422450"

    module_function

    def launch_deadlock_with_command(command_args)
      return nil if command_args.nil? || command_args.empty?

      program = command_args[0]
      rest = command_args[1..] || []
      rest << "-condebug" unless rest.any? { |a| a.casecmp("-condebug").zero? }

      RpcLogger.info("[launcher] Launching via command: #{program} #{rest.join(' ')}")
      Process.spawn(program, *rest)
    rescue StandardError => e
      RpcLogger.warn("[launcher] Failed to launch command: #{e.message}")
      nil
    end

    def launch_deadlock
      if ProcessWatcher.deadlock_running?
        RpcLogger.info("[launcher] Deadlock is already running - skipping launch.")
        return
      end

      RpcLogger.info("[launcher] Launching Deadlock with -condebug...")
      steam_exe = Steam.steam_exe_path
      unless steam_exe
        RpcLogger.warn("[launcher] Could not find Steam executable. Launch Deadlock manually with -condebug.")
        return
      end

      Process.spawn(steam_exe, "-applaunch", DEADLOCK_APP_ID, "-condebug")
      RpcLogger.info("[launcher] Steam launch initiated.")
    rescue StandardError => e
      RpcLogger.warn("[launcher] Failed to launch Steam: #{e.message}")
    end
  end
end
