use Mojo::Base -strict;
use Test2::V0;
use Mojo::File qw(curfile);
use Mojo::IOLoop::Server;
use Mojo::Promise;
use Mojo::Server::DaemonControl;
use Mojo::UserAgent;

my $app    = curfile->dirname->child(qw(my-app my-app.pl));
my $port   = Mojo::IOLoop::Server->generate_port;
my $listen = Mojo::URL->new("http://127.0.0.1:$port");
my $ua     = Mojo::UserAgent->new;

subtest 'run and spawn if reaped' => sub {
  my $dctl = Mojo::Server::DaemonControl->new(listen => [$listen], workers => 2);
  my %pid;

  $dctl->on(
    spawn => sub {
      my ($dctl, $pid) = @_;
      $pid{$pid} = 1;

      my $n_pids = keys %pid;
      Mojo::Promise->timer(0.2)->then(sub {
        return $ua->get_p($listen->clone->path('/pid')->to_string);
      })->then(sub {
        my $tx = shift;

        my $daemon_pid = $tx->res->body =~ m!pid=(\d+)! && $1;
        $pid{$daemon_pid} += 10 if $daemon_pid;

        return $n_pids >= 3 ? $dctl->stop : return ok kill(TERM => $daemon_pid), "TERM $daemon_pid";
      })->catch(sub {
        ok 0, "TERM $pid $_[0]";
      })->wait;
    }
  );

  $dctl->on(reap => sub { $pid{$_[1]} += 100 });
  $dctl->run($app);

  is int(keys %pid), 3,               'workers';
  is [values %pid],  [111, 111, 111], 'reaped';
};

done_testing;
