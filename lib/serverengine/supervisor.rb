#
# ServerEngine
#
# Copyright (C) 2012-2013 Sadayuki Furuhashi
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module ServerEngine

  class Supervisor
    include ConfigLoader

    def initialize(server_module, worker_module, load_config_proc={}, &block)
      @server_module = server_module
      @worker_module = worker_module

      @detach_flag = BlockingFlag.new
      @stop = false

      @pm = ProcessManager.new(
        auto_tick: false,
        graceful_kill_signal: Daemon::Signals::GRACEFUL_STOP,
        immediate_kill_signal: Daemon::Signals::IMMEDIATE_STOP,
        enable_heartbeat: true,
        auto_heartbeat: true,
      )

      super(load_config_proc, &block)

      @create_server_proc = Supervisor.create_server_proc(server_module, worker_module, @config)
      @server_process_name = @config[:server_process_name]

      @restart_server_process = !!@config[:restart_server_process]
      @enable_detach = !!@config[:enable_detach]
      @exit_on_detach = !!@config[:exit_on_detach]
      @disable_reload = !!@config[:disable_reload]

      @command_pipe = @config.fetch(:command_pipe, nil)
    end

    # server is available after start_server() call.
    attr_reader :server

    def reload_config
      super

      @server_detach_wait = @config[:server_detach_wait] || 10.0
      @server_restart_wait = @config[:server_restart_wait] || 1.0

      @pm.configure(@config, prefix: 'server_')

      nil
    end

    module ServerInitializer
      def initialize
        reload_config
      end
    end

    def self.create_server_proc(server_module, worker_module, config)
      wt = config[:worker_type] || 'embedded'
      case wt
      when 'embedded'
        server_class = EmbeddedServer
      when 'process'
        server_class = MultiProcessServer
      when 'thread'
        server_class = MultiThreadServer
      when 'spawn'
        server_class = MultiSpawnServer
      else
        raise ArgumentError, "unexpected :worker_type option #{wt}"
      end

      lambda {|load_config_proc,logger|
        s = server_class.new(worker_module, load_config_proc)
        s.logger = logger
        s.extend(ServerInitializer)
        s.extend(server_module) if server_module
        s.instance_eval { initialize }
        s
      }
    end

    def create_server(logger)
      @server = @create_server_proc.call(@load_config_proc, logger)
    end

    def _stop(stop_graceful)
      if @command_pipe
        @command_pipe.write stop_graceful ? "GRACEFUL_STOP\n" : "IMMEDIATE_STOP\n"
        @command_pipe.close
        @command_pipe = nil
      else
        send_signal(stop_graceful ? Daemon::Signals::GRACEFUL_STOP : Daemon::Signals::IMMEDIATE_STOP)
      end
    end
    private :_stop

    def stop(stop_graceful)
      @stop = true
      _stop(stop_graceful)
    end

    def restart(stop_graceful)
      reload_config
      @logger.reopen! if @logger
      if @restart_server_process
        _stop(stop_graceful)
      else
        if @command_pipe
          @command_pipe.write stop_graceful ? "GRACEFUL_RESTART\n" : "IMMEDIATE_RESTART\n"
        else
          send_signal(stop_graceful ? Daemon::Signals::GRACEFUL_RESTART : Daemon::Signals::IMMEDIATE_RESTART)
        end
      end
    end

    def reload
      unless @disable_reload
        reload_config
      end
      @logger.reopen! if @logger
      if @command_pipe
        @command_pipe.write "RELOAD\n"
      else
        send_signal(Daemon::Signals::RELOAD)
      end
    end

    def detach(stop_graceful)
      if @enable_detach
        @detach_flag.set!
        _stop(stop_graceful)
      else
        stop(stop_graceful)
      end
    end

    def install_signal_handlers
      s = self
      if @command_pipe
        Thread.new do
          until @command_pipe.closed?
            case @command_pipe.gets.chomp
            when "GRACEFUL_STOP"
              s.stop(true)
            when "IMMEDIATE_STOP"
              s.stop(false)
            when "GRACEFUL_RESTART"
              s.restart(true)
            when "IMMEDIATE_RESTART"
              s.restart(false)
            when "RELOAD"
              s.reload
            when "DETACH"
              s.detach(true)
            when "DUMP"
              Sigdump.dump
            end
          end
        end
      else
        SignalThread.new do |st|
          st.trap(Daemon::Signals::GRACEFUL_STOP) { s.stop(true) }
          st.trap(Daemon::Signals::IMMEDIATE_STOP) { s.stop(false) }
          st.trap(Daemon::Signals::GRACEFUL_RESTART) { s.restart(true) }
          st.trap(Daemon::Signals::IMMEDIATE_RESTART) { s.restart(false) }
          st.trap(Daemon::Signals::RELOAD) { s.reload }
          st.trap(Daemon::Signals::DETACH) { s.detach(true) }
          st.trap(Daemon::Signals::DUMP) { Sigdump.dump }
        end
      end
    end

    def main
      # just in case Supervisor is not created by Daemon
      create_logger unless @logger

      @pmon = start_server

      while true
        # keep the child process alive in this loop
        until @detach_flag.wait(0.5)
          if try_join
            return if @stop   # supervisor stoppped explicitly

            # child process died unexpectedly.
            # sleep @server_detach_wait sec and reboot process
            @pmon = reboot_server
          end
        end

        wait_until = Time.now + @server_detach_wait
        while (w = wait_until - Time.now) > 0
          break if try_join
          sleep [0.5, w].min
        end

        return if @exit_on_detach

        @detach_flag.reset!
      end
    end

    def logger=(logger)
      super
      @pm.logger = @logger
    end

    private

    def send_signal(sig)
      @pmon.send_signal(sig) if @pmon
      nil
    end

    def try_join
      if stat = @pmon.try_join
        @logger.info "Server finished#{@stop ? '' : ' unexpectedly'} with #{ProcessManager.format_join_status(stat)}"
        @pmon = nil
        return stat
      else
        @pm.tick
        return false
      end
    end

    def start_server
      unless ServerEngine.windows?
        s = create_server(logger)
        @last_start_time = Time.now

        begin
          m = @pm.fork do
            $0 = @server_process_name if @server_process_name
            s.install_signal_handlers

            s.main
          end

          return m
        ensure
          s.after_start
        end
      else
        inpipe, @command_pipe = IO.pipe
        m = @pm.spawn(*Array(config[:windows_daemon_cmdline]), in: inpipe)
        inpipe.close

        return m
      end
    end

    def reboot_server
      # try reboot for ever until @detach_flag is set
      while true
        wait = @server_restart_wait - (Time.now - @last_start_time)
        if @detach_flag.wait(wait > 0 ? wait : 0.1)
          break
        end

        begin
          return start_server
        rescue
          ServerEngine.dump_uncaught_error($!)
        end
      end

      return nil
    end
  end

end
