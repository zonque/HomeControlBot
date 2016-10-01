#!/usr/bin/env ruby

# -*- coding: utf-8 -*-

require 'yaml'
require 'telegram/bot'
require 'thread'
require 'net/ping'

include Net

EMOJI_CAMERA = "\u{1F4F7}"

class HomeControlBot

  def initialize()
    @mutex = Mutex.new

    @config = YAML.load(File.read("HomeControlBot.yml"))
    @chats = IO.readlines("HomeControlBot.chatids").map { |s| s.to_i } rescue []
    @chats.uniq!

    @pingStatus = {}
    @pingHosts = @config["ping_hosts"]
    @pingHosts.each { |ph| @pingStatus[ph] = false }

    @stickers = @config["stickers"] || {}

    @monitorDirs = @config["monitor_dirs"].map do |dir|
      { dir: dir, files: Dir.glob("#{dir}/*") }
    end

    @broadcasts = Queue.new
    @pingTimeout = 0
  end

  def parseTime(s)
    return 0 unless s

    factors = [ 1, 60, 60 * 60, 60 * 60 * 24 ]
    a = s.split(':').map(&:to_i)
    return 0 if a.length > factors.length

    a.inject { |sum, n| sum + (n * factors.pop) }
  end

  def broadcast(msg)
    @broadcasts.push({ message: msg, type: :message })
  end

  def broadcast_video(video)
    @broadcasts.push({ video: video, type: :video })
  end

  def writeChatIDs
    @chats.uniq!

    File.open("HomeControlBot.chatids", 'w') do |f|
      @chats.each do |c|
        f.write("#{c}\n")
      end
    end
  end

  def startMotion
    system("systemctl start motion")
  end

  def stopMotion
    system("systemctl stop motion")
  end

  def timerThread(bot, message, duration, text)
    bot.api.send_message(chat_id: message.chat.id, text: "Ok, will call you back in #{duration} seconds (#{duration / 60}:#{duration % 60} minutes)")

    thread = Thread.new(bot, message, duration, text) do |b, m, d, t|
      sleep duration
      s = "Hey #{m.from.first_name}! #{d} seconds are over!"
      s += " ('#{t}')" unless t.nil? or t.empty?
      b.api.send_message(chat_id: message.chat.id, text: s)
    end

    thread
  end

  def run
    Telegram::Bot::Client.run(@config["telegram_token"]) do |bot|
      threads = []

      threads << Thread.new do
        loop do
          msg = @broadcasts.pop
          #puts "Broadcasting '#{msg}' to #{@chats.count} channels"

          @mutex.synchronize do
            @chats.uniq.each do |chat|
              case msg[:type]
              when :message
                bot.api.send_message(chat_id: chat, text: msg[:message])
              when :video
                bot.api.send_video(chat_id: chat, video: Faraday::UploadIO.new(msg[:video], 'video/mp4'))
              end
            end
          end
        end
      end

      @pingHosts.each do |ph|
        threads << Thread.new do
          p = Net::Ping::ICMP.new(ph, nil, 2)

          loop do
            @mutex.synchronize do
              @pingStatus[ph] = p.ping?
            end
            sleep @pingStatus[ph] ? 10 : 1
          end
        end
      end

      threads << Thread.new do
        motionStarted = false

        loop do
          @mutex.synchronize do
            if @pingStatus.values.any?
              @pingTimeout = 0
            else
              @pingTimeout += 1
            end
          end

          if @pingTimeout > @config["ping_timeout"] && !motionStarted
            broadcast("Ping timeout. #{EMOJI_CAMERA} on!")
            startMotion
            motionStarted = true
          end

          if @pingTimeout == 0 && motionStarted
            broadcast("#{EMOJI_CAMERA} off")
            stopMotion
            motionStarted = false
          end

          sleep 1
        end
      end

      threads << Thread.new do
        loop do
          @monitorDirs.each do |d|
            files = Dir.glob("#{d[:dir]}/*")
            new_files = files - d[:files]
            d[:files] = files

            if new_files.any?
              broadcast("Alert: #{new_files.count} new file(s) in #{d[:dir]}. Go check.")

              new_files.each do |nf|
                next unless /\.avi$/.match(nf)
                #puts "Broadcasting #{nf}"
                broadcast_video(nf)
              end
            end
          end

          sleep 60
        end
      end

      puts "Started. Waiting for messages."

      bot.listen do |message|
        unless @config["telegram_allowed"].include? message.from.id
          bot.api.send_message(chat_id: message.chat.id, text: "Huh. Who are you? I'm not talking to strangers, number #{message.from.id}.")
          next
        end

        next unless message and message.text

        args = message.text.split(' ')
        cmd = args[0][1..-1]

        if @stickers.keys.include? cmd
          sticker = @stickers[cmd].shuffle.first
          bot.api.send_sticker(chat_id: message.chat.id, sticker: sticker)
          next
        end

        case cmd
        when 'start'
          @chats << message.chat.id
          writeChatIDs
          bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
        when 'stop'
          @chats.delete(message.chat.id)
          writeChatIDs
          bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
        when 'hello'
          bot.api.send_message(chat_id: message.chat.id, text: "I'm alive and kicking, #{message.from.first_name}")
        when 'motionstatus'
          s = [
            `systemctl status motion`,
            `uptime`
          ].join("\n").force_encoding("utf-8")

          bot.api.send_message(chat_id: message.chat.id, text: s)
        when 'mount'
          bot.api.send_message(chat_id: message.chat.id, text: `mount`)
        when 'pingstatus'
          s = "Ping status:\n"
          @pingStatus.each { |ph, status| s += "#{ph} is #{status ? 'up' : 'down'}\n" }
          s += "Timeout = #{@pingTimeout}"
          bot.api.send_message(chat_id: message.chat.id, text: s)
        when 'timer'
          break unless args[1]
          duration = parseTime(args[1])
          threads << timerThread(bot, message, duration, args[2])
        when 'egg'
          threads << timerThread(bot, message, 270, "Egg")
        end
      end

      threads.each(&:kill)
    end
  end
end

hcb = HomeControlBot.new
hcb.run