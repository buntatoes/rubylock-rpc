# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "game_state"
require_relative "logger"

module RubylockRpc
  module ProcessWatcher
    POLL_INTERVAL_S = 3

    if Gem.win_platform?
      require "fiddle"
      require "fiddle/import"

      module Win32Snapshot
        extend Fiddle::Importer
        dlload "kernel32.dll"

        TH32CS_SNAPPROCESS = 0x00000002
        INVALID_HANDLE_VALUE = -1
        PTR_SIZE = Fiddle::SIZEOF_VOIDP
        # On x64 Windows: dwSize(4) + cntUsage(4) + th32ProcessID(4) + pad(4) +
        # th32DefaultHeapID(8) + th32ModuleID(4) + cntThreads(4) +
        # th32ParentProcessID(4) + pcPriClassBase(4) + dwFlags(4) = 44 bytes before szExeFile[260] -> total 304 bytes.
        # On x86 Windows: 36 bytes before szExeFile[260] -> total 296 bytes.
        EXE_NAME_OFFSET = (PTR_SIZE == 8) ? 44 : 36
        PROCESSENTRY32_SIZE = EXE_NAME_OFFSET + 260

        extern "void* CreateToolhelp32Snapshot(unsigned long, unsigned long)"
        extern "int Process32First(void*, void*)"
        extern "int Process32Next(void*, void*)"
        extern "int CloseHandle(void*)"
      end
    end

    module_function

    def process_running?(target_name)
      target = target_name.to_s.downcase
      target_stem = target.sub(/\.exe\z/, "")
      if Gem.win_platform?
        win32_process_running?(target)
      else
        Dir.glob("/proc/[0-9]*").any? do |proc_dir|
          comm = File.read(File.join(proc_dir, "comm")).strip.downcase
          return true if comm == target || comm == target_stem

          cmdline = File.binread(File.join(proc_dir, "cmdline"))
          first_arg = cmdline.split("\0", 2).first.to_s.downcase
          base = File.basename(first_arg.tr("\\", "/"))
          base == target || base == target_stem
        rescue StandardError
          false
        end
      end
    rescue StandardError
      false
    end

    def win32_process_running?(target_lower)
      snapshot = Win32Snapshot.CreateToolhelp32Snapshot(Win32Snapshot::TH32CS_SNAPPROCESS, 0)
      return false if snapshot.null? || snapshot.to_i == Win32Snapshot::INVALID_HANDLE_VALUE

      begin
        buf = +"\0" * Win32Snapshot::PROCESSENTRY32_SIZE
        buf[0, 4] = [Win32Snapshot::PROCESSENTRY32_SIZE].pack("V")

        return false if Win32Snapshot.Process32First(snapshot, buf) == 0

        loop do
          raw_name = buf[Win32Snapshot::EXE_NAME_OFFSET, 260]
          exe_name = raw_name.split("\0", 2).first.to_s.downcase
          return true if exe_name == target_lower

          break if Win32Snapshot.Process32Next(snapshot, buf) == 0
        end
        false
      ensure
        Win32Snapshot.CloseHandle(snapshot)
      end
    end

    def deadlock_running?
      process_running?("deadlock.exe")
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
