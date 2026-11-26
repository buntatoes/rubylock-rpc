# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "open3"
require_relative "game_state"
require_relative "logger"

module DeadlockRpc
  module ProcessWatcher
    POLL_INTERVAL_S = 3

    module_function

    def deadlock_running?
      if Gem.win_platform?
        out, status = Open3.capture2("tasklist", "/FI", "IMAGENAME eq deadlock.exe", "/NH")
        status.success? && out.downcase.include?("deadlock.exe")
      else
        Dir.glob("/proc/[0-9]*/comm").any? do |comm_path|
          name = File.read(comm_path).strip
          name == "deadlock" || name == "deadlock.exe"
        rescue StandardError
          false
        end
      end
    rescue StandardError
      false
    end

    def run(state, mutex)
      was_running = false

      loop do
        running = deadlock_running?

        if running && !was_running
          RpcLogger.info("[process] Deadlock process detected")
          mutex.synchronize do
            state.enter_main_menu if state.phase == GamePhase::NOT_RUNNING
          end
        elsif !running && was_running
          RpcLogger.info("[process] Deadlock process exited - resetting state")
          mutex.synchronize { state.reset }
        end

        was_running = running
        sleep(POLL_INTERVAL_S)
      end
    end
  end
end
