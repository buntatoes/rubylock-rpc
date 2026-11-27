# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "json"
require "securerandom"
require "socket"
require_relative "logger"

module RubylockRpc
  # Pure-Ruby Discord Rich Presence IPC client supporting both Windows Named Pipes
  # (\\.\pipe\discord-ipc-0..9) and Unix Domain Sockets.
  class DiscordIpcClient
    OP_HANDSHAKE = 0
    OP_FRAME     = 1
    OP_CLOSE     = 2

    attr_reader :app_id

    def self.build_activity_payload(
      details:,
      hero_data:,
      state:,
      start_time:,
      party_size:,
      img_cfg:,
      statlocker_account_id: nil,
      show_statlocker_button: false
    )
      large_image = if hero_data && !hero_data.icon_url.to_s.empty?
                      hero_data.icon_url
                    else
                      img_cfg.fallback_large_image
                    end

      large_text = if hero_data && !hero_data.name.to_s.empty?
                     hero_data.name
                   else
                     img_cfg.fallback_large_image_tooltip
                   end

      assets = {
        "large_image" => large_image,
        "large_text"  => large_text
      }

      if large_image != img_cfg.corner_image
        assets["small_image"] = img_cfg.corner_image
        assets["small_text"]  = img_cfg.corner_image_tooltip
      end

      activity = {
        "details" => details,
        "assets"  => assets
      }

      activity["state"] = state if state && !state.empty?
      activity["timestamps"] = { "start" => start_time.to_i } if start_time
      activity["party"] = { "size" => [party_size.to_i, 6] } if party_size

      if show_statlocker_button && statlocker_account_id
        activity["buttons"] = [
          {
            "label" => "View on Statlocker",
            "url"   => "https://statlocker.gg/profile/#{statlocker_account_id}/matches"
          }
        ]
      end

      activity
    end

    def initialize(app_id)
      @app_id = app_id.to_s
      @io = nil
    end

    def connected?
      !@io.nil?
    end

    def connect
      close
      (0..9).each do |idx|
        io = try_open_pipe(idx)
        next unless io

        @io = io
        send_frame(OP_HANDSHAKE, { "v" => 1, "client_id" => @app_id })
        read_frame
        return true
      rescue StandardError
        close
      end
      raise IOError, "Unable to connect to Discord IPC pipe (0..9)"
    end

    def reconnect
      close
      connect
    end

    def set_activity(activity_hash)
      raise IOError, "Discord IPC not connected" unless @io

      payload = {
        "cmd"   => "SET_ACTIVITY",
        "args"  => {
          "pid"      => Process.pid,
          "activity" => activity_hash
        },
        "nonce" => SecureRandom.uuid
      }
      send_frame(OP_FRAME, payload)
      read_frame
      true
    end

    def clear_activity
      return false unless @io

      payload = {
        "cmd"   => "SET_ACTIVITY",
        "args"  => {
          "pid"      => Process.pid,
          "activity" => nil
        },
        "nonce" => SecureRandom.uuid
      }
      send_frame(OP_FRAME, payload)
      read_frame
      true
    rescue StandardError
      false
    end

    def close
      @io&.close
    rescue StandardError
      # Ignore close errors
    ensure
      @io = nil
    end

    private

    def try_open_pipe(idx)
      if Gem.win_platform?
        path = "\\\\.\\pipe\\discord-ipc-#{idx}"
        File.open(path, "r+b")
      else
        dirs = [
          ENV["XDG_RUNTIME_DIR"],
          ENV["TMPDIR"],
          ENV["TMP"],
          ENV["TEMP"],
          "/tmp"
        ].compact.uniq
        dirs.each do |d|
          candidates = [
            File.join(d, "discord-ipc-#{idx}"),
            File.join(d, "app/com.discordapp.Discord/discord-ipc-#{idx}"),
            File.join(d, "app/dev.vencord.Vesktop/discord-ipc-#{idx}"),
            File.join(d, "snap.discord/discord-ipc-#{idx}")
          ]
          candidates.each do |sock_path|
            next unless File.exist?(sock_path)

            return UNIXSocket.new(sock_path)
          rescue StandardError
            next
          end
        end
        nil
      end
    rescue StandardError
      nil
    end

    def send_frame(opcode, data_hash)
      json = JSON.generate(data_hash)
      header = [opcode, json.bytesize].pack("V2")
      @io.write(header)
      @io.write(json)
      @io.flush
    end

    def read_frame
      header = @io.read(8)
      raise EOFError, "Discord IPC closed while reading header" unless header && header.bytesize == 8

      opcode, length = header.unpack("V2")
      body = length.positive? ? @io.read(length) : ""
      [opcode, body]
    end
  end
end
