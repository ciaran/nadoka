#
# Copyright (c) 2004 SASADA Koichi <ko1 at atdot.net>
#
# This program is free software with ABSOLUTELY NO WARRANTY.
# You can re-distribute and/or modify this program under
# the same terms of the Ruby's lisence.
#
#
# $Id: ndk_client.rb,v 1.22 2004/05/01 04:55:49 ko1 Exp $
# Create : K.S. 04/04/17 16:50:10
#

require 'thread'

module Nadoka
  class NDK_Client
    def initialize config, sock, manager
      @sock   = sock

      @config = config
      @logger = config.logger
      @manager= manager
      @state  = manager.state

      @queue  = Queue.new
      @remote_host = @sock.peeraddr[2]
      @thread = Thread.current
      @connected = false

      # client information
      @realname = nil
      @hostname = nil
    end
    
    def start
      send_thread = Thread.new{
        begin
          while q = @queue.pop
            begin
              send_to_client q
            end
          end
        rescue Exception => e
          @manager.ndk_error e
          raise
        end
      }
      begin
        if login
          @connected = true
          begin
            @manager.invoke_event :leave_away, @manager.client_count
            @manager.invoke_event :invoke_bot, :client_login, @manager.client_count
            while msg = recv_from_client
              send_from_client msg, self
            end
          rescue NDK_QuitClient
            # finish
          ensure
            @manager.invoke_event :invoke_bot, :client_logout, @manager.client_count
          end
        end
      rescue Exception
        @manager.ndk_error $!
      ensure
        @logger.slog "Client #{@realname}@#{@remote_host} disconnected."
        @sock.close
        send_thread.kill if send_thread && send_thread.alive?
      end
    end
    
    def kill
      @thread && @thread.kill
    end
    
    def recv_from_client
      begin
        str = @sock.gets
        if str
          @logger.dlog "[C>] #{str}"
          ::RICE::Message::parse str
        end
      rescue ::RICE::UnknownCommand, ::RICE::InvalidMessage
        @manager.ndk_error $!
        retry
      end
    end
    
    def push msg
      if @connected
        @queue << msg
      end
    end
    alias << push
    
    def login
      pass = nil
      nick = nil
      @username = nil
      
      while (nick == nil) || (@username == nil)
        msg = recv_from_client
        return nil if msg == nil
        
        case msg.command
        when 'USER'
          @username, @hostname, @servername, @realname = msg.params
        when 'NICK'
          nick = msg.params[0]
        when 'PASS'
          pass = msg.params[0]
        else
          raise "Illegal login sequence: #{msg}"
        end
      end
      
      if @config.client_server_pass && (@config.client_server_pass != pass)
        send_reply Rpl.err_passwdmismatch(nick, "Password Incorrect.")
        return false
      end
      
      send_reply Rpl.rpl_welcome( nick,
        'Welcome to the Internet Relay Network'+"#{nick}! #{@username}@#{@remote_host}")
      send_reply Rpl.rpl_yourhost(nick, "Your host is nadoka, running version #{NDK_Version}")
      send_reply Rpl.rpl_created( nick, 'This server was created ' + NDK_Created.to_s)
      send_reply Rpl.rpl_myinfo(  nick, "nadoka", "#{NDK_Version}", "aoOirw", "abeiIklmnoOpqrstv")

      send_motd
      
      send_command Cmd.nick(@manager.state.nick), nick
      nick = @manager.state.nick

      @manager.state.current_channels.each{|ch, chs|
        send_command Cmd.join(ch)
        if chs.topic
          send_reply Rpl.rpl_topic(@state.nick, ch, chs.topic)
        else
          send_reply Rpl.rpl_notopic(@state.nick, ch, "No topic is set.")
        end
        send_reply Rpl.rpl_namreply(  @state.nick, chs.state, ch, chs.names.join(' '))
        send_reply Rpl.rpl_endofnames(@state.nick, ch, "End of NAMES list.")
      }

      send_backlog
      
      @logger.slog "Client #{@realname}@#{@remote_host} connected."
      true
    end
    
    def send_motd
      send_reply Rpl.rpl_motdstart(@state.nick, "- Nadoka Message of the Day - ")
      send_reply Rpl.rpl_motd(@state.nick, "- Enjoy IRC chat with Nadoka chan!")
      send_reply Rpl.rpl_motd(@state.nick, "- ")
      send_reply Rpl.rpl_endofmotd(@state.nick, "End of MOTD command.")
    end

    def send_backlog
      @manager.state.backlog.each{|line|
        send_msg Cmd.notice(@manager.state.nick, line)
      }
      if @config.backlog_lines == 0
        @manager.state.backlog_clear
      end
    end
    
    # :who!~username@host CMD ..
    def send_command cmd, nick = @manager.state.nick
      msg = add_prefix(cmd, "#{nick}!#{@username}@#{@remote_host}")
      send_msg msg
    end

    # :serverinfo REPL ...
    def send_reply repl
      msg = add_prefix(repl, @config.nadoka_server_name)
      send_msg msg
    end

    def send_msg msg
      @logger.dlog "[C<] #{msg}"
      @sock.puts msg.to_s
    end
    
    def send_to_client msg
      if /^\d+/ =~ msg.command
        send_reply msg
      else
        send_msg msg
      end
    end
    
    def add_prefix cmd, prefix = "#{@manager.state.nick}!#{@username}@#{@remote_host}"
      cmd.prefix = prefix
      cmd
    end

    ::RICE::Command.regist_command('NADOKA')
    
    # client -> server handling
    def send_from_client msg, from
      until @manager.connected
        Thread.pass
      end
      
      case msg.command
      when 'NADOKA'
        nadoka_client_command msg.params[0], msg.params[1..-1]
        return
      when 'QUIT'
        raise NDK_QuitClient
      when 'PRIVMSG', 'NOTICE'
        if /^\/nadoka/ =~ msg.params[1]
          _, cmd, *args = msg.params[1].split(/\s+/)
          nadoka_client_command cmd, args
          return
        end
        if @manager.send_to_bot(:client_privmsg, self, msg.params[0], msg.params[1])
          @manager.send_to_server msg
          @manager.send_to_clients_otherwise msg, from
        end
      else
        @manager.send_to_server msg
      end
    end
    
    def nadoka_client_command cmd, args
      cmd ||= ''
      case cmd.upcase
      when 'QUIT'
        @manager.invoke_event :quit_program
        self << Cmd.notice(@state.nick, 'nadoka will be quit. bye!')
      when 'RESTART'
        @manager.invoke_event :restart_program, self
        self << Cmd.notice(@state.nick, 'nadoka will be restart. see you later.')
      when 'RELOAD'
        @manager.invoke_event :reload_config, self
      when 'HELP'
        self << Cmd.notice(@state.nick, 'available: QUIT, RESTART, RELOAD, HELP')
        if args[1]
          self << Cmd.notice(@state.nick, "#{args[1]}: ")
        end
      else
        if @manager.send_to_bot :nadoka_command, self, cmd, *args
          self << Cmd.notice(@state.nick, 'No such command. Use /NADOKA HELP.')
        end
      end
    end
  end
end

