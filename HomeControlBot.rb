#!/usr/bin/env ruby

# -*- coding: utf-8 -*-

require 'yaml'
require 'telegram/bot'
require 'thread'
require 'net/ping'

include Net

class HomeControlBot

  def initialize()
    @mutex = Mutex.new

    @config = YAML.load(File.read("HomeControlBot.yml"))
    @chats = IO.readlines("HomeControlBot.chatids").map { |s| s.to_i } rescue []
    @chats.uniq!

    @pingStatus = {}
    @pingHosts = @config["ping_hosts"]
    @pingHosts.each { |ph| @pingStatus[ph] = false }

    @monitorDirs = @config["monitor_dirs"].map do |dir|
      { dir: dir, count: countFiles(dir) }
    end

    @broadcasts = Queue.new

    @motionStarted = false
    @pingTimeout = 0
  end

  def broadcast(msg)
    @broadcasts.push(msg)
  end

  def countFiles(dir)
    d = Dir.new(dir)
    count = 0
    d.each { |f| count += 1 }

    count
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

  def checkPings
    any = false

    @pingStatus.each do |ph, status|
      any = true if status == true
    end

    if any
      @pingTimeout = 0
    else
      @pingTimeout += 1
    end

    if @pingTimeout > 3 && !@motionStarted
      broadcast("Hey, have your mobiles all left the flat? Enabling the camera now!")
      startMotion
      @motionStarted = true
    end

    if @pingTimeout == 0 && @motionStarted
      broadcast("Ah, there you are! Camera is off again, no worries!")
      stopMotion
      @motionStarted = false
    end
  end

  def dispatchMessage(bot, message)
    unless @config["telegram_allowed"].include? message.from.id
      bot.api.send_message(chat_id: message.chat.id, text: "Huh. Who are you? I'm not talking to strangers.")
      return
    end

    case message.text
    when '/start'
      chats << message.chat.id
      writeChatIDs(chats)
      bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
    when '/stop'
      chats.delete(message.chat.id)
      writeChatIDs(chats)
      bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
    when '/hello'
      bot.api.send_message(chat_id: message.chat.id, text: "I'm alive and kicking, #{message.from.first_name}")
    when '/motionstatus'
      s = [
        `systemctl status motion`,
        `uptime`
      ].join("\n").force_encoding("utf-8")

      bot.api.send_message(chat_id: message.chat.id, text: s)
    when '/mount'
      bot.api.send_message(chat_id: message.chat.id, text: `mount`)
    when '/pingstatus'
      s = "Ping status:\n"
      @pingStatus.each { |ph, status| s += "#{ph} is #{status ? 'up' : 'down'}\n" }
      s += "Timeout = #{@pingTimeout}"
      bot.api.send_message(chat_id: message.chat.id, text: s)
    end
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
              bot.api.send_message(chat_id: chat, text: msg)
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
              checkPings
            end
            sleep @pingStatus[ph] ? 10 : 1
          end
        end
      end

      threads << Thread.new do
        loop do
          @monitorDirs.each do |d|
            count = countFiles(d[:dir])
            if count != d[:count]
              broadcast("Alert: #{count - d[:count]} new file(s) in #{d[:dir]}. Go check.")
            end

            d[:count] = count
          end

          sleep 60
        end
      end

      puts "Started. Listening for messages."

      bot.listen do |message|
        dispatchMessage(bot, message)
      end

      threads.each(&:kill)
    end
  end
end

hcb = HomeControlBot.new
hcb.run