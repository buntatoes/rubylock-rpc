# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only
#
# Builds the distributable packages for RubyLock RPC:
#   1. Windows Setup Installer: dist/RubyLock-RPC-Setup-v<version>-win64.exe
#      (installs rubylock-rpc.exe + Ruby core to %LOCALAPPDATA%\RubyLock-RPC
#       and creates a Desktop shortcut to launch Deadlock through RubyLock RPC)
#   2. Linux release bundle:    dist/rubylock-rpc-linux-x86_64.tar.gz

require "fileutils"
require "rubygems/package"
require "tmpdir"
require "zlib"
require_relative "../lib/rubylock_rpc"

ROOT_DIR = File.expand_path("..", __dir__)
DIST_DIR = File.join(ROOT_DIR, "dist")

module Packager
  module_function

  def build_all(target = :all)
    FileUtils.mkdir_p(DIST_DIR)
    build_windows_installer(required: target != :all) if [:all, :windows, :exe].include?(target)
    build_linux_tarball if [:all, :linux].include?(target)
  end

  def find_tool(binary_name, extra_globs = [])
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, binary_name)
      return candidate if File.exist?(candidate)
    end
    extra_globs.each do |pattern|
      matches = Dir.glob(pattern).sort.reverse
      return matches.first unless matches.empty?
    end
    nil
  end

  def release_version
    "v#{RubylockRpc::VERSION}"
  end

  def collect_ruby_files
    Dir.glob(File.join(ROOT_DIR, "lib", "**", "*.rb")).sort.map do |abs|
      abs.sub("#{ROOT_DIR}/", "").tr("\\", "/")
    end
  end

  def build_windows_installer(required: true)
    if Gem.win_platform?
      gcc = find_tool("gcc.exe", [
        "C:/Ruby*-x64/msys64/ucrt64/bin/gcc.exe",
        "C:/msys64/ucrt64/bin/gcc.exe"
      ])
      raise "gcc.exe not found for compiling Windows executables" unless gcc

      windres = find_tool("windres.exe", [
        "C:/Ruby*-x64/msys64/ucrt64/bin/windres.exe",
        "C:/msys64/ucrt64/bin/windres.exe"
      ])
      raise "windres.exe not found for embedding Windows icon and payload resources" unless windres

      gcc_bin_dir = File.dirname(gcc)
      env = { "PATH" => "#{gcc_bin_dir};#{ENV['PATH']}" }
    else
      gcc = find_tool("x86_64-w64-mingw32-gcc")
      windres = find_tool("x86_64-w64-mingw32-windres")
      unless gcc && windres
        if required
          raise "x86_64-w64-mingw32-gcc and x86_64-w64-mingw32-windres are required to cross-compile Windows executables"
        end
        puts "[package] Skipping Windows .exe installer build on non-Windows host (MinGW-w64 toolchain not found)"
        return
      end
      env = {}
    end

    Dir.mktmpdir("rubylock-rpc-win64") do |stage|
      prefix_flags = [
        "-ffile-prefix-map=#{ROOT_DIR}=.",
        "-ffile-prefix-map=#{stage}=."
      ]

      icon_src = File.join(ROOT_DIR, "assets", "icon.ico")
      host_rc  = File.join(stage, "host.rc")
      host_res = File.join(stage, "host.res.o")
      File.write(host_rc, "1 ICON \"#{icon_src.tr('\\', '/')}\"\n")
      raise "windres failed for host icon" unless system(env, windres, host_rc, "-O", "coff", "-o", host_res)

      # 1. Build rubylock-rpc.exe (native GUI host executable)
      host_src = File.join(ROOT_DIR, "packaging", "host", "rubylock_rpc_host.c")
      host_exe = File.join(stage, "rubylock-rpc.exe")
      ok = system(
        env, gcc, "-O2", "-Wall", "-Wextra", "-s", "-static-libgcc", "-mwindows",
        *prefix_flags, host_src, host_res, "-o", host_exe
      )
      raise "Failed to compile rubylock-rpc.exe" unless ok

      # 2. Pack embedded RLPC payload archive
      payload_entries = [
        ["rubylock-rpc.exe", File.binread(host_exe)],
        ["LICENSE", File.binread(File.join(ROOT_DIR, "LICENSE"))],
        ["README.md", File.binread(File.join(ROOT_DIR, "README.md"))],
        ["bin/rubylock-rpc", File.binread(File.join(ROOT_DIR, "bin", "rubylock-rpc"))],
        ["assets/icon.ico", File.binread(File.join(ROOT_DIR, "assets", "icon.ico"))],
        ["assets/icon.png", File.binread(File.join(ROOT_DIR, "assets", "icon.png"))]
      ]
      collect_ruby_files.each do |rel|
        payload_entries << [rel, File.binread(File.join(ROOT_DIR, rel))]
      end

      payload_bin = File.join(stage, "payload.bin")
      File.open(payload_bin, "wb") do |f|
        f.write("RLPC")
        f.write([payload_entries.size].pack("V"))
        payload_entries.each do |rel_path, data|
          path_bytes = rel_path.encode("UTF-8")
          f.write([path_bytes.bytesize, data.bytesize].pack("V2"))
          f.write(path_bytes)
          f.write(data)
        end
      end

      # 3. Compile unified Setup/Uninstall installer executable
      setup_rc  = File.join(stage, "setup.rc")
      setup_res = File.join(stage, "setup.res.o")
      File.write(
        setup_rc,
        "1 ICON \"#{icon_src.tr('\\', '/')}\"\n" \
        "101 RCDATA \"#{payload_bin.tr('\\', '/')}\"\n"
      )
      raise "windres failed for installer resources" unless system(env, windres, setup_rc, "-O", "coff", "-o", setup_res)

      installer_src = File.join(ROOT_DIR, "packaging", "windows", "installer.c")
      setup_exe_out = File.join(DIST_DIR, "RubyLock-RPC-Setup-#{release_version}-win64.exe")
      FileUtils.rm_f(setup_exe_out)
      ok = system(
        env,
        gcc, "-O2", "-Wall", "-Wextra", "-s", "-static-libgcc", "-mwindows",
        *prefix_flags, installer_src, setup_res,
        "-lole32", "-lshell32", "-luuid", "-ladvapi32",
        "-o", setup_exe_out
      )
      raise "Failed to compile Windows installer executable" unless ok

      puts "[package] Built Windows Setup EXE: #{setup_exe_out} (#{File.size(setup_exe_out)} bytes)"
    end
  end

  def build_linux_tarball
    tar_gz_out = File.join(DIST_DIR, "rubylock-rpc-linux-x86_64.tar.gz")
    FileUtils.rm_f(tar_gz_out)

    prefix = "rubylock-rpc-linux-x86_64"
    files_to_pack = [
      ["LICENSE", 0o644],
      ["README.md", 0o644],
      ["Rakefile", 0o644],
      ["rubylock-rpc.gemspec", 0o644],
      ["bin/rubylock-rpc", 0o755],
      ["packaging/linux/install.sh", 0o755],
      ["packaging/linux/uninstall.sh", 0o755],
      ["packaging/linux/rubylock-rpc.desktop", 0o644],
      ["packaging/host/rubylock_rpc_host.c", 0o644],
      ["assets/icon.png", 0o644],
      ["assets/icon.ico", 0o644]
    ]

    collect_ruby_files.each do |rel|
      files_to_pack << [rel, 0o644]
    end

    linux_elf = nil
    if !Gem.win_platform? && (gcc = find_tool("gcc"))
      linux_elf = File.join(DIST_DIR, "rubylock-rpc-elf")
      host_src = File.join(ROOT_DIR, "packaging", "host", "rubylock_rpc_host.c")
      ok = system(
        gcc, "-O2", "-Wall", "-Wextra", "-s",
        "-ffile-prefix-map=#{ROOT_DIR}=.",
        host_src, "-o", linux_elf
      )
      raise "Failed to compile Linux rubylock-rpc host binary" unless ok
    end

    File.open(tar_gz_out, "wb") do |file|
      Zlib::GzipWriter.wrap(file) do |gz|
        Gem::Package::TarWriter.new(gz) do |tar|
          files_to_pack.each do |rel_path, mode|
            src = File.join(ROOT_DIR, rel_path)
            content = File.binread(src)
            content = content.gsub("\r\n", "\n") if rel_path.end_with?(".rb", ".sh", ".desktop", "rubylock-rpc")
            tar.add_file_simple("#{prefix}/#{rel_path}", mode, content.bytesize) do |io|
              io.write(content)
            end
          end

          install_sh = File.binread(File.join(ROOT_DIR, "packaging/linux/install.sh")).gsub("\r\n", "\n")
          tar.add_file_simple("#{prefix}/install.sh", 0o755, install_sh.bytesize) do |io|
            io.write(install_sh)
          end

          uninstall_sh = File.binread(File.join(ROOT_DIR, "packaging/linux/uninstall.sh")).gsub("\r\n", "\n")
          tar.add_file_simple("#{prefix}/uninstall.sh", 0o755, uninstall_sh.bytesize) do |io|
            io.write(uninstall_sh)
          end

          if linux_elf && File.exist?(linux_elf)
            elf_bytes = File.binread(linux_elf)
            tar.add_file_simple("#{prefix}/rubylock-rpc", 0o755, elf_bytes.bytesize) do |io|
              io.write(elf_bytes)
            end
          end
        end
      end
    end
  ensure
    FileUtils.rm_f(linux_elf) if linux_elf && File.exist?(linux_elf)
    puts "[package] Built Linux archive: #{tar_gz_out} (#{File.size(tar_gz_out)} bytes)" if File.exist?(tar_gz_out.to_s)
  end
end

if $PROGRAM_NAME == __FILE__
  arg = ARGV[0].to_s.sub(/\A--/, "").downcase
  target = case arg
           when "exe", "windows" then :windows
           when "linux"          then :linux
           else :all
           end
  Packager.build_all(target)
end
