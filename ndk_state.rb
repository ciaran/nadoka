#
# Copyright (c) 2004 SASADA Koichi <ko1 at atdot.net>
#
# This program is free software with ABSOLUTELY NO WARRANTY.
# You can re-distribute and/or modify this program under
# the same terms of the Ruby's lisence.
#
#
# $Id: ndk_state.rb,v 1.10 2004/05/01 05:40:16 ko1 Exp $
# Create : K.S. 04/04/20 10:42:27
#

module Nadoka
  class NDK_State
    class ChannelState
      def initialize name
        @name  = name
        @topic = nil
        @member= {}

        # member data
        # { "nick" => "mode", ... }
      end

      attr_accessor :topic
      attr_reader   :member

      # get members nick array
      def members
        @member.keys
      end

      # get user's mode
      def mode nick
        @member[nick]
      end
      
      def names
        @member.map{|nick, mode|
          prefix = if /o/ =~ mode
            '@'
          elsif /v/ =~ mode
            '+'
          else
            ''
          end
          prefix + nick
        }
      end
      
      def state
        '='
      end
      
      #####################################
      
      def on_join nick, mode=''
        @member[nick] = mode
      end
      
      def on_part nick
        @member.delete nick
      end
      
      def on_nick nick, newnick
        if @member.has_key? nick
          @member[newnick] = @member[nick]
          @member.delete nick
        end
      end

      MODE_WITH_NICK_ARG = 'ov'
      MODE_WITH_ARGS     = 'klbeI'
      MODE_WITHOUT_ARGS  = 'aimnqpsrt'
      
      def on_mode nick, args
        if @member.has_key? nick
          while mode = args.shift
            modes = mode.split(//)
            flag  = modes.shift
            modes.each{|m|
              if MODE_WITH_NICK_ARG.include? m
                chg_mode args.shift, flag, m
              elsif MODE_WITH_ARGS.include? m
                args.shift
              elsif MODE_WITHOUT_ARGS.include? m
                # ignore
              end
            }
          end
        end
      end

      def chg_mode nick, flag, mode
        if @member.has_key? nick
          if flag == '+'
            @member[nick] += mode
          elsif flag == '-'
            @member[nick].gsub!(mode, '')
          end
        end
      end

      def to_s
        str = ''
        @member.each{|k, v|
          str << "#{k}: #{v}, "
        }
        str
      end
    end
    
    def initialize manager
      @manager = manager
      @config  = nil
      @logger  = nil
      
      @current_nick     = nil
      @original_nick    = nil
      @current_channels = {}
      @backlog = []
    end
    attr_reader :backlog
    attr_reader :current_channels
    attr_reader :current_nick
    attr_accessor :original_nick
    attr_writer :logger, :config
    
    def nick=(n)
      @current_nick=n
    end
    
    def nick
      @original_nick || @current_nick
    end

    def nick_succ
      if /^(.+)(\d)$/ =~ @current_nick
        @current_nick = $1 + ($2.to_i + 1).to_s
      else
        @current_nick += '0'
      end
      @current_nick
    end
    
    def channels
      @current_channels.keys
    end

    def channel_member ch
      if @current_channels.has_key? ch
        @current_channels[ch].members
      else
        []
      end
    end

    #
    def backlog_push msg
      if @config.backlog_lines == 0
        if @manager.client_num == 0
          @backlog << msg
        end
      else
        @backlog << msg
        while @backlog.size > @config.backlog_lines
          @backlog.shift
        end
      end
    end

    def backlog_clear
      @backlog = []
    end
    
    #
    def on_join user, ch
      msg = "+ #{user} to #{ch}"
      if user == nick
        @logger.clog ch, msg
        chs = @current_channels[ch] = ChannelState.new(ch)
      else
        if @current_channels.has_key? ch
          @logger.clog ch, msg
          @current_channels[ch].on_join(user)
        end
      end
      @logger.log msg
    end
    
    def on_part user, ch
      msg = "- #{user} from #{ch}"
      if user == nick
        @logger.clog ch, msg
        @current_channels.delete ch
      else
        if @current_channels.has_key? ch
          @logger.clog ch, msg
          @current_channels[ch].on_part user
        end
      end
      @logger.log msg
    end
    
    def on_nick user, newnick
      msg = "#{user} -> #{newnick}"
      if user == nick
        @current_nick = newnick
      end
      @current_channels.each{|ch, chs|
        if chs.on_nick user, newnick
          @logger.clog ch, msg
        end
      }
      @logger.log msg
    end
    
    def on_quit user, qmsg
      if user == nick
        @current_channels = {} # clear
      else
        @current_channels.each{|ch, chs|
          if chs.on_part(user)
            @logger.clog ch, "- #{user} from #{ch}(#{qmsg})"
          end
        }
      end
      @logger.log "- #{user}(#{qmsg})"
    end
    
    def on_mode user, ch, args
      if @current_channels.has_key? ch
        @current_channels[ch].on_mode user, args
      end
    end

    def on_topic user, ch, topic
      if @current_channels.has_key? ch
        @logger.clog ch, "<#{ch}:#{user} TOPIC> #{topic}"
        @current_channels[ch].topic = topic
      end
      @logger.log "<#{ch} TOPIC> #{topic}"
    end
    
    def on_332 ch, topic
      if @current_channels.has_key? ch
        @current_channels[ch].topic = topic
        @logger.clog ch, "<#{ch} TOPIC> #{topic}"
      end
      @logger.log "<#{ch} TOPIC> #{topic}"
    end
    
    # RPL_NAMREPLY
    # ex) :lalune 353 test_ndk = #nadoka :test_ndk ko1_nmdk
    # 
    def on_353 ch, users
      if @current_channels.has_key? ch
        chs = @current_channels[ch]
        users.split(/ /).each{|e|
          /^([\@\+])?(.+)/ =~ e
          case $1
          when '@'
            mode = 'o'
          when '+'
            mode = 'v'
          else
            mode = ''
          end
          chs.on_join $2, mode
        }
      end
    end
    
  end
end

