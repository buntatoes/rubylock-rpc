# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

module DeadlockRpc
  # Lightweight, zero-dependency TOML parser and serializer tailored for Deadlock RPC config files.
  # Supports standard [section] and [nested.section] tables, double-quoted and literal single-quoted
  # strings, booleans, integers, and # comments.
  module Toml
    module_function

    def parse(text)
      root = {}
      current_table = root

      text.to_s.each_line do |raw_line|
        line = strip_comment(raw_line).strip
        next if line.empty?

        if line.start_with?("[") && line.end_with?("]")
          section_path = line[1..-2].strip.split(".")
          current_table = section_path.reduce(root) do |acc, key|
            acc[key] ||= {}
          end
        elsif (eq_idx = line.index("="))
          key = line[0...eq_idx].strip
          val_str = line[(eq_idx + 1)..].strip
          current_table[key] = parse_value(val_str) unless key.empty?
        end
      end

      root
    end

    def dump(hash)
      lines = []
      emit_table(hash, [], lines)
      "#{lines.join("\n").rstrip}\n"
    end

    def emit_table(table, path, lines)
      scalars = {}
      subtables = {}

      table.each do |k, v|
        if v.is_a?(Hash)
          subtables[k.to_s] = v
        else
          scalars[k.to_s] = v
        end
      end

      unless path.empty? && scalars.empty?
        lines << "" unless lines.empty?
        lines << "[#{path.join('.')}]" unless path.empty?
        scalars.keys.sort.each do |k|
          lines << "#{k} = #{format_value(scalars[k])}"
        end
      end

      subtables.keys.sort.each do |k|
        emit_table(subtables[k], path + [k], lines)
      end
    end

    def strip_comment(line)
      in_double = false
      in_single = false
      escaped = false

      line.each_char.with_index do |ch, idx|
        if escaped
          escaped = false
          next
        end
        if ch == "\\" && in_double
          escaped = true
          next
        end
        if ch == '"' && !in_single
          in_double = !in_double
        elsif ch == "'" && !in_double
          in_single = !in_single
        elsif ch == "#" && !in_double && !in_single
          return line[0...idx]
        end
      end
      line
    end

    def parse_value(val_str)
      if val_str.start_with?('"') && val_str.end_with?('"') && val_str.length >= 2
        unescape_double_quoted(val_str[1..-2])
      elsif val_str.start_with?("'") && val_str.end_with?("'") && val_str.length >= 2
        val_str[1..-2]
      elsif val_str == "true"
        true
      elsif val_str == "false"
        false
      elsif val_str.match?(/\A-?\d+\z/)
        val_str.to_i
      else
        val_str
      end
    end

    def unescape_double_quoted(str)
      str.gsub(/\\(["\\ntr])/) do
        case Regexp.last_match(1)
        when '"'  then '"'
        when "\\" then "\\"
        when "n"  then "\n"
        when "t"  then "\t"
        when "r"  then "\r"
        else Regexp.last_match(0)
        end
      end
    end

    def format_value(val)
      case val
      when TrueClass, FalseClass, Integer
        val.to_s
      when String
        if val.include?("\\") && !val.include?("'")
          "'#{val}'"
        else
          escaped = val.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", "\\n")
          "\"#{escaped}\""
        end
      else
        "\"#{val}\""
      end
    end
  end
end
