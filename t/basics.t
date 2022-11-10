use Mojo::Base -strict;
use Test2::V0;
use Mojo::File qw(tempfile);
use Mojo::Server::DaemonControl;

subtest 'Proxy attributes' => sub {
  my $dctl = Mojo::Server::DaemonControl->new(
    graceful_timeout   => 119,
    heartbeat_interval => 4,
    heartbeat_timeout  => 49,
    workers            => 3,
  );

  like $dctl->pid_file, qr{basics\.t\.pid$}, 'default pid_file';
  is $dctl->graceful_timeout,   119, 'constructor graceful_timeout';
  is $dctl->heartbeat_interval, 4,   'constructor heartbeat_interval';
  is $dctl->heartbeat_timeout,  49,  'constructor heartbeat_timeout';
  is $dctl->workers,            3,   'constructor workers';
  for my $n (qw(graceful_timeout heartbeat_interval heartbeat_timeout listen pid_file workers)) {
    is $dctl->$n, $dctl->_prefork->$n, "prefork $n";
  }
};

subtest 'PID file' => sub {
  my $pid_file = tempfile;
  my $dctl     = Mojo::Server::DaemonControl->new(pid_file => $pid_file);

  is $dctl->pid_file,  "$pid_file", 'pid_file proxy attribute';
  is $dctl->check_pid, undef,       'no pid';
  $dctl->ensure_pid_file($$);
  is $dctl->check_pid, $$, 'wrote pid';

  undef $dctl;
  ok !-e $pid_file, 'pid file got cleaned up';
};

done_testing;
