
describe ServerEngine::MultiSpawnServer do
  include_context 'test server and worker'

  context 'with command_sender=pipe' do
    it 'starts worker processes' do
      config = {workers: 2, command_sender: 'pipe', log_stdout: false, log_stderr: false}

      s = ServerEngine::MultiSpawnServer.new(TestWorker) { config.dup }
      t = Thread.new { s.main }

      begin
        wait_for_fork

        test_state(:worker_run).should == 2
      ensure
        s.stop(true)
        t.join
      end
    end
  end
end
