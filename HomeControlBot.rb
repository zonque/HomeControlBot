#!/usr/bin/env ruby

# -*- coding: utf-8 -*-

require 'yaml'
require 'telegram/bot'
require 'net/ping'

include Net

config = YAML.load(File.read("HomeControlBot.yml"))
chats = IO.readlines("HomeControlBot.chatids").map { |s| s.to_i } rescue []

pingStatus = {}
pingHosts = config["ping_hosts"]
pingHosts.each { |ph| pingStatus[ph] = false }

def countFiles(dir)
  d = Dir.new(dir)
  count = 0
  d.each { |f| count += 1 }

  count
end

monitorDirs = config["monitor_dirs"].map do |dir|
  { dir: dir, count: countFiles(dir) }
end

broadcasts = Queue.new

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

$started = false
$timeout = 0

def checkPings
  any = false

  pingStatus.each do |ph, status|
    any = true if status == true
  end

  if any
    $timeout = 0
  else
    $timeout += 1
  end

  if $timeout > 3 && !$started
    broadcasts.push("Hey, have your mobiles all left the flat? Enabling the camera now!")
    startMotion
    $started = true
  end

  if $timeout == 0 && $started
    broadcasts.push("Ah, there you are! Camera is off again, no worries!")
    stopMotion
    $started = false
  end
end

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

  pingHosts.each do |ph|
    threads << Thread.new do
      p = Net::Ping::ICMP.new(ph, nil, 2)

      loop do
        pingStatus[ph] = p.ping?
        checkPings
        sleep pingStatus[ph] ? 10 : 1
      end
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
    when '/pingstatus'
      s = "Ping status:\n"
      pingStatus.each { |ph, status| s += "#{ph} is #{status ? 'up' : 'down'}\n" }
      bot.api.send_message(chat_id: message.chat.id, text: s)
    end
  end

  threads.each(&:kill)
end
