use Mojo::Base -strict;
use Test2::V0;
use Mojo::File qw(curfile);
use Mojo::IOLoop::Server;
use Mojo::Promise;
use Mojo::Server::DaemonControl;
use Mojo::UserAgent;

# It is very unlikely that this test will succeed. It is only meant as a check
# to see if the load is distributed at all.
# On Macos 12.2.1 (ARM64) only one of the workers gets all the requests, while
# on Linux 5.13.0 (x86_64) it gets distributed more evenly.

my $app    = curfile->dirname->child(qw(my-app my-app.pl));
my $port   = Mojo::IOLoop::Server->generate_port;
my $listen = Mojo::URL->new("http://127.0.0.1:$port");
my $ua     = Mojo::UserAgent->new->max_connections(0);

subtest 'run and spawn if reaped' => sub {
  my $dctl = Mojo::Server::DaemonControl->new(listen => [$listen], workers => 4);
  my %pid;

  $dctl->on(
    spawn => sub {
      my ($dctl, $pid) = @_;
      $pid{$pid}++;
      return if keys(%pid) < 4;

      my $url = $listen->clone->path('/pid')->to_string;
      wait_until_ready($url);
      return Mojo::Promise->map({concurrency => 5}, sub { $ua->get_p($url) }, 1 .. 99)->then(sub {
        warn "got /pid response\n" if $ENV{HARNESS_IS_VERBOSE};
        $_->[0]->res->body =~ m!pid=(\d+)! && $pid{$1}++ for @_;
        $dctl->stop;
      })->catch(sub {
        ok 0, $_[0];
        $dctl->stop;
      })->wait;
    }
  );

  $dctl->run($app);

  my $todo = todo 'This test is unlikely to pass';
  is int(keys %pid), 4,                'workers';
  is [values %pid],  [25, 25, 25, 25], 'load';
};

done_testing;

sub wait_until_ready { 1 until $ua->get($_[0])->res->code }
