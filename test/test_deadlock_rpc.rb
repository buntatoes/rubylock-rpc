# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/deadlock_rpc"

class TestDeadlockRpc < Minitest::Test
  def test_toml_parse_and_dump
    parsed = DeadlockRpc::Toml.parse(DeadlockRpc::ConfigManager::DEFAULT_TOML)
    assert_equal true, parsed.dig("general", "launch_game_on_start")
    assert_equal 500, parsed.dig("general", "game_log_poll_interval_ms")
    assert_equal 4, parsed.dig("general", "config_version")
    assert_equal "Playing as {hero}", parsed.dig("presence", "details_with_hero")
    assert_equal "Browsing the Main Menu", parsed.dig("presence", "status", "in_main_menu")
    assert_equal "deadlock_logo", parsed.dig("images", "fallback_large_image")

    dumped = DeadlockRpc::Toml.dump(parsed)
    reparsed = DeadlockRpc::Toml.parse(dumped)
    assert_equal parsed, reparsed
  end

  def test_config_migration_and_vars
    Dir.mktmpdir do |dir|
      cfg_file = File.join(dir, "config.toml")
      File.write(cfg_file, "[general]\nconfig_version = 1\nlaunch_game_on_start = false\n")
      cfg = DeadlockRpc::ConfigManager.load(cfg_file)
      assert_equal false, cfg.general.launch_game_on_start
      assert_equal 4, cfg.general.config_version
      assert_equal "Playing as {hero}", cfg.presence.details_with_hero
    end

    rendered = DeadlockRpc::ConfigManager.apply_vars("Playing as {hero} in {mode}", hero: "Haze", mode: "Standard Match")
    assert_equal "Playing as Haze in Standard Match", rendered
  end

  def test_hero_key_normalization_and_static_fallback
    assert_equal "hero_inferno", DeadlockRpc::LogWatcher.normalize_hero_key("hero_inferno_v2")
    assert_equal "hero_ratking", DeadlockRpc::LogWatcher.normalize_hero_key("ratking")
    assert_equal "Infernus", DeadlockRpc::HeroCache.static_fallback("hero_inferno")
    assert_equal "Rat King", DeadlockRpc::HeroCache.static_fallback("hero_ratking")
    assert_equal "Mo & Krill", DeadlockRpc::HeroCache.static_fallback("hero_krill")
  end

  def test_log_watcher_state_machine
    state = DeadlockRpc::GameState.new
    state.enter_main_menu
    assert_equal DeadlockRpc::GamePhase::MAIN_MENU, state.phase

    # Enter hideout and load hero
    DeadlockRpc::LogWatcher.process_line('[Client] Map: "dl_hideout"', state)
    assert_equal DeadlockRpc::GamePhase::HIDEOUT, state.phase
    DeadlockRpc::LogWatcher.process_line("[HostStateManager] Host activate: (dl_hideout)", state)
    assert_equal true, state.hideout_loaded

    DeadlockRpc::LogWatcher.process_line("[Server] Loaded hero 1/hero_ratking_v2", state)
    assert_equal "hero_ratking", state.hero_key

    # Account ID and party events
    DeadlockRpc::LogWatcher.process_line("User [U:1:12345678] connected", state)
    assert_equal 12_345_678, state.local_account_id

    DeadlockRpc::LogWatcher.process_line("[Client] Players: 3 (0 bots) / 3 humans", state)
    assert_equal 3, state.party_size

    # Start and stop matchmaking
    DeadlockRpc::LogWatcher.process_line("k_EMsgClientToGCStartMatchmaking", state)
    assert_equal DeadlockRpc::GamePhase::IN_QUEUE, state.phase
    DeadlockRpc::LogWatcher.process_line("k_EMsgClientToGCStopMatchmaking", state)
    assert_equal DeadlockRpc::GamePhase::HIDEOUT, state.phase

    # Enter match on dl_midtown with 12 players -> Standard Match
    DeadlockRpc::LogWatcher.process_line("Lobby 100 for Match 200 created", state)
    assert_equal DeadlockRpc::GamePhase::MATCH_INTRO, state.phase
    DeadlockRpc::LogWatcher.process_line("[Client] Created physics for dl_midtown", state)
    assert_equal DeadlockRpc::GamePhase::IN_MATCH, state.phase
    DeadlockRpc::LogWatcher.process_line("[Client] Players: 12 (0 bots) / 12 humans", state)
    assert_equal DeadlockRpc::MatchMode::STANDARD, state.match_mode

    # Hero lock-in during standard match
    DeadlockRpc::LogWatcher.process_line("VMDL Camera Pose Success! models/heroes/haze/haze.vmdl", state)
    assert_equal "hero_haze", state.hero_key
    DeadlockRpc::LogWatcher.process_line("VMDL Camera Pose Success! models/heroes/bebop/bebop.vmdl", state)
    assert_equal "hero_haze", state.hero_key

    # Match start timer & postgame
    DeadlockRpc::LogWatcher.process_line("ChangeGameState: GameInProgress (7)", state)
    refute_nil state.match_started_at
    assert_equal "07:42", DeadlockRpc::GameState.format_match_elapsed(462)
    assert_equal "1:01:05", DeadlockRpc::GameState.format_match_elapsed(3665)

    DeadlockRpc::LogWatcher.process_line("Lobby 100 for Match 200 destroyed", state)
    assert_equal DeadlockRpc::GamePhase::POST_MATCH, state.phase
  end

  def test_discord_activity_payload
    img_cfg = DeadlockRpc::ImagesConfig.new
    hero = DeadlockRpc::HeroData.new(
      name: "Rat King",
      hideout_text: "Wishing The Hideout Was On Long Island",
      icon_url: "https://assets.deadlock-api.com/heroes/ratking.png"
    )

    payload = DeadlockRpc::DiscordIpcClient.build_activity_payload(
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
    assert_equal "https://statlocker.gg/profile/12345678/matches", payload.dig("buttons", 0, "url")
  end
end
