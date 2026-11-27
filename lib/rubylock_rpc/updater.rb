# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "fileutils"
require "json"
require "net/http"
require "open3"
require "rubygems/package"
require "tmpdir"
require "uri"
require "zlib"
require_relative "logger"

module RubylockRpc
  # Pure-Ruby GitHub Releases auto-updater (zero external gems).
  # Checks https://api.github.com/repos/buntatoes/rubylock-rpc/releases/latest
  # and downloads/installs the matching Windows (.exe) or Linux (.tar.gz) package.
  module Updater
    GITHUB_REPO        = "buntatoes/rubylock-rpc"
    LATEST_RELEASE_URL = "https://api.github.com/repos/#{GITHUB_REPO}/releases/latest"
    HTTP_TIMEOUT_S     = 8
    MAX_REDIRECTS      = 5
    TRUSTED_HOSTS      = [
      "github.com",
      "api.github.com",
      "objects.githubusercontent.com",
      "release-assets.githubusercontent.com",
      "github-releases.githubusercontent.com",
      "codeload.github.com"
    ].freeze

    ReleaseInfo = Struct.new(:version, :tag_name, :html_url, :asset_name, :asset_url, keyword_init: true)

    if Gem.win_platform?
      require "fiddle"
      require "fiddle/import"

      module Win32Dialog
        extend Fiddle::Importer
        dlload "user32.dll"

        MB_OK              = 0x00000000
        MB_YESNO           = 0x00000004
        MB_ICONERROR       = 0x00000010
        MB_ICONINFORMATION = 0x00000040
        IDYES              = 6

        extern "int MessageBoxW(void*, void*, void*, unsigned int)"
      end
    end

    module_function

    def parse_version(str)
      cleaned = str.to_s.strip.sub(/\A[vV]/, "")
      return nil if cleaned.empty? || cleaned.include?("-")

      m = /\A(\d+)\.(\d+)(?:\.(\d+))?\z/.match(cleaned)
      return nil unless m

      [m[1].to_i, m[2].to_i, (m[3] || 0).to_i]
    end

    def newer_version?(remote_tag, current_version = RubylockRpc::VERSION)
      remote = parse_version(remote_tag)
      current = parse_version(current_version)
      return false unless remote && current

      (remote <=> current) == 1
    end

    def trusted_download_url?(url_str)
      uri = URI.parse(url_str.to_s)
      uri.is_a?(URI::HTTPS) && TRUSTED_HOSTS.include?(uri.host.to_s.downcase)
    rescue URI::InvalidURIError
      false
    end

    def select_asset(assets, win_platform: Gem.win_platform?)
      return nil unless assets.is_a?(Array)

      if win_platform
        assets.find { |a| a["name"].to_s.match?(/\ARubyLock-RPC-Setup-.*\.exe\z/i) } ||
          assets.find { |a| a["name"].to_s.match?(/\.exe\z/i) }
      else
        assets.find { |a| a["name"].to_s.match?(/\Arubylock-rpc-linux-x86_64\.tar\.gz\z/i) } ||
          assets.find { |a| a["name"].to_s.match?(/linux.*\.tar\.gz\z/i) }
      end
    end

    def check_latest(current_version: RubylockRpc::VERSION, win_platform: Gem.win_platform?)
      body = http_get_body(
        LATEST_RELEASE_URL,
        headers: {
          "Accept"     => "application/vnd.github+json",
          "User-Agent" => "rubylock-rpc/#{current_version}"
        }
      )
      return nil unless body

      data = JSON.parse(body)
      return nil if data["draft"] || data["prerelease"]

      tag = data["tag_name"].to_s
      return nil unless newer_version?(tag, current_version)

      asset = select_asset(data["assets"], win_platform: win_platform)
      asset_url = asset ? asset["browser_download_url"].to_s : ""
      return nil unless trusted_download_url?(asset_url)

      ReleaseInfo.new(
        version: tag.sub(/\A[vV]/, ""),
        tag_name: tag,
        html_url: data["html_url"].to_s,
        asset_name: asset["name"].to_s,
        asset_url: asset_url
      )
    rescue StandardError => e
      RpcLogger.debug("[updater] Check failed: #{e.message}")
      nil
    end

    def check_and_apply(auto_update:, current_version: RubylockRpc::VERSION, silent: false, &on_before_exit)
      release = check_latest(current_version: current_version)
      return :up_to_date unless release

      RpcLogger.info("[updater] New release available: #{release.tag_name} (current: v#{current_version})")

      proceed = if auto_update
                  true
                else
                  prompt_user_for_update(release, current_version: current_version)
                end
      return :declined unless proceed

      result = install_update(release, silent: silent || auto_update)
      if result == :launched_installer
        on_before_exit&.call
      end
      result
    rescue StandardError => e
      RpcLogger.warn("[updater] Update failed: #{e.message}")
      notify_user("RubyLock RPC Update Failed", "Could not install #{release&.tag_name || 'update'}: #{e.message}", error: true) unless silent
      :failed
    end

    def install_update(release, silent: false)
      raise "Untrusted download URL" unless trusted_download_url?(release.asset_url)

      if Gem.win_platform?
        setup_path = File.join(Dir.tmpdir, release.asset_name)
        download_asset(release.asset_url, setup_path)
        verify_magic_bytes!(setup_path, "MZ")

        RpcLogger.info("[updater] Launching Windows installer #{release.asset_name} --silent")
        pid = Process.spawn(setup_path, "--silent")
        Process.detach(pid)
        :launched_installer
      else
        Dir.mktmpdir("rubylock-update") do |tmp|
          archive_path = File.join(tmp, release.asset_name)
          download_asset(release.asset_url, archive_path)
          verify_magic_bytes!(archive_path, "\x1f\x8b".b)

          extract_dir = File.join(tmp, "extracted")
          extract_tar_gz(archive_path, extract_dir)

          installer = Dir.glob(File.join(extract_dir, "*", "install.sh")).first ||
                      File.join(extract_dir, "install.sh")
          raise "install.sh not found in release archive" unless installer && File.exist?(installer)

          prefix = detect_linux_install_prefix
          RpcLogger.info("[updater] Installing #{release.tag_name} to #{prefix}...")
          env = { "PREFIX" => prefix }
          stdout, stderr, status = Open3.capture3(env, "sh", installer, "--silent")
          unless status.success?
            raise "install.sh exited with status #{status.exitstatus}: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
          end

          RpcLogger.info("[updater] Updated RubyLock RPC to #{release.tag_name}.")
          unless silent
            notify_user(
              "RubyLock RPC Updated",
              "RubyLock RPC has been updated to #{release.tag_name}.\nRestart RubyLock RPC to use the new version."
            )
          end
          :installed
        end
      end
    end

    def extract_tar_gz(tar_gz_path, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      root = File.expand_path(dest_dir)
      root_prefix = "#{root}#{File::SEPARATOR}"

      Zlib::GzipReader.open(tar_gz_path) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            rel = entry.full_name.to_s
            raise "Unsafe archive entry: #{rel}" if rel.start_with?("/") || rel.split("/").include?("..")

            target = File.expand_path(rel, root)
            raise "Path traversal detected: #{rel}" unless target.start_with?(root_prefix)

            if entry.directory?
              FileUtils.mkdir_p(target)
            elsif entry.file?
              FileUtils.mkdir_p(File.dirname(target))
              File.binwrite(target, entry.read.to_s)
              mode = entry.header.mode.to_i & 0o777
              File.chmod(mode, target) if mode.positive? && !Gem.win_platform?
            end
          end
        end
      end
    end

    def detect_linux_install_prefix(app_root = File.expand_path("../..", __dir__))
      expanded = File.expand_path(app_root)
      if expanded.end_with?("/share/rubylock-rpc")
        File.dirname(File.dirname(expanded))
      else
        ENV["PREFIX"] || File.join(Dir.home, ".local")
      end
    end

    def prompt_user_for_update(release, current_version: RubylockRpc::VERSION)
      msg = "RubyLock RPC #{release.tag_name} is available (you have v#{current_version}).\n\nDownload and install now?"
      if Gem.win_platform?
        win32_message_box("RubyLock RPC Update", msg, Win32Dialog::MB_YESNO | Win32Dialog::MB_ICONINFORMATION) == Win32Dialog::IDYES
      elsif linux_gui_session?
        if command_exists?("zenity")
          system(
            "zenity", "--question",
            "--title=RubyLock RPC Update",
            "--ok-label=Update Now",
            "--cancel-label=Later",
            "--text=#{msg}"
          )
          $?.success?
        elsif command_exists?("kdialog")
          system("kdialog", "--title", "RubyLock RPC Update", "--yesno", msg)
          $?.success?
        elsif command_exists?("notify-send")
          system(
            "notify-send",
            "RubyLock RPC #{release.tag_name} Available",
            "Run 'rubylock-rpc --update' to install the latest release."
          )
          false
        else
          false
        end
      else
        false
      end
    rescue StandardError
      false
    end

    def notify_user(title, msg, error: false)
      if Gem.win_platform?
        flags = Win32Dialog::MB_OK | (error ? Win32Dialog::MB_ICONERROR : Win32Dialog::MB_ICONINFORMATION)
        win32_message_box(title, msg, flags)
      elsif linux_gui_session?
        if command_exists?("zenity")
          kind = error ? "--error" : "--info"
          system("zenity", kind, "--title=#{title}", "--text=#{msg}")
        elsif command_exists?("kdialog")
          kind = error ? "--error" : "--msgbox"
          system("kdialog", "--title", title, kind, msg)
        elsif command_exists?("notify-send")
          system("notify-send", title, msg)
        end
      end
    rescue StandardError
      nil
    end

    def download_asset(url, dest_path)
      current_url = url
      MAX_REDIRECTS.times do
        raise "Untrusted redirect URL: #{current_url}" unless trusted_download_url?(current_url)

        uri = URI.parse(current_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = HTTP_TIMEOUT_S
        http.read_timeout = 60

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = "rubylock-rpc/#{RubylockRpc::VERSION}"

        redirect_target = nil
        http.request(req) do |res|
          if res.is_a?(Net::HTTPRedirection) && res["location"]
            redirect_target = URI.join(current_url, res["location"]).to_s
          elsif res.is_a?(Net::HTTPSuccess)
            File.open(dest_path, "wb") do |f|
              res.read_body { |chunk| f.write(chunk) }
            end
            raise "Downloaded empty file" if File.size(dest_path).zero?

            return dest_path
          else
            raise "HTTP #{res.code} downloading #{uri.host}"
          end
        end

        current_url = redirect_target if redirect_target
      end
      raise "Too many redirects while downloading update"
    end

    def http_get_body(url, headers: {})
      current_url = url
      MAX_REDIRECTS.times do
        raise "Untrusted URL: #{current_url}" unless trusted_download_url?(current_url)

        uri = URI.parse(current_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = HTTP_TIMEOUT_S
        http.read_timeout = HTTP_TIMEOUT_S

        req = Net::HTTP::Get.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }

        res = http.request(req)
        if res.is_a?(Net::HTTPRedirection) && res["location"]
          current_url = URI.join(current_url, res["location"]).to_s
        elsif res.is_a?(Net::HTTPSuccess)
          return res.body
        else
          return nil
        end
      end
      nil
    end

    def verify_magic_bytes!(path, expected_bytes)
      actual = File.binread(path, expected_bytes.bytesize)
      raise "Downloaded package failed header verification" unless actual == expected_bytes
    end

    def linux_gui_session?
      !Gem.win_platform? && (!ENV["DISPLAY"].to_s.empty? || !ENV["WAYLAND_DISPLAY"].to_s.empty?)
    end

    def command_exists?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        candidate = File.join(dir, name)
        File.file?(candidate) && File.executable?(candidate)
      end
    end

    def win32_message_box(title, text, flags)
      w_text  = "#{text}\0".encode("UTF-16LE")
      w_title = "#{title}\0".encode("UTF-16LE")
      Win32Dialog.MessageBoxW(nil, Fiddle::Pointer[w_text], Fiddle::Pointer[w_title], flags)
    end
  end
end
