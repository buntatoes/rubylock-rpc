# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "json"
require "net/http"
require "uri"
require_relative "config"
require_relative "logger"

module RubylockRpc
  HeroData = Struct.new(:name, :hideout_text, :icon_url, keyword_init: true)

  class HeroCache
    STATIC_FALLBACK = {
      "hero_abrams"            => "Abrams",
      "hero_atlas"             => "Abrams",
      "hero_fencer"            => "Apollo",
      "hero_baba"              => "Baba",
      "hero_bebop"             => "Bebop",
      "hero_punkgoat"          => "Billy",
      "hero_nano"              => "Calico",
      "hero_unicorn"           => "Celeste",
      "hero_deadpack"          => "Deadman Danny",
      "hero_drifter"           => "Drifter",
      "hero_dynamo"            => "Dynamo",
      "hero_necro"             => "Graves",
      "hero_archer"            => "Grey Talon",
      "hero_orion"             => "Grey Talon",
      "hero_haze"              => "Haze",
      "hero_astro"             => "Holliday",
      "hero_inferno"           => "Infernus",
      "hero_ivy"               => "Ivy",
      "hero_tengu"             => "Ivy",
      "hero_kelvin"            => "Kelvin",
      "hero_geist"             => "Lady Geist",
      "hero_ghost"             => "Lady Geist",
      "hero_lash"              => "Lash",
      "hero_mcginnis"          => "McGinnis",
      "hero_forge"             => "McGinnis",
      "hero_vampirebat"        => "Mina",
      "hero_mirage"            => "Mirage",
      "hero_digger"            => "Mo & Krill",
      "hero_krill"             => "Mo & Krill",
      "hero_nurse"             => "Nurse Harrow",
      "hero_bookworm"          => "Paige",
      "hero_chrono"            => "Paradox",
      "hero_pocket"            => "Pocket",
      "hero_synth"             => "Pocket",
      "hero_ratking"           => "Rat King",
      "hero_familiar"          => "Rem",
      "hero_gigawatt_prisoner" => "Seven",
      "hero_gigawatt"          => "Seven",
      "hero_shiv"              => "Shiv",
      "hero_werewolf"          => "Silver",
      "hero_magician"          => "Sinclair",
      "hero_chessmaster"       => "Solomon",
      "hero_doorman"           => "The Doorman",
      "hero_priest"            => "Venator",
      "hero_frank"             => "Victor",
      "hero_hornet"            => "Vindicta",
      "hero_artist"            => "Violet",
      "hero_viscous"           => "Viscous",
      "hero_viper"             => "Vyper",
      "hero_warden"            => "Warden",
      "hero_wraith"            => "Wraith",
      "hero_yamato"            => "Yamato"
    }.freeze

    attr_reader :portrait_style

    def self.static_fallback(hero_key)
      STATIC_FALLBACK[hero_key.to_s]
    end

    def initialize(portrait_style = HeroPortraitStyle::NORMAL)
      @portrait_style = portrait_style
      @cache = {}
    end

    def portrait_style=(new_style)
      return if @portrait_style == new_style

      @portrait_style = new_style
      @cache.clear
    end

    def get_or_fetch(hero_key)
      key = hero_key.to_s
      return @cache[key] if @cache.key?(key)

      data = fetch(key)
      if data
        RpcLogger.info("[api] Cached #{key}: \"#{data.name}\"")
        @cache[key] = data
      end
      data
    end

    private

    def fetch(hero_key)
      stripped = hero_key.sub(/\Ahero_/, "")
      candidates = [hero_key, stripped, self.class.static_fallback(hero_key)].compact.uniq
      candidates.each do |candidate|
        data = fetch_by_name(hero_key, candidate)
        return data if data
      end

      if (fallback_name = self.class.static_fallback(hero_key))
        return HeroData.new(name: fallback_name, hideout_text: "", icon_url: "")
      end

      RpcLogger.warn("[api] Failed to fetch #{hero_key}")
      nil
    end

    def fetch_by_name(hero_key, name)
      encoded = name.gsub(" ", "%20").gsub("&", "%26")
      uri = URI.parse("https://api.deadlock-api.com/v1/assets/heroes/by-name/#{encoded}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      res = http.get(uri.request_uri)
      return nil unless res.is_a?(Net::HTTPSuccess)

      hero = JSON.parse(res.body)
      images = hero["images"]
      return nil unless images.is_a?(Hash)

      icon_url = select_icon_url(hero_key, images)
      HeroData.new(
        name: hero["name"] || hero_key.sub(/\Ahero_/, ""),
        hideout_text: hero["hideout_rich_presence"].to_s,
        icon_url: icon_url.to_s
      )
    rescue StandardError => e
      RpcLogger.debug("[api] Lookup \"#{name}\" for #{hero_key} failed: #{e.message}")
      nil
    end

    def select_icon_url(hero_key, images)
      normal = images["icon_hero_card"].to_s
      case @portrait_style
      when HeroPortraitStyle::GLOAT
        gloat = images["hero_card_gloat"].to_s
        gloat.empty? ? normal : gloat
      when HeroPortraitStyle::CRITICAL
        crit = images["hero_card_critical"].to_s
        crit.empty? ? normal : crit
      when HeroPortraitStyle::ICON
        icon = images["icon_image_small"].to_s
        icon.empty? ? normal : icon
      when HeroPortraitStyle::FULLBODY
        hero_key
      else
        normal
      end
    end
  end
end
