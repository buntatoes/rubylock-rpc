# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/rubylock_rpc"

class TestRubylockRpc < Minitest::Test
  def test_toml_parse_and_dump
    parsed = RubylockRpc::Toml.parse(RubylockRpc::ConfigManager::DEFAULT_TOML)
    assert_equal true, parsed.dig("general", "launch_game_on_start")
    assert_equal 500, parsed.dig("general", "game_log_poll_interval_ms")
    assert_equal "", parsed.dig("general", "discord_app_id")
    assert_equal 5, parsed.dig("general", "config_version")
    assert_equal "Playing as {hero}", parsed.dig("presence", "details_with_hero")
    assert_equal "Browsing the Main Menu", parsed.dig("presence", "status", "in_main_menu")
    assert_equal "deadlock_logo", parsed.dig("images", "fallback_large_image")
    assert_equal "RubyLock RPC", parsed.dig("images", "fallback_large_image_tooltip")

    dumped = RubylockRpc::Toml.dump(parsed)
    reparsed = RubylockRpc::Toml.parse(dumped)
    assert_equal parsed, reparsed
  end

  def test_config_migration_and_vars
    Dir.mktmpdir do |dir|
      cfg_file = File.join(dir, "config.toml")
      File.write(cfg_file, "[general]\nconfig_version = 1\nlaunch_game_on_start = false\n")
      cfg = RubylockRpc::ConfigManager.load(cfg_file)
      assert_equal false, cfg.general.launch_game_on_start
      assert_equal 5, cfg.general.config_version
      assert_equal nil, cfg.general.discord_app_id
      assert_equal "Playing as {hero}", cfg.presence.details_with_hero
    end

    Dir.mktmpdir do |dir|
      cfg_file = File.join(dir, "config.toml")
      File.write(cfg_file, "[general]\nconfig_version = 5\ndiscord_app_id = \"123456789012345678\"\n")
      cfg = RubylockRpc::ConfigManager.load(cfg_file)
      assert_equal "123456789012345678", cfg.general.discord_app_id
    end

    rendered = RubylockRpc::ConfigManager.apply_vars("Playing as {hero} in {mode}", hero: "Haze", mode: "Standard Match")
    assert_equal "Playing as Haze in Standard Match", rendered
  end

  def test_hero_key_normalization_and_static_fallback
    assert_equal "hero_inferno", RubylockRpc::LogWatcher.normalize_hero_key("hero_inferno_v2")
    assert_equal "hero_ratking", RubylockRpc::LogWatcher.normalize_hero_key("ratking")
    assert_equal "Infernus", RubylockRpc::HeroCache.static_fallback("hero_inferno")
    assert_equal "Rat King", RubylockRpc::HeroCache.static_fallback("hero_ratking")
    assert_equal "Mo & Krill", RubylockRpc::HeroCache.static_fallback("hero_krill")
  end

  def test_log_watcher_state_machine
    state = RubylockRpc::GameState.new
    state.enter_main_menu
    assert_equal RubylockRpc::GamePhase::MAIN_MENU, state.phase

    # Enter hideout and load hero
    RubylockRpc::LogWatcher.process_line('[Client] Map: "dl_hideout"', state)
    assert_equal RubylockRpc::GamePhase::HIDEOUT, state.phase
    RubylockRpc::LogWatcher.process_line("[HostStateManager] Host activate: (dl_hideout)", state)
    assert_equal true, state.hideout_loaded

    RubylockRpc::LogWatcher.process_line("[Server] Loaded hero 1/hero_ratking_v2", state)
    assert_equal "hero_ratking", state.hero_key

    # Account ID and party events
    RubylockRpc::LogWatcher.process_line("User [U:1:12345678] connected", state)
    assert_equal 12_345_678, state.local_account_id

    RubylockRpc::LogWatcher.process_line("[Client] Players: 3 (0 bots) / 3 humans", state)
    assert_equal 3, state.party_size

    # Start and stop matchmaking
    RubylockRpc::LogWatcher.process_line("k_EMsgClientToGCStartMatchmaking", state)
    assert_equal RubylockRpc::GamePhase::IN_QUEUE, state.phase
    RubylockRpc::LogWatcher.process_line("k_EMsgClientToGCStopMatchmaking", state)
    assert_equal RubylockRpc::GamePhase::HIDEOUT, state.phase

    # Enter match on dl_midtown with 12 players -> Standard Match
    RubylockRpc::LogWatcher.process_line("Lobby 100 for Match 200 created", state)
    assert_equal RubylockRpc::GamePhase::MATCH_INTRO, state.phase
    RubylockRpc::LogWatcher.process_line("[Client] Created physics for dl_midtown", state)
    assert_equal RubylockRpc::GamePhase::IN_MATCH, state.phase
    RubylockRpc::LogWatcher.process_line("[Client] Players: 12 (0 bots) / 12 humans", state)
    assert_equal RubylockRpc::MatchMode::STANDARD, state.match_mode

    # Hero lock-in during standard match
    RubylockRpc::LogWatcher.process_line("VMDL Camera Pose Success! models/heroes/haze/haze.vmdl", state)
    assert_equal "hero_haze", state.hero_key
    RubylockRpc::LogWatcher.process_line("VMDL Camera Pose Success! models/heroes/bebop/bebop.vmdl", state)
    assert_equal "hero_haze", state.hero_key

    # Match start timer & postgame
    RubylockRpc::LogWatcher.process_line("ChangeGameState: GameInProgress (7)", state)
    refute_nil state.match_started_at
    assert_equal "07:42", RubylockRpc::GameState.format_match_elapsed(462)
    assert_equal "1:01:05", RubylockRpc::GameState.format_match_elapsed(3665)

    RubylockRpc::LogWatcher.process_line("Lobby 100 for Match 200 destroyed", state)
    assert_equal RubylockRpc::GamePhase::POST_MATCH, state.phase
  end

  def test_discord_activity_payload
    img_cfg = RubylockRpc::ImagesConfig.new
    hero = RubylockRpc::HeroData.new(
      name: "Rat King",
      hideout_text: "Wishing The Hideout Was On Long Island",
      icon_url: "https://assets.deadlock-api.com/heroes/ratking.png"
    )

    payload = RubylockRpc::DiscordIpcClient.build_activity_payload(
      details: "Playing as Rat King",
      hero_data: hero,
      state: "Standard Match - 05:10",
      start_time: 1_700_000_000,
      party_size: nil,
      img_cfg: img_cfg,
      statlocker_account_id: 12_345_678,
      show_statlocker_button: true
    )

    assert_equal "Playing as Rat King", payload["details"]
    assert_equal "Standard Match - 05:10", payload["state"]
    assert_equal "https://assets.deadlock-api.com/heroes/ratking.png", payload.dig("assets", "large_image")
    assert_equal "Rat King", payload.dig("assets", "large_text")
    assert_equal "deadlock_logo", payload.dig("assets", "small_image")
    assert_equal "RubyLock RPC", payload.dig("assets", "small_text")
    assert_equal "https://statlocker.gg/profile/12345678/matches", payload.dig("buttons", 0, "url")
  end

  def test_process_watcher_native_snapshot
    # Verify native process enumeration works without spawning tasklist/console windows.
    expected_self = Gem.win_platform? ? "ruby.exe" : "ruby"
    assert_equal true, RubylockRpc::ProcessWatcher.process_running?(expected_self)
    assert_equal false, RubylockRpc::ProcessWatcher.process_running?("definitely_not_a_real_process_99999.exe")
  end
end
