#!/usr/bin/env ruby

# -*- coding: utf-8 -*-

require 'yaml'
require 'telegram/bot'
require 'net/ping'

include Net

config = YAML.load(File.read("HomeControlBot.yml"))
pingHosts = config["ping_hosts"].map { |h| Net::Ping::ICMP.new(h) } rescue []
chats = IO.readlines("HomeControlBot.chatids").map { |s| s.to_i } rescue []

def countFiles(dir)
  d = Dir.new(dir)
  count = 0
  d.each { |f| count += 1 }

  count
end

def writeChatIDs(chats)
  chats.uniq!

  File.open("HomeControlBot.chatids", 'w') do |f|
    chats.each do |c|
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

monitorDirs = config["monitor_dirs"].map do |dir|
  { dir: dir, count: countFiles(dir) }
end

broadcasts = Queue.new

Telegram::Bot::Client.run(config["telegram_token"]) do |bot|
  threads = []

  threads << Thread.new do
    loop do
      msg = broadcasts.pop

      chats.uniq.each do |chat|
        bot.api.send_message(chat_id: chat, text: msg)
      end

      puts "Broadcasting '#{msg}' to #{chats.count} channels"
    end
  end

  threads << Thread.new do
    timeout = 0
    started = false

    loop do
      any = false

      pingHosts.each do |h|
        any = true if h.ping?
      end

      if any
        timeout = 0
      else
        timeout += 1
      end

      if timeout > 5 && !started
        broadcasts.push("Hey, have your mobiles all left the flat? Enabling the camera now!")
        startMotion
        started = true
      end

      if timeout == 0 && started
        broadcasts.push("Ah, there you are! Camera is off again, no worries!")
        stopMotion
        started = false
      end

      sleep 5
    end
  end

  threads << Thread.new do
    loop do
      monitorDirs.each do |d|
        count = countFiles(d[:dir])
        if count != d[:count]
          broadcasts.push("Alert: #{count - d[:count]} new file(s) in #{d[:dir]}. Go check.")
        end

        d[:count] = count
      end

      sleep 60
    end
  end

  puts "Started. Listening for messages."

  bot.listen do |message|
    unless config["telegram_allowed"].include? message.from.id
      bot.api.send_message(chat_id: message.chat.id, text: "Huh. Who are you? I'm not talking to strangers.")
      next
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
    end
  end

  threads.each(&:kill)
end
