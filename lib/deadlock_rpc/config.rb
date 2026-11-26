# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "toml"
require_relative "logger"

module DeadlockRpc
  module HeroPortraitStyle
    NORMAL   = :normal
    GLOAT    = :gloat
    CRITICAL = :critical
    ICON     = :icon
    FULLBODY = :fullbody

    ALL = [NORMAL, GLOAT, CRITICAL, ICON, FULLBODY].freeze

    module_function

    def from_string(str)
      case str.to_s.strip.downcase
      when "gloat"    then GLOAT
      when "critical" then CRITICAL
      when "icon"     then ICON
      when "fullbody" then FULLBODY
      else NORMAL
      end
    end
  end

  GeneralConfig = Struct.new(
    :launch_game_on_start,
    :exit_when_game_closes,
    :auto_update,
    :game_log_poll_interval_ms,
    :discord_update_interval_s,
    :game_folder,
    :declined_shortcut,
    :config_version,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        launch_game_on_start: true,
        exit_when_game_closes: true,
        auto_update: false,
        game_log_poll_interval_ms: 500,
        discord_update_interval_s: 5,
        game_folder: nil,
        declined_shortcut: false,
        config_version: 4
      }
      super(defaults.merge(kwargs))
    end
  end

  StatusStrings = Struct.new(
    :game_not_running,
    :in_main_menu,
    :in_hideout,
    :in_matchmaking,
    :loading_into_match,
    :in_match,
    :match_location_label,
    :post_match,
    :spectating,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        game_not_running: "Not Running",
        in_main_menu: "Browsing the Main Menu",
        in_hideout: "In the Hideout",
        in_matchmaking: "Searching for a Match...",
        loading_into_match: "{mode} - Loading into Match",
        in_match: "{mode}",
        match_location_label: "the Cursed Apple",
        post_match: "Reviewing Match Results",
        spectating: "Spectating a Match"
      }
      super(defaults.merge(kwargs))
    end
  end

  PresenceConfig = Struct.new(
    :show_hero_image,
    :show_match_timer,
    :show_statlocker_button,
    :hero_portrait_style,
    :details_with_hero,
    :status,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        show_hero_image: true,
        show_match_timer: true,
        show_statlocker_button: false,
        hero_portrait_style: HeroPortraitStyle::NORMAL,
        details_with_hero: "Playing as {hero}",
        status: StatusStrings.new
      }
      super(defaults.merge(kwargs))
    end
  end

  ImagesConfig = Struct.new(
    :fallback_large_image,
    :fallback_large_image_tooltip,
    :corner_image,
    :corner_image_tooltip,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        fallback_large_image: "deadlock_logo",
        fallback_large_image_tooltip: "Deadlock RPC",
        corner_image: "deadlock_logo",
        corner_image_tooltip: "Deadlock RPC"
      }
      super(defaults.merge(kwargs))
    end
  end

  Config = Struct.new(:general, :presence, :images, keyword_init: true) do
    def initialize(**kwargs)
      super(
        general: kwargs[:general] || GeneralConfig.new,
        presence: kwargs[:presence] || PresenceConfig.new,
        images: kwargs[:images] || ImagesConfig.new
      )
    end
  end

  class SharedBools
    attr_reader :mutex

    def initialize(cfg)
      @mutex = Mutex.new
      @launch_game_on_start = cfg.general.launch_game_on_start
      @exit_when_game_closes = cfg.general.exit_when_game_closes
      @auto_update = cfg.general.auto_update
      @show_hero_image = cfg.presence.show_hero_image
      @show_match_timer = cfg.presence.show_match_timer
      @show_statlocker_button = cfg.presence.show_statlocker_button
      @hero_portrait_style = cfg.presence.hero_portrait_style
      @settings_dirty = false
    end

    %i[
      launch_game_on_start
      exit_when_game_closes
      auto_update
      show_hero_image
      show_match_timer
      show_statlocker_button
      hero_portrait_style
    ].each do |attr|
      define_method(attr) do
        @mutex.synchronize { instance_variable_get(:"@#{attr}") }
      end

      define_method(:"#{attr}=") do |val|
        @mutex.synchronize do
          instance_variable_set(:"@#{attr}", val)
          @settings_dirty = true
        end
      end
    end

    def consume_dirty!
      @mutex.synchronize do
        was_dirty = @settings_dirty
        @settings_dirty = false
        was_dirty
      end
    end
  end

  module ConfigManager
    CURRENT_CONFIG_VERSION = 4

    DEFAULT_TOML = <<~TOML
      [general]
      launch_game_on_start = true
      exit_when_game_closes = true
      # Install available updates automatically instead of showing the update prompt.
      auto_update = false
      game_log_poll_interval_ms = 500
      discord_update_interval_s = 5
      # Override the Deadlock install location if auto-detection fails. Filled in automatically once
      # the game is found, and re-detected if the folder ever stops being a Deadlock install.
      # Example: steamapps\\common\\Deadlock
      game_folder = ""
      # Set to true after the user declines the shortcut install prompt. Managed automatically.
      declined_shortcut = false
      # Managed automatically — do not edit.
      config_version = 4

      [presence]
      show_hero_image = true
      # Show how long the current match has been running, as a clock (e.g. "07:42"). Added to the
      # in-match status line, or placed with {timer} if presence.status.in_match uses that variable.
      show_match_timer = true
      # Show a Statlocker button when your Steam ID is detected in the game log.
      show_statlocker_button = false
      # Hero portrait style to display. Options: "normal", "gloat", "critical", "icon", "fullbody".
      hero_portrait_style = "normal"
      # Rich presence detail line when a hero is selected. Supports {hero}.
      details_with_hero = "Playing as {hero}"

      [presence.status]
      # Status strings for each game phase. Supports {mode} where noted.
      game_not_running = "Not Running"
      in_main_menu = "Browsing the Main Menu"
      in_hideout = "In the Hideout"
      in_matchmaking = "Searching for a Match..."
      # Supports {mode} (e.g. "Ranked", "Unranked").
      loading_into_match = "{mode} - Loading into Match"
      # Supports {mode} and {timer} (match duration, e.g. "07:42").
      in_match = "{mode}"
      match_location_label = "the Cursed Apple"
      post_match = "Reviewing Match Results"
      spectating = "Spectating a Match"

      # Asset key names registered in your Discord application's Art Assets.
      [images]
      fallback_large_image = "deadlock_logo"
      fallback_large_image_tooltip = "Deadlock RPC"
      corner_image = "deadlock_logo"
      corner_image_tooltip = "Deadlock RPC"
    TOML

    module_function

    def config_path(base_dir = RpcLogger.resolve_data_dir)
      File.join(base_dir, "config.toml")
    end

    def apply_vars(template, vars)
      result = template.to_s.dup
      vars.each do |k, v|
        result.gsub!("{#{k}}", v.to_s)
      end
      result
    end

    def load(path = config_path)
      unless File.exist?(path)
        File.write(path, DEFAULT_TOML)
        return from_hash(Toml.parse(DEFAULT_TOML))
      end

      raw = File.read(path, encoding: "UTF-8")
      parsed = Toml.parse(raw)
      if migrate!(parsed)
        File.write(path, Toml.dump(parsed))
      end
      from_hash(parsed)
    rescue StandardError => e
      RpcLogger.warn("[config] Failed to load #{path} (#{e.message}), using defaults")
      from_hash(Toml.parse(DEFAULT_TOML))
    end

    def from_hash(h)
      gen_h = h["general"] || {}
      pres_h = h["presence"] || {}
      stat_h = pres_h["status"] || {}
      img_h = h["images"] || {}

      gf = gen_h["game_folder"].to_s.strip
      general = GeneralConfig.new(
        launch_game_on_start: bool_or(gen_h["launch_game_on_start"], true),
        exit_when_game_closes: bool_or(gen_h["exit_when_game_closes"], true),
        auto_update: bool_or(gen_h["auto_update"], false),
        game_log_poll_interval_ms: int_or(gen_h["game_log_poll_interval_ms"], 500),
        discord_update_interval_s: int_or(gen_h["discord_update_interval_s"], 5),
        game_folder: gf.empty? ? nil : gf,
        declined_shortcut: bool_or(gen_h["declined_shortcut"], false),
        config_version: int_or(gen_h["config_version"], CURRENT_CONFIG_VERSION)
      )

      status = StatusStrings.new(
        game_not_running: str_or(stat_h["game_not_running"], "Not Running"),
        in_main_menu: str_or(stat_h["in_main_menu"], "Browsing the Main Menu"),
        in_hideout: str_or(stat_h["in_hideout"], "In the Hideout"),
        in_matchmaking: str_or(stat_h["in_matchmaking"], "Searching for a Match..."),
        loading_into_match: str_or(stat_h["loading_into_match"], "{mode} - Loading into Match"),
        in_match: str_or(stat_h["in_match"], "{mode}"),
        match_location_label: str_or(stat_h["match_location_label"], "the Cursed Apple"),
        post_match: str_or(stat_h["post_match"], "Reviewing Match Results"),
        spectating: str_or(stat_h["spectating"], "Spectating a Match")
      )

      presence = PresenceConfig.new(
        show_hero_image: bool_or(pres_h["show_hero_image"], true),
        show_match_timer: bool_or(pres_h["show_match_timer"], true),
        show_statlocker_button: bool_or(pres_h["show_statlocker_button"], false),
        hero_portrait_style: HeroPortraitStyle.from_string(pres_h["hero_portrait_style"]),
        details_with_hero: str_or(pres_h["details_with_hero"], "Playing as {hero}"),
        status: status
      )

      images = ImagesConfig.new(
        fallback_large_image: str_or(img_h["fallback_large_image"], "deadlock_logo"),
        fallback_large_image_tooltip: str_or(img_h["fallback_large_image_tooltip"], "Deadlock RPC"),
        corner_image: str_or(img_h["corner_image"], "deadlock_logo"),
        corner_image_tooltip: str_or(img_h["corner_image_tooltip"], "Deadlock RPC")
      )

      Config.new(general: general, presence: presence, images: images)
    end

    def set_config_value(section, key, value, path = config_path)
      return unless File.exist?(path)

      parsed = Toml.parse(File.read(path, encoding: "UTF-8"))
      parsed[section] ||= {}
      parsed[section][key] = value
      File.write(path, Toml.dump(parsed))
    rescue StandardError => e
      RpcLogger.warn("[config] Could not update #{section}.#{key}: #{e.message}")
    end

    def migrate!(parsed)
      gen = (parsed["general"] ||= {})
      version = gen["config_version"].is_a?(Integer) ? gen["config_version"] : 0
      return false if version >= CURRENT_CONFIG_VERSION

      defaults = Toml.parse(DEFAULT_TOML)
      defaults.each do |sec, table|
        next unless table.is_a?(Hash)

        parsed[sec] ||= {}
        table.each do |k, v|
          if v.is_a?(Hash)
            parsed[sec][k] ||= {}
            v.each { |sk, sv| parsed[sec][k][sk] = sv unless parsed[sec][k].key?(sk) }
          else
            parsed[sec][k] = v unless parsed[sec].key?(k)
          end
        end
      end

      gen["config_version"] = CURRENT_CONFIG_VERSION
      true
    end

    def bool_or(val, default)
      val.is_a?(TrueClass) || val.is_a?(FalseClass) ? val : default
    end

    def int_or(val, default)
      val.is_a?(Integer) ? val : default
    end

    def str_or(val, default)
      val.is_a?(String) ? val : default
    end
  end
end
