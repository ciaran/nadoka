#
# Copyright (c) 2004-2005 SASADA Koichi <ko1 at atdot.net>
#
# This program is free software with ABSOLUTELY NO WARRANTY.
# You can re-distribute and/or modify this program under
# the same terms of the Ruby's lisence.
#
#
# $Id$
# Create : K.S. 04/04/17 16:50:33
#
#
# You can check RCFILE with following command:
#
#   ruby ndk_config.rb [RCFILE]
#

require 'uri'
require 'socket'
require 'kconv'

require 'ndk/logger'

module Nadoka
  
  class NDK_ConfigBase
    # system
    # 0: quiet, 1: normal, 2: system, 3: debug
    Loglevel     = 2
    Setting_name = 'DefaultSetting',
    
    # client server
    Client_server_port = 6667
    Client_server_host = nil
    Client_server_pass = 'NadokaPassWord' # or nil
    Client_server_acl  = nil
    ACL_Object = nil
    
    # 
    Server_list = [
    # { :host => '127.0.0.1', :port => 6667, :pass => nil }
    ]
    Servers = []

    Reconnect_delay    = 150
    
    Default_channels   = []
    Login_channels     = []

    #
    User       = ENV['USER'] || ENV['USERNAME'] || 'nadokatest'
    Nick       = 'ndkusr'
    Hostname   = Socket.gethostname
    Servername = '*'
    Realname   = 'nadoka user'
    Mode       = nil
    
    Away_Message = 'away'
    Away_Nick    = nil

    Quit_Message = "Quit Nadoka #{::Nadoka::NDK_Version} - http://www.atdot.net/nadoka/"
    
    #
    Channel_info = {}
    # log
    Default_log = '${setting_name}-${channel_name}/%y%m%d.log'
    System_log  = '${setting_name}-system.log'
    Debug_log   = $stdout
    FilenameEncoding = 'euc'

    SystemLog_TimeFormat = '%y%m%d-%H:%M:%S'
    Log_TimeFormat       = '%H:%M:%S'
    BackLog_Lines        = 20
    
    Log_MessageFormat = {
      'PRIVMSG' => '<{user}> {msg}',
      'NOTICE'  => '{{user}} {msg}',
      'JOIN'    => '+ {user} to {ch}',
      'NICK'    => '* {user} -> {newnick}',
      'QUIT'    => '- {user} ({msg})',
      'PART'    => '- {user} from {ch}',
      'KICK'    => '- {user} kicked by {kicker} ({msg}) from {ch}',
      'MODE'    => '* {user} changed mode ({msg})',
      'TOPIC'   => '<{ch} TOPIC> {msg}',
      'SYSTEM'  => '[NDK] {msg}'
    }
    
    # dirs
    Plugins_dir = './plugins'
    Log_dir     = './log'
    
    # bots
    BotConfig   = []

    # filters
    Privmsg_Filter = []
    Notice_Filter  = []

    # ...
    Privmsg_Filter_light = []
    Nadoka_server_name   = 'NadokaProgram'
    
    def self.inherited subklass
      ConfigClass << subklass
    end
  end
  ConfigClass = [NDK_ConfigBase]
  
  class NDK_Config
    NDK_ConfigBase.constants.each{|e|
      eval %Q{
        def #{e.downcase}
          @config['#{e.downcase}'.intern]
        end
      }
    }
    
    def initialize manager, rcfile = nil
      @manager = manager
      @bots = []
      load_config(rcfile || './nadokarc')
    end
    attr_reader :config, :bots, :logger

    def remove_previous_setting
      # remove setting class
      klass = ConfigClass.shift
      while k = ConfigClass.shift
        Object.module_eval{
          remove_const(k.name)
        }
      end
      ConfigClass.push(klass)


      # clear required files
      RequiredFiles.replace []

      # remove current NadokaBot
      Object.module_eval %q{
        remove_const :NadokaBot
        module NadokaBot
          def self.included mod
            Nadoka::NDK_Config::BotClasses['::' + mod.name.downcase] = mod
          end
        end
      }
      
      # clear bot class
      BotClasses.each{|k, v|
        Object.module_eval{
          if /\:\:/ !~ k.to_s && const_defined?(v.name)
            remove_const(v.name)
          end
        }
      }
      BotClasses.clear
      
      # destruct bot instances
      @bots.each{|bot|
        bot.bot_destruct
      }
      @bots = []
    end

    def load_bots
      # for compatibility
      return load_bots_old if @config[:botconfig].kind_of? Hash
      @bots = @config[:botconfig].map{|bot|
        if bot.kind_of? Hash
          name = bot[:name]
          cfg  = bot
          raise "No bot name specified. Check rcfile." unless name
        else
          name = bot
          cfg  = nil
        end
        load_botfile name.to_s.downcase
        make_bot_instance name, cfg
      }
    end

    # for compatibility
    def load_bots_old
      (@config[:botfiles] + (@config[:defaultbotfiles]||[])).each{|file|
        load_botfile file
      }
      
      @config[:botconfig].keys.each{|bk|
        bkn = bk.to_s
        bkni= bkn.intern
        
        unless BotClasses.any?{|n, c| n == bkni}
          if @config[:botfiles]
            raise "No such BotClass: #{bkn}"
          else
            load_botfile "#{bkn.downcase}.nb"
          end
        end
      }
      
      @bots = BotClasses.map{|bkname, bk|
        if @config[:botconfig].has_key? bkname
          if (cfg = @config[:botconfig][bkname]).kind_of? Array
            cfg.map{|c|
              make_bot_instance bk, c
            }
          else
            make_bot_instance bk, cfg
          end
        else
          make_bot_instance bk, nil
        end
      }.flatten
    end
    
    def load_config(rcfile)
      load(rcfile) if rcfile
      
      @config = {}
      klass = ConfigClass.last
      klass.constants.each{|e|
        @config[e.downcase.intern] = klass.const_get(e)
      }

      if $NDK_Debug
        @config[:loglevel] = 3
      end
      
      @logger = NDK_Logger.new(@manager, self)
      @logger.slog "load config: #{rcfile}"

      if svrs = klass.const_get(:Servers)
        svl = []
        svrs.each{|si|
          ports = si[:port] || 6667
          host  = si[:host]
          pass  = si[:pass]
          if ports.respond_to? :each
            ports.each{|port|
              svl << {:host => host, :port => port,  :pass => pass}
            }
          else
            svl <<   {:host => host, :port => ports, :pass => pass}
          end
        }
        @config[:server_list] = svl
      end

      # treat with channel information
      if chs = klass.const_get(:Channel_info)
        dchs = []
        lchs = []
        cchs = {}
        
        chs.each{|ch, setting|
          ch = identical_channel_name(ch)
          
          if !setting[:timing] || setting[:timing] == :startup
            dchs << ch
          elsif setting[:timing] == :login
            lchs << ch
          end
          cchs[ch] = setting
        }
        chs.replace cchs
        @config[:default_channels] = dchs
        @config[:login_channels]   = lchs
      end

      # acl setting
      if @config[:client_server_acl] && !@config[:acl_object]
        require 'drb/acl'
        
        acl = @config[:client_server_acl].strip.split(/\s+/)
        @config[:acl_object] = ACL.new(acl)
        logger.slog "ACL: #{acl.join(' ')}"
      end

      # load bots
      load_bots

      GC.start
    end

    def ch_config ch, key
      channel_info[ch] && channel_info[ch][key]
    end
    
    def canonical_channel_name ch
      ch = ch.sub(/^\!.{5}/, '!')
      identical_channel_name ch
    end

    def identical_channel_name ch
      # use 4 gsub() because of the compatibility of RFC2813(3.2)
      ch.toeuc.downcase.tr('[]\\~', '{}|^').tojis
    end

    def log_file_name ch
      ch = ch.sub(/^\!.{5}/, '!')
      
    end

    def escape_log_file_name ch
      
    end
    
    def make_channel_from_server rch
      cn = canonical_channel_name rch
      id = identical_channel_name rch
      ln = log_file_name rch
      ChannelName.new(rch, id, cn, ln)
    end

    def make_channel_from_configuration rch
      ln  = escape_log_file_name rch
      rch = raw_channel_name rch
      id  = cn = identical_channel_name rch
      ChannelName.new(rch, id, cn, ln)
    end
    
    def make_bot_instance bk, cfg
      bk = BotClasses[bk.to_s.downcase.intern] unless bk.kind_of? Class
      bot = bk.new @manager, self, cfg || {}
      @logger.slog "bot instance: #{bot.bot_state}"
      bot
    end
    
    def load_botfile file
      loaded = false
      
      if @config[:plugins_dir].respond_to? :each
        @config[:plugins_dir].each{|dir|
          if load_file "#{dir}/#{file}.nb"
            loaded = true
            break
          end
        }
      else
        loaded = load_file "#{@config[:plugins_dir]}/#{file}.nb"
      end

      unless loaded
        raise "No such bot file: #{file}"
      end
    end

    def load_file file
      if FileTest.exist? file
        Nadoka.require file
        true
      else
        false
      end
    end
    
    RequiredFiles       = []
    BotClasses          = {}
  end

  def self.require file
    return if NDK_Config::RequiredFiles.include? file
    
    NDK_Config::RequiredFiles.push file
    begin
      ret = ::Kernel.load(file)
    rescue
      NDK_Config::RequiredFiles.pop
      raise
    end
    ret
  end
end

module NadokaBot
  # empty module for bot namespace
  # this module is reloadable
  def self.included mod
    Nadoka::NDK_Config::BotClasses['::' + mod.name.downcase] = mod
  end
end

if $0 == __FILE__
  require 'pp'
  pp Nadoka::NDK_Config.new(nil, ARGV.shift)
end

