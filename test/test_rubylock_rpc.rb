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
    assert_equal 6, parsed.dig("general", "config_version")
    assert_equal "Playing as {hero}", parsed.dig("presence", "details_with_hero")
    assert_equal "Browsing the Main Menu", parsed.dig("presence", "status", "in_main_menu")
    assert_equal RubylockRpc::DEFAULT_ICON_URL, parsed.dig("images", "fallback_large_image")
    assert_equal RubylockRpc::DEFAULT_ICON_URL, parsed.dig("images", "corner_image")
    assert_equal "RubyLock RPC", parsed.dig("images", "fallback_large_image_tooltip")

    dumped = RubylockRpc::Toml.dump(parsed)
    reparsed = RubylockRpc::Toml.parse(dumped)
    assert_equal parsed, reparsed
  end

  def test_config_migration_and_vars
    Dir.mktmpdir do |dir|
      cfg_file = File.join(dir, "config.toml")
      File.write(
        cfg_file,
        "[general]\nconfig_version = 4\nlaunch_game_on_start = false\n" \
        "[images]\nfallback_large_image = \"deadlock_logo\"\ncorner_image = \"deadlock_logo\"\n"
      )
      cfg = RubylockRpc::ConfigManager.load(cfg_file)
      assert_equal false, cfg.general.launch_game_on_start
      assert_equal 6, cfg.general.config_version
      assert_equal nil, cfg.general.discord_app_id
      assert_equal RubylockRpc::DEFAULT_ICON_URL, cfg.images.fallback_large_image
      assert_equal RubylockRpc::DEFAULT_ICON_URL, cfg.images.corner_image
      assert_equal "Playing as {hero}", cfg.presence.details_with_hero
    end

    Dir.mktmpdir do |dir|
      cfg_file = File.join(dir, "config.toml")
      File.write(cfg_file, "[general]\nconfig_version = 6\ndiscord_app_id = \"123456789012345678\"\n[images]\ncorner_image = \"\"\n")
      cfg = RubylockRpc::ConfigManager.load(cfg_file)
      assert_equal "123456789012345678", cfg.general.discord_app_id
      assert_equal "", cfg.images.corner_image
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
    assert_equal RubylockRpc::DEFAULT_ICON_URL, payload.dig("assets", "small_image")
    assert_equal "RubyLock RPC", payload.dig("assets", "small_text")
    assert_equal "https://statlocker.gg/profile/12345678/matches", payload.dig("buttons", 0, "url")

    hidden_corner_cfg = RubylockRpc::ImagesConfig.new(corner_image: "")
    hidden_payload = RubylockRpc::DiscordIpcClient.build_activity_payload(
      details: "Playing as Rat King",
      hero_data: hero,
      state: "Standard Match - 05:10",
      start_time: 1_700_000_000,
      party_size: nil,
      img_cfg: hidden_corner_cfg
    )
    assert_equal nil, hidden_payload.dig("assets", "small_image")
    assert_equal nil, hidden_payload.dig("assets", "small_text")
  end

  def test_process_watcher_native_snapshot
    # Verify native process enumeration works without spawning tasklist/console windows.
    expected_self = Gem.win_platform? ? "ruby.exe" : "ruby"
    assert_equal true, RubylockRpc::ProcessWatcher.process_running?(expected_self)
    assert_equal false, RubylockRpc::ProcessWatcher.process_running?("definitely_not_a_real_process_99999.exe")
  end

  def test_updater_version_asset_and_url_checks
    assert_equal [1, 3, 0], RubylockRpc::Updater.parse_version("v1.3.0")
    assert_equal [1, 2, 0], RubylockRpc::Updater.parse_version("1.2")
    assert_equal nil, RubylockRpc::Updater.parse_version("v1.3.0-rc1")
    assert_equal true, RubylockRpc::Updater.newer_version?("v1.3.0", "1.2.0")
    assert_equal true, RubylockRpc::Updater.newer_version?("v2.0.0", "1.9.9")
    assert_equal false, RubylockRpc::Updater.newer_version?("v1.3.0", "1.3.0")
    assert_equal false, RubylockRpc::Updater.newer_version?("v1.2.9", "1.3.0")

    assets = [
      { "name" => "RubyLock-RPC-Setup-v1.3.0-win64.exe", "browser_download_url" => "https://github.com/buntatoes/rubylock-rpc/releases/download/v1.3.0/RubyLock-RPC-Setup-v1.3.0-win64.exe" },
      { "name" => "rubylock-rpc-linux-x86_64.tar.gz", "browser_download_url" => "https://github.com/buntatoes/rubylock-rpc/releases/download/v1.3.0/rubylock-rpc-linux-x86_64.tar.gz" }
    ]
    assert_equal "RubyLock-RPC-Setup-v1.3.0-win64.exe", RubylockRpc::Updater.select_asset(assets, win_platform: true)["name"]
    assert_equal "rubylock-rpc-linux-x86_64.tar.gz", RubylockRpc::Updater.select_asset(assets, win_platform: false)["name"]

    assert_equal true, RubylockRpc::Updater.trusted_download_url?("https://github.com/buntatoes/rubylock-rpc/releases/download/v1.3.0/rubylock-rpc-linux-x86_64.tar.gz")
    assert_equal true, RubylockRpc::Updater.trusted_download_url?("https://objects.githubusercontent.com/some/asset")
    assert_equal false, RubylockRpc::Updater.trusted_download_url?("http://github.com/buntatoes/rubylock-rpc")
    assert_equal false, RubylockRpc::Updater.trusted_download_url?("https://evil.example.com/payload.exe")
  end

  def test_updater_safe_tar_extraction
    require "stringio"
    require "rubygems/package"
    require "zlib"

    Dir.mktmpdir do |dir|
      good_tgz = File.join(dir, "good.tar.gz")
      File.open(good_tgz, "wb") do |f|
        Zlib::GzipWriter.wrap(f) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            tar.add_file_simple("pkg/hello.txt", 0o644, 5) { |io| io.write("hello") }
          end
        end
      end
      out_dir = File.join(dir, "out")
      RubylockRpc::Updater.extract_tar_gz(good_tgz, out_dir)
      assert_equal "hello", File.read(File.join(out_dir, "pkg", "hello.txt"))

      bad_tgz = File.join(dir, "bad.tar.gz")
      File.open(bad_tgz, "wb") do |f|
        Zlib::GzipWriter.wrap(f) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            tar.add_file_simple("../escape.txt", 0o644, 4) { |io| io.write("nope") }
          end
        end
      end
      raised = false
      begin
        RubylockRpc::Updater.extract_tar_gz(bad_tgz, File.join(dir, "bad_out"))
      rescue StandardError
        raised = true
      end
      assert_equal true, raised
    end
  end

  def test_dbus_wire_message_roundtrip
    require "stringio"
    wire = RubylockRpc::Tray::DbusWire
    msg_bytes = wire.encode_message(
      type: wire::MSG_METHOD_RETURN,
      serial: 42,
      headers: [
        [wire::HDR_REPLY_SERIAL, wire.v("u", 7)],
        [wire::HDR_DESTINATION, wire.v("s", ":1.99")]
      ],
      body_sig: "u(ia{sv}av)",
      body_args: [
        3,
        [
          0,
          { "children-display" => wire.v("s", "submenu") },
          [
            wire.v("(ia{sv}av)", [1, { "label" => wire.v("s", "RubyLock RPC"), "enabled" => wire.v("b", true) }, []])
          ]
        ]
      ]
    )
    decoded = wire.read_message(StringIO.new(msg_bytes))
    assert_equal wire::MSG_METHOD_RETURN, decoded[:type]
    assert_equal 42, decoded[:serial]
    assert_equal 7, decoded[:reply_serial]
    assert_equal ":1.99", decoded[:destination]
    assert_equal 3, decoded[:args][0]
    assert_equal "submenu", decoded[:args][1][1]["children-display"]
    assert_equal "RubyLock RPC", decoded[:args][1][2][0][1]["label"]
  end
end
