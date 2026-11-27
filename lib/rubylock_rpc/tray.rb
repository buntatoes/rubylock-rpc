# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "socket"
require_relative "logger"

module RubylockRpc
  # Native, zero-dependency system tray icon for Windows (Win32 Shell_NotifyIconW)
  # and Linux GNOME / KDE / COSMIC / XFCE (D-Bus org.kde.StatusNotifierItem + com.canonical.dbusmenu).
  module Tray
    MENU_LAUNCH_DEADLOCK = 4
    MENU_TOGGLE_EXIT     = 5
    MENU_TOGGLE_UPDATE   = 6
    MENU_CHECK_UPDATE    = 7
    MENU_OPEN_CONFIG     = 8
    MENU_QUIT            = 10

    def self.start(shared:, version:, icon_ico_path:, callbacks: {})
      if Gem.win_platform?
        WindowsTray.new(shared: shared, version: version, icon_ico_path: icon_ico_path, callbacks: callbacks).start
      else
        LinuxDbusTray.new(shared: shared, version: version, callbacks: callbacks).start
      end
    rescue StandardError => e
      RpcLogger.warn("[tray] Could not start system tray icon: #{e.message}")
      NullTray.new
    end

    class NullTray
      def update_status(_text); end
      def refresh; end
      def stop; end
    end

    # -------------------------------------------------------------------------
    # Pure-Ruby D-Bus binary wire protocol encoder/decoder (little-endian v1)
    # -------------------------------------------------------------------------
    module DbusWire
      MSG_METHOD_CALL   = 1
      MSG_METHOD_RETURN = 2
      MSG_ERROR         = 3
      MSG_SIGNAL        = 4

      HDR_PATH         = 1
      HDR_INTERFACE    = 2
      HDR_MEMBER       = 3
      HDR_ERROR_NAME   = 4
      HDR_REPLY_SERIAL = 5
      HDR_DESTINATION  = 6
      HDR_SENDER       = 7
      HDR_SIGNATURE    = 8

      ALIGNMENTS = {
        "y" => 1, "b" => 4, "n" => 2, "q" => 2, "i" => 4, "u" => 4,
        "x" => 8, "t" => 8, "d" => 8, "s" => 4, "o" => 4, "g" => 1,
        "v" => 1, "a" => 4, "(" => 8, "{" => 8
      }.freeze

      Variant = Struct.new(:sig, :val)

      module_function

      def v(sig, val)
        Variant.new(sig, val)
      end

      def pad(buf, align)
        rem = buf.bytesize % align
        buf << ("\0" * (align - rem)) if rem != 0
      end

      def split_signature(sig)
        types = []
        i = 0
        while i < sig.length
          start = i
          ch = sig[i]
          if ch == "a"
            i += 1
            sub = split_one_type(sig, i)
            i += sub.length
            types << sig[start...i]
          elsif ch == "(" || ch == "{"
            sub = split_one_type(sig, i)
            i += sub.length
            types << sub
          else
            i += 1
            types << ch
          end
        end
        types
      end

      def split_one_type(sig, idx)
        ch = sig[idx]
        case ch
        when "a"
          "a#{split_one_type(sig, idx + 1)}"
        when "("
          depth = 0
          j = idx
          while j < sig.length
            depth += 1 if sig[j] == "("
            depth -= 1 if sig[j] == ")"
            j += 1
            break if depth.zero?
          end
          sig[idx...j]
        when "{"
          depth = 0
          j = idx
          while j < sig.length
            depth += 1 if sig[j] == "{"
            depth -= 1 if sig[j] == "}"
            j += 1
            break if depth.zero?
          end
          sig[idx...j]
        else
          ch
        end
      end

      def align_of(type_sig)
        ALIGNMENTS.fetch(type_sig[0], 1)
      end

      def encode_value(buf, type_sig, val)
        case type_sig[0]
        when "y"
          buf << [val.to_i & 0xFF].pack("C")
        when "b"
          pad(buf, 4)
          buf << [val ? 1 : 0].pack("V")
        when "i"
          pad(buf, 4)
          buf << [val.to_i].pack("l<")
        when "u"
          pad(buf, 4)
          buf << [val.to_i].pack("V")
        when "s", "o"
          pad(buf, 4)
          bytes = val.to_s.b
          buf << [bytes.bytesize].pack("V")
          buf << bytes << "\0"
        when "g"
          bytes = val.to_s.b
          buf << [bytes.bytesize].pack("C")
          buf << bytes << "\0"
        when "v"
          var = val.is_a?(Variant) ? val : infer_variant(val)
          encode_value(buf, "g", var.sig)
          encode_value(buf, var.sig, var.val)
        when "a"
          elem_sig = type_sig[1..]
          elem_align = align_of(elem_sig)
          pad(buf, 4)
          len_pos = buf.bytesize
          buf << "\0\0\0\0"
          pad(buf, elem_align)
          data_start = buf.bytesize
          if elem_sig.start_with?("{") && val.is_a?(Hash)
            val.each { |k, item_v| encode_value(buf, elem_sig, [k, item_v]) }
          else
            Array(val).each { |item| encode_value(buf, elem_sig, item) }
          end
          byte_len = buf.bytesize - data_start
          buf[len_pos, 4] = [byte_len].pack("V")
        when "(", "{"
          pad(buf, 8)
          inner = type_sig[1..-2]
          sub_types = split_signature(inner)
          sub_types.each_with_index do |st, idx|
            encode_value(buf, st, val[idx])
          end
        else
          raise "Unsupported D-Bus type: #{type_sig}"
        end
      end

      def infer_variant(val)
        case val
        when TrueClass, FalseClass then Variant.new("b", val)
        when Integer               then Variant.new("i", val)
        else                            Variant.new("s", val.to_s)
        end
      end

      def encode_message(type:, serial:, headers:, body_sig: "", body_args: [], flags: 0)
        body = +"".b
        unless body_sig.empty?
          split_signature(body_sig).each_with_index do |t, idx|
            encode_value(body, t, body_args[idx])
          end
        end

        hdr_fields = headers.dup
        hdr_fields << [HDR_SIGNATURE, Variant.new("g", body_sig)] unless body_sig.empty?

        msg = +"".b
        msg << ["l".ord, type, flags, 1, body.bytesize, serial].pack("CCCCVV")
        encode_value(msg, "a(yv)", hdr_fields)
        pad(msg, 8)
        msg << body
        msg
      end

      class Decoder
        def initialize(data, pos = 0)
          @data = data
          @pos = pos
        end

        attr_reader :pos

        def align(n)
          rem = @pos % n
          @pos += (n - rem) if rem != 0
        end

        def read_type(type_sig)
          case type_sig[0]
          when "y"
            val = @data.getbyte(@pos)
            @pos += 1
            val
          when "b"
            align(4)
            val = @data.byteslice(@pos, 4).unpack1("V") != 0
            @pos += 4
            val
          when "n"
            align(2)
            val = @data.byteslice(@pos, 2).unpack1("s<")
            @pos += 2
            val
          when "q"
            align(2)
            val = @data.byteslice(@pos, 2).unpack1("v")
            @pos += 2
            val
          when "i"
            align(4)
            val = @data.byteslice(@pos, 4).unpack1("l<")
            @pos += 4
            val
          when "u"
            align(4)
            val = @data.byteslice(@pos, 4).unpack1("V")
            @pos += 4
            val
          when "x"
            align(8)
            val = @data.byteslice(@pos, 8).unpack1("q<")
            @pos += 8
            val
          when "t"
            align(8)
            val = @data.byteslice(@pos, 8).unpack1("Q<")
            @pos += 8
            val
          when "d"
            align(8)
            val = @data.byteslice(@pos, 8).unpack1("E")
            @pos += 8
            val
          when "s", "o"
            align(4)
            len = @data.byteslice(@pos, 4).unpack1("V")
            @pos += 4
            str = @data.byteslice(@pos, len).force_encoding("UTF-8")
            @pos += len + 1
            str
          when "g"
            len = @data.getbyte(@pos)
            @pos += 1
            str = @data.byteslice(@pos, len).force_encoding("UTF-8")
            @pos += len + 1
            str
          when "v"
            sig = read_type("g")
            read_type(sig)
          when "a"
            elem_sig = type_sig[1..]
            align(4)
            byte_len = @data.byteslice(@pos, 4).unpack1("V")
            @pos += 4
            align(DbusWire.align_of(elem_sig))
            end_pos = @pos + byte_len
            if elem_sig.start_with?("{")
              h = {}
              while @pos < end_pos
                k, val = read_type(elem_sig)
                h[k] = val
              end
              h
            else
              arr = []
              arr << read_type(elem_sig) while @pos < end_pos
              arr
            end
          when "(", "{"
            align(8)
            inner = type_sig[1..-2]
            DbusWire.split_signature(inner).map { |st| read_type(st) }
          else
            raise "Unsupported D-Bus decode type: #{type_sig}"
          end
        end
      end

      def read_message(io)
        fixed = read_exact(io, 16)
        return nil unless fixed

        endian, msg_type, flags, _ver, body_len, serial, hdr_len = fixed.unpack("CCCCVVV")
        raise "Unsupported D-Bus endianness" unless endian == "l".ord

        hdr_pad = (8 - ((16 + hdr_len) % 8)) % 8
        rest = read_exact(io, hdr_len + hdr_pad + body_len)
        return nil unless rest

        full = fixed + rest
        dec = Decoder.new(full, 12)
        raw_fields = dec.read_type("a(yv)")
        fields = {}
        raw_fields.each { |code, val| fields[code] = val }

        dec.align(8)
        body_args = []
        sig = fields[HDR_SIGNATURE].to_s
        unless sig.empty?
          split_signature(sig).each { |t| body_args << dec.read_type(t) }
        end

        {
          type: msg_type,
          flags: flags,
          serial: serial,
          path: fields[HDR_PATH],
          interface: fields[HDR_INTERFACE],
          member: fields[HDR_MEMBER],
          sender: fields[HDR_SENDER],
          destination: fields[HDR_DESTINATION],
          reply_serial: fields[HDR_REPLY_SERIAL],
          signature: sig,
          args: body_args
        }
      end

      def read_exact(io, n)
        buf = +"".b
        while buf.bytesize < n
          chunk = io.read(n - buf.bytesize)
          return nil if chunk.nil? || chunk.empty?

          buf << chunk
        end
        buf
      end
    end

    # -------------------------------------------------------------------------
    # Linux StatusNotifierItem + DBusMenu tray (KDE Plasma, GNOME AppIndicator, COSMIC, XFCE)
    # -------------------------------------------------------------------------
    class LinuxDbusTray
      SNI_IFACE  = "org.kde.StatusNotifierItem"
      SNI_PATH   = "/StatusNotifierItem"
      MENU_IFACE = "com.canonical.dbusmenu"
      MENU_PATH  = "/MenuBar"

      SNI_INTROSPECT = <<~XML
        <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg type="s" direction="out"/></method>
          </interface>
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
            <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
            <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
          </interface>
          <interface name="org.kde.StatusNotifierItem">
            <property name="Category" type="s" access="read"/>
            <property name="Id" type="s" access="read"/>
            <property name="Title" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="WindowId" type="i" access="read"/>
            <property name="IconName" type="s" access="read"/>
            <property name="IconThemePath" type="s" access="read"/>
            <property name="IconPixmap" type="a(iiay)" access="read"/>
            <property name="OverlayIconName" type="s" access="read"/>
            <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionIconName" type="s" access="read"/>
            <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionMovieName" type="s" access="read"/>
            <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
            <property name="ItemIsMenu" type="b" access="read"/>
            <property name="Menu" type="o" access="read"/>
            <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
            <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
            <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
            <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
            <signal name="NewTitle"/>
            <signal name="NewIcon"/>
            <signal name="NewToolTip"/>
            <signal name="NewStatus"><arg type="s"/></signal>
          </interface>
        </node>
      XML

      MENU_INTROSPECT = <<~XML
        <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg type="s" direction="out"/></method>
          </interface>
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
            <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
          </interface>
          <interface name="com.canonical.dbusmenu">
            <property name="Version" type="u" access="read"/>
            <property name="TextDirection" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="IconThemePath" type="as" access="read"/>
            <method name="GetLayout">
              <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
              <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
            </method>
            <method name="GetGroupProperties">
              <arg type="ai" direction="in"/><arg type="as" direction="in"/>
              <arg type="a(ia{sv})" direction="out"/>
            </method>
            <method name="GetProperty">
              <arg type="i" direction="in"/><arg type="s" direction="in"/>
              <arg type="v" direction="out"/>
            </method>
            <method name="Event">
              <arg type="i" direction="in"/><arg type="s" direction="in"/>
              <arg type="v" direction="in"/><arg type="u" direction="in"/>
            </method>
            <method name="EventGroup">
              <arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/>
            </method>
            <method name="AboutToShow">
              <arg type="i" direction="in"/><arg type="b" direction="out"/>
            </method>
            <method name="AboutToShowGroup">
              <arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/>
            </method>
            <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
            <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
          </interface>
        </node>
      XML

      def initialize(shared:, version:, callbacks: {})
        @shared = shared
        @version = version
        @callbacks = callbacks
        @mutex = Mutex.new
        @serial = 0
        @revision = 1
        @status_text = "Connecting to Discord..."
        @sock = nil
        @running = false
        @thread = nil
        @bus_name = "org.kde.StatusNotifierItem-#{Process.pid}-1"
        @icon_name, @icon_theme_path = resolve_icon_config
      end

      def start
        sock = connect_session_bus
        unless sock
          RpcLogger.info("[tray] No Linux D-Bus session bus detected - running without tray icon.")
          return self
        end

        @sock = sock
        @running = true

        send_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello")
        send_call(
          "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
          "su", [@bus_name, 0]
        )
        send_call(
          "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch",
          "s", ["type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'"]
        )
        register_with_watcher

        @thread = Thread.new { message_loop }
        RpcLogger.info("[tray] Linux system tray icon registered (StatusNotifierItem)")
        self
      rescue StandardError => e
        RpcLogger.warn("[tray] Linux tray init failed: #{e.message}")
        stop
        self
      end

      def update_status(text)
        changed = @mutex.synchronize do
          str = text.to_s
          if str != @status_text
            @status_text = str
            @revision += 1
            true
          else
            false
          end
        end
        return unless changed && @running && @sock

        emit_signal(SNI_PATH, SNI_IFACE, "NewToolTip")
        emit_signal(MENU_PATH, MENU_IFACE, "LayoutUpdated", "ui", [@revision, 0])
      rescue StandardError
        # Ignore transient bus write errors
      end

      def refresh
        rev = @mutex.synchronize { @revision += 1 }
        return unless @running && @sock

        emit_signal(MENU_PATH, MENU_IFACE, "LayoutUpdated", "ui", [rev, 0])
      rescue StandardError
        # Ignore transient bus write errors
      end

      def stop
        @running = false
        @sock&.close rescue nil
        @sock = nil
      end

      private

      def resolve_icon_config
        # Prefer standard XDG hicolor icon if installed (~/.local/share/icons/hicolor/256x256/apps/rubylock-rpc.png)
        home = Dir.home rescue ""
        hicolor_icon = File.join(home, ".local/share/icons/hicolor/256x256/apps/rubylock-rpc.png")
        return ["rubylock-rpc", ""] if File.exist?(hicolor_icon)

        # Fallback for portable / source checkouts (assets/icon.png)
        assets_dir = File.expand_path("../../assets", __dir__)
        if File.exist?(File.join(assets_dir, "icon.png"))
          return ["icon", assets_dir]
        end

        ["rubylock-rpc", ""]
      end

      def connect_session_bus
        addr = ENV["DBUS_SESSION_BUS_ADDRESS"].to_s
        if addr.empty?
          runtime = ENV["XDG_RUNTIME_DIR"].to_s
          default_bus = File.join(runtime, "bus")
          addr = "unix:path=#{default_bus}" if !runtime.empty? && File.socket?(default_bus)
        end
        return nil if addr.empty?

        sock = open_dbus_socket(addr)
        return nil unless sock

        uid_hex = Process.uid.to_s.bytes.map { |b| format("%02x", b) }.join
        sock.write("\0AUTH EXTERNAL #{uid_hex}\r\n")
        resp = sock.gets("\r\n").to_s
        unless resp.start_with?("OK ")
          sock.write("AUTH ANONYMOUS\r\n")
          resp = sock.gets("\r\n").to_s
          unless resp.start_with?("OK ")
            sock.close
            return nil
          end
        end
        sock.write("BEGIN\r\n")
        sock
      rescue StandardError
        nil
      end

      def open_dbus_socket(addr)
        addr.split(";").each do |entry|
          next unless entry.start_with?("unix:")

          params = {}
          entry.sub(/\Aunix:/, "").split(",").each do |kv|
            k, val = kv.split("=", 2)
            params[k] = val.to_s.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).to_i(16).chr }
          end
          if params["path"]
            return UNIXSocket.new(params["path"])
          elsif params["abstract"]
            return UNIXSocket.new("\0#{params['abstract']}")
          end
        rescue StandardError
          next
        end
        nil
      end

      def next_serial
        @mutex.synchronize { @serial += 1 }
      end

      def write_raw(bytes)
        @mutex.synchronize do
          return unless @sock

          @sock.write(bytes)
          @sock.flush
        end
      end

      def send_call(dest, path, iface, member, sig = "", args = [])
        headers = [
          [DbusWire::HDR_PATH,        DbusWire.v("o", path)],
          [DbusWire::HDR_INTERFACE,   DbusWire.v("s", iface)],
          [DbusWire::HDR_MEMBER,      DbusWire.v("s", member)],
          [DbusWire::HDR_DESTINATION, DbusWire.v("s", dest)]
        ]
        msg = DbusWire.encode_message(
          type: DbusWire::MSG_METHOD_CALL,
          serial: next_serial,
          headers: headers,
          body_sig: sig,
          body_args: args
        )
        write_raw(msg)
      end

      def send_reply(req, sig = "", args = [])
        headers = [[DbusWire::HDR_REPLY_SERIAL, DbusWire.v("u", req[:serial])]]
        headers << [DbusWire::HDR_DESTINATION, DbusWire.v("s", req[:sender])] if req[:sender]
        msg = DbusWire.encode_message(
          type: DbusWire::MSG_METHOD_RETURN,
          serial: next_serial,
          headers: headers,
          body_sig: sig,
          body_args: args
        )
        write_raw(msg)
      end

      def send_error(req, error_name, message = "")
        headers = [
          [DbusWire::HDR_ERROR_NAME,   DbusWire.v("s", error_name)],
          [DbusWire::HDR_REPLY_SERIAL, DbusWire.v("u", req[:serial])]
        ]
        headers << [DbusWire::HDR_DESTINATION, DbusWire.v("s", req[:sender])] if req[:sender]
        msg = DbusWire.encode_message(
          type: DbusWire::MSG_ERROR,
          serial: next_serial,
          headers: headers,
          body_sig: "s",
          body_args: [message]
        )
        write_raw(msg)
      end

      def emit_signal(path, iface, member, sig = "", args = [])
        headers = [
          [DbusWire::HDR_PATH,      DbusWire.v("o", path)],
          [DbusWire::HDR_INTERFACE, DbusWire.v("s", iface)],
          [DbusWire::HDR_MEMBER,    DbusWire.v("s", member)]
        ]
        msg = DbusWire.encode_message(
          type: DbusWire::MSG_SIGNAL,
          serial: next_serial,
          headers: headers,
          body_sig: sig,
          body_args: args
        )
        write_raw(msg)
      end

      def register_with_watcher
        send_call(
          "org.kde.StatusNotifierWatcher",
          "/StatusNotifierWatcher",
          "org.kde.StatusNotifierWatcher",
          "RegisterStatusNotifierItem",
          "s",
          [SNI_PATH]
        )
      end

      def message_loop
        while @running && @sock
          msg = DbusWire.read_message(@sock)
          break unless msg

          if msg[:type] == DbusWire::MSG_METHOD_CALL
            handle_method_call(msg)
          elsif msg[:type] == DbusWire::MSG_SIGNAL &&
                msg[:member] == "NameOwnerChanged" &&
                msg[:args][0] == "org.kde.StatusNotifierWatcher" &&
                !msg[:args][2].to_s.empty?
            register_with_watcher
          end
        end
      rescue StandardError => e
        RpcLogger.debug("[tray] D-Bus loop ended: #{e.message}") if @running
      end

      def handle_method_call(msg)
        path = msg[:path].to_s
        iface = msg[:interface].to_s
        member = msg[:member].to_s

        if iface == "org.freedesktop.DBus.Peer" && member == "Ping"
          send_reply(msg)
        elsif iface == "org.freedesktop.DBus.Introspectable" && member == "Introspect"
          xml = (path == MENU_PATH) ? MENU_INTROSPECT : SNI_INTROSPECT
          send_reply(msg, "s", [xml])
        elsif iface == "org.freedesktop.DBus.Properties"
          handle_properties(msg, path)
        elsif path == SNI_PATH
          send_reply(msg)
        elsif path == MENU_PATH
          handle_menu_call(msg, member)
        else
          send_error(msg, "org.freedesktop.DBus.Error.UnknownObject", "Unknown path #{path}")
        end
      end

      def handle_properties(msg, path)
        props = (path == MENU_PATH) ? menu_properties : sni_properties
        case msg[:member]
        when "Get"
          key = msg[:args][1].to_s
          if props.key?(key)
            send_reply(msg, "v", [props[key]])
          else
            send_error(msg, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property #{key}")
          end
        when "GetAll"
          send_reply(msg, "a{sv}", [props])
        else
          send_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unsupported properties method")
        end
      end

      def sni_properties
        status_snapshot = @mutex.synchronize { @status_text }
        {
          "Category"            => DbusWire.v("s", "ApplicationStatus"),
          "Id"                  => DbusWire.v("s", "rubylock-rpc"),
          "Title"               => DbusWire.v("s", "RubyLock RPC"),
          "Status"              => DbusWire.v("s", "Active"),
          "WindowId"            => DbusWire.v("i", 0),
          "IconName"            => DbusWire.v("s", @icon_name),
          "IconThemePath"       => DbusWire.v("s", @icon_theme_path),
          "IconPixmap"          => DbusWire.v("a(iiay)", []),
          "OverlayIconName"     => DbusWire.v("s", ""),
          "OverlayIconPixmap"   => DbusWire.v("a(iiay)", []),
          "AttentionIconName"   => DbusWire.v("s", ""),
          "AttentionIconPixmap" => DbusWire.v("a(iiay)", []),
          "AttentionMovieName"  => DbusWire.v("s", ""),
          "ToolTip"             => DbusWire.v("(sa(iiay)ss)", [@icon_name, [], "RubyLock RPC", status_snapshot]),
          "ItemIsMenu"          => DbusWire.v("b", true),
          "Menu"                => DbusWire.v("o", MENU_PATH)
        }
      end

      def menu_properties
        {
          "Version"       => DbusWire.v("u", 3),
          "TextDirection" => DbusWire.v("s", "ltr"),
          "Status"        => DbusWire.v("s", "normal"),
          "IconThemePath" => DbusWire.v("as", [])
        }
      end

      def menu_items
        status_snapshot = @mutex.synchronize { @status_text }
        [
          [1, { "label" => DbusWire.v("s", "RubyLock RPC v#{@version}"), "enabled" => DbusWire.v("b", false) }],
          [2, { "label" => DbusWire.v("s", "Status: #{status_snapshot}"), "enabled" => DbusWire.v("b", false) }],
          [3, { "type"  => DbusWire.v("s", "separator") }],
          [MENU_LAUNCH_DEADLOCK, { "label" => DbusWire.v("s", "Launch Deadlock"), "enabled" => DbusWire.v("b", true) }],
          [MENU_TOGGLE_EXIT, {
            "label"        => DbusWire.v("s", "Exit When Game Closes"),
            "toggle-type"  => DbusWire.v("s", "checkmark"),
            "toggle-state" => DbusWire.v("i", @shared.exit_when_game_closes ? 1 : 0),
            "enabled"      => DbusWire.v("b", true)
          }],
          [MENU_TOGGLE_UPDATE, {
            "label"        => DbusWire.v("s", "Auto-Update"),
            "toggle-type"  => DbusWire.v("s", "checkmark"),
            "toggle-state" => DbusWire.v("i", @shared.auto_update ? 1 : 0),
            "enabled"      => DbusWire.v("b", true)
          }],
          [MENU_CHECK_UPDATE, { "label" => DbusWire.v("s", "Check for Updates"), "enabled" => DbusWire.v("b", true) }],
          [MENU_OPEN_CONFIG,  { "label" => DbusWire.v("s", "Open Config Folder"), "enabled" => DbusWire.v("b", true) }],
          [9,                 { "type"  => DbusWire.v("s", "separator") }],
          [MENU_QUIT,         { "label" => DbusWire.v("s", "Quit RubyLock RPC"), "enabled" => DbusWire.v("b", true) }]
        ]
      end

      def handle_menu_call(msg, member)
        case member
        when "GetLayout"
          parent_id = msg[:args][0].to_i
          rev = @mutex.synchronize { @revision }
          if parent_id == 0
            children = menu_items.map do |id, props|
              DbusWire.v("(ia{sv}av)", [id, props, []])
            end
            root = [0, { "children-display" => DbusWire.v("s", "submenu") }, children]
          else
            found = menu_items.find { |id, _| id == parent_id }
            root = found ? [found[0], found[1], []] : [parent_id, {}, []]
          end
          send_reply(msg, "u(ia{sv}av)", [rev, root])
        when "GetGroupProperties"
          ids = Array(msg[:args][0])
          selected = ids.empty? ? menu_items : menu_items.select { |id, _| ids.include?(id) }
          send_reply(msg, "a(ia{sv})", [selected])
        when "GetProperty"
          id = msg[:args][0].to_i
          name = msg[:args][1].to_s
          found = menu_items.find { |item_id, _| item_id == id }
          if found && found[1].key?(name)
            send_reply(msg, "v", [found[1][name]])
          else
            send_error(msg, "org.freedesktop.DBus.Error.InvalidArgs", "Property not found")
          end
        when "Event"
          id = msg[:args][0].to_i
          ev = msg[:args][1].to_s
          send_reply(msg)
          dispatch_menu_action(id) if ev == "clicked"
        when "EventGroup"
          events = Array(msg[:args][0])
          send_reply(msg, "ai", [[]])
          events.each { |ev| dispatch_menu_action(ev[0].to_i) if ev[1].to_s == "clicked" }
        when "AboutToShow"
          send_reply(msg, "b", [false])
        when "AboutToShowGroup"
          send_reply(msg, "aiai", [[], []])
        else
          send_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown menu method #{member}")
        end
      end

      def dispatch_menu_action(id)
        Thread.new do
          case id
          when MENU_LAUNCH_DEADLOCK then @callbacks[:launch]&.call
          when MENU_TOGGLE_EXIT
            @callbacks[:toggle_exit]&.call
            refresh
          when MENU_TOGGLE_UPDATE
            @callbacks[:toggle_auto_update]&.call
            refresh
          when MENU_CHECK_UPDATE    then @callbacks[:check_update]&.call
          when MENU_OPEN_CONFIG     then @callbacks[:open_config]&.call
          when MENU_QUIT            then @callbacks[:quit]&.call
          end
        rescue StandardError => e
          RpcLogger.warn("[tray] Menu action failed: #{e.message}")
        end
      end
    end

    # -------------------------------------------------------------------------
    # Windows Native System Tray (Shell_NotifyIconW via Ruby Fiddle)
    # -------------------------------------------------------------------------
    class WindowsTray
      if Gem.win_platform?
        require "fiddle"
        require "fiddle/import"

        module Kernel32
          extend Fiddle::Importer
          dlload "kernel32.dll"
          extern "void* GetModuleHandleW(void*)"
        end

        module User32
          extend Fiddle::Importer
          dlload "user32.dll"
          extern "unsigned short RegisterClassExW(void*)"
          extern "void* CreateWindowExW(unsigned long, void*, void*, unsigned long, int, int, int, int, void*, void*, void*, void*)"
          extern "int DestroyWindow(void*)"
          extern "long long DefWindowProcW(void*, unsigned int, unsigned long long, long long)"
          extern "int PeekMessageW(void*, void*, unsigned int, unsigned int, unsigned int)"
          extern "int TranslateMessage(void*)"
          extern "long long DispatchMessageW(void*)"
          extern "int PostMessageW(void*, unsigned int, unsigned long long, long long)"
          extern "void* LoadImageW(void*, void*, unsigned int, int, int, unsigned int)"
          extern "int DestroyIcon(void*)"
          extern "void* CreatePopupMenu()"
          extern "int AppendMenuW(void*, unsigned int, unsigned long long, void*)"
          extern "int TrackPopupMenu(void*, unsigned int, int, int, int, void*, void*)"
          extern "int DestroyMenu(void*)"
          extern "int GetCursorPos(void*)"
          extern "int SetForegroundWindow(void*)"
          extern "unsigned int RegisterWindowMessageW(void*)"
        end

        module Shell32
          extend Fiddle::Importer
          dlload "shell32.dll"
          extern "int Shell_NotifyIconW(unsigned long, void*)"
        end
      end

      WM_NULL       = 0x0000
      WM_USER       = 0x0400
      WM_TRAYICON   = WM_USER + 1
      WM_RBUTTONUP  = 0x0205
      WM_LBUTTONUP  = 0x0202
      PM_REMOVE     = 0x0001
      IMAGE_ICON    = 1
      LR_LOADFROMFILE = 0x0010
      LR_DEFAULTSIZE  = 0x0040
      NIM_ADD       = 0x00000000
      NIM_MODIFY    = 0x00000001
      NIM_DELETE    = 0x00000002
      NIF_MESSAGE   = 0x00000001
      NIF_ICON      = 0x00000002
      NIF_TIP       = 0x00000004
      MF_STRING     = 0x00000000
      MF_GRAYED     = 0x00000001
      MF_CHECKED    = 0x00000008
      MF_SEPARATOR  = 0x00000800
      TPM_RIGHTBUTTON = 0x0002
      TPM_NONOTIFY    = 0x0080
      TPM_RETURNCMD   = 0x0100

      def initialize(shared:, version:, icon_ico_path:, callbacks: {})
        @shared = shared
        @version = version
        @icon_ico_path = icon_ico_path
        @callbacks = callbacks
        @mutex = Mutex.new
        @status_text = "Connecting to Discord..."
        @running = false
        @hwnd = nil
        @hicon = nil
        @nid_buf = nil
        @pending_tooltip = nil
      end

      def start
        return self unless Gem.win_platform? && Fiddle::SIZEOF_VOIDP == 8

        @running = true
        @thread = Thread.new { run_message_loop }
        self
      end

      def update_status(text)
        @mutex.synchronize do
          @status_text = text.to_s
          @pending_tooltip = "RubyLock RPC - #{@status_text}"[0, 127]
        end
      end

      def refresh; end

      def stop
        @running = false
      end

      private

      def wide(str)
        "#{str}\0".encode("UTF-16LE")
      end

      def run_message_loop
        hinst = Kernel32.GetModuleHandleW(nil)
        class_name = wide("RubyLockRpcTrayWindow_#{Process.pid}")
        taskbar_msg = User32.RegisterWindowMessageW(Fiddle::Pointer[wide("TaskbarCreated")])

        @wnd_proc = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_LONG_LONG,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT, Fiddle::TYPE_ULONG_LONG, Fiddle::TYPE_LONG_LONG]
        ) do |hwnd, msg, wparam, lparam|
          if msg == WM_TRAYICON && (lparam == WM_RBUTTONUP || lparam == WM_LBUTTONUP)
            show_context_menu(hwnd)
            0
          elsif taskbar_msg != 0 && msg == taskbar_msg
            Shell32.Shell_NotifyIconW(NIM_ADD, Fiddle::Pointer[@nid_buf]) if @nid_buf
            0
          else
            User32.DefWindowProcW(hwnd, msg, wparam, lparam)
          end
        end

        wc = +"\0" * 80
        wc[0, 4]  = [80].pack("V")
        wc[8, 8]  = [@wnd_proc.to_i].pack("Q<")
        wc[24, 8] = [hinst.to_i].pack("Q<")
        wc[64, 8] = [Fiddle::Pointer[class_name].to_i].pack("Q<")
        User32.RegisterClassExW(Fiddle::Pointer[wc])

        title_w = wide("RubyLock RPC")
        @hwnd = User32.CreateWindowExW(
          0, Fiddle::Pointer[class_name], Fiddle::Pointer[title_w],
          0, 0, 0, 0, 0, nil, nil, hinst, nil
        )
        return if @hwnd.nil? || @hwnd.null?

        if @icon_ico_path && File.exist?(@icon_ico_path)
          ico_w = wide(@icon_ico_path)
          @hicon = User32.LoadImageW(nil, Fiddle::Pointer[ico_w], IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE)
        end

        @nid_buf = build_nid(@hwnd, @hicon, "RubyLock RPC v#{@version}")
        Shell32.Shell_NotifyIconW(NIM_ADD, Fiddle::Pointer[@nid_buf])
        RpcLogger.info("[tray] Windows system tray icon active")

        msg_buf = +"\0" * 48
        while @running
          while User32.PeekMessageW(Fiddle::Pointer[msg_buf], @hwnd, 0, 0, PM_REMOVE) != 0
            User32.TranslateMessage(Fiddle::Pointer[msg_buf])
            User32.DispatchMessageW(Fiddle::Pointer[msg_buf])
          end

          tip = @mutex.synchronize { t = @pending_tooltip; @pending_tooltip = nil; t }
          if tip
            @nid_buf = build_nid(@hwnd, @hicon, tip)
            Shell32.Shell_NotifyIconW(NIM_MODIFY, Fiddle::Pointer[@nid_buf])
          end

          sleep(0.05)
        end
      rescue StandardError => e
        RpcLogger.warn("[tray] Windows tray loop error: #{e.message}")
      ensure
        Shell32.Shell_NotifyIconW(NIM_DELETE, Fiddle::Pointer[@nid_buf]) if @nid_buf
        User32.DestroyWindow(@hwnd) if @hwnd && !@hwnd.null?
        User32.DestroyIcon(@hicon) if @hicon && !@hicon.null?
      end

      def build_nid(hwnd, hicon, tooltip)
        nid = +"\0" * 976
        flags = NIF_MESSAGE | NIF_TIP
        flags |= NIF_ICON if hicon && !hicon.null?
        nid[0, 4]  = [976].pack("V")
        nid[8, 8]  = [hwnd.to_i].pack("Q<")
        nid[16, 4] = [1].pack("V")
        nid[20, 4] = [flags].pack("V")
        nid[24, 4] = [WM_TRAYICON].pack("V")
        nid[32, 8] = [hicon ? hicon.to_i : 0].pack("Q<")
        tip_w = wide(tooltip.to_s[0, 127])
        nid[40, tip_w.bytesize] = tip_w
        nid
      end

      def show_context_menu(hwnd)
        menu = User32.CreatePopupMenu
        return if menu.nil? || menu.null?

        status_snapshot = @mutex.synchronize { @status_text }
        append_item(menu, MF_STRING | MF_GRAYED, 1, "RubyLock RPC v#{@version}")
        append_item(menu, MF_STRING | MF_GRAYED, 2, "Status: #{status_snapshot}")
        User32.AppendMenuW(menu, MF_SEPARATOR, 0, nil)
        append_item(menu, MF_STRING, MENU_LAUNCH_DEADLOCK, "Launch Deadlock")
        exit_flags = MF_STRING | (@shared.exit_when_game_closes ? MF_CHECKED : 0)
        append_item(menu, exit_flags, MENU_TOGGLE_EXIT, "Exit When Game Closes")
        upd_flags = MF_STRING | (@shared.auto_update ? MF_CHECKED : 0)
        append_item(menu, upd_flags, MENU_TOGGLE_UPDATE, "Auto-Update")
        append_item(menu, MF_STRING, MENU_CHECK_UPDATE, "Check for Updates")
        append_item(menu, MF_STRING, MENU_OPEN_CONFIG, "Open Config Folder")
        User32.AppendMenuW(menu, MF_SEPARATOR, 0, nil)
        append_item(menu, MF_STRING, MENU_QUIT, "Quit RubyLock RPC")

        pt = +"\0" * 8
        User32.GetCursorPos(Fiddle::Pointer[pt])
        x, y = pt.unpack("l<2")

        User32.SetForegroundWindow(hwnd)
        cmd = User32.TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD, x, y, 0, hwnd, nil)
        User32.PostMessageW(hwnd, WM_NULL, 0, 0)
        User32.DestroyMenu(menu)

        return if cmd.zero?

        Thread.new do
          case cmd
          when MENU_LAUNCH_DEADLOCK then @callbacks[:launch]&.call
          when MENU_TOGGLE_EXIT     then @callbacks[:toggle_exit]&.call
          when MENU_TOGGLE_UPDATE   then @callbacks[:toggle_auto_update]&.call
          when MENU_CHECK_UPDATE    then @callbacks[:check_update]&.call
          when MENU_OPEN_CONFIG     then @callbacks[:open_config]&.call
          when MENU_QUIT            then @callbacks[:quit]&.call
          end
        rescue StandardError => e
          RpcLogger.warn("[tray] Menu action failed: #{e.message}")
        end
      end

      def append_item(menu, flags, id, label)
        w = wide(label)
        User32.AppendMenuW(menu, flags, id, Fiddle::Pointer[w])
      end
    end
  end
end
