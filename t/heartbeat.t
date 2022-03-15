use Mojo::Base -strict;
use Test2::V0;
use Mojo::File qw(curfile);
use Mojo::IOLoop::Server;
use Mojo::Promise;
use Mojo::Server::DaemonControl;
use Mojo::UserAgent;
use Time::HiRes qw(time);

plan skip_all => 'TEST_LIVE=1' unless $ENV{TEST_LIVE};

my $app    = curfile->dirname->child(qw(my-app my-app.pl));
my $listen = Mojo::URL->new(sprintf 'http://127.0.0.1:%s', Mojo::IOLoop::Server->generate_port);
my $t0;

subtest 'force stop blocked workers' => sub {
  my $dctl = Mojo::Server::DaemonControl->new(
    graceful_timeout   => 0.5,
    heartbeat_interval => 0.5,
    heartbeat_timeout  => 1,
    listen             => [$listen],
    workers            => 2,
  );
  my %workers;

  $dctl->on(heartbeat => sub { run_slow_request_in_fork() unless $ENV{REQUEST}++; });
  $dctl->on(
    heartbeat => sub {
      my ($dctl, $w) = @_;
      $workers{$w->{pid}} = $w;
      $dctl->stop if grep { $_->{KILL} } values %workers;
    }
  );

  $dctl->run($app);

  for my $w (values %workers) {
    $w->{graceful} = 2  if $w->{graceful};
    $w->{time}     = 1  if $w->{time};
    $w->{pid}      = 42 if $w->{pid};
    $w->{pid}++ if $w->{QUIT};
    $w->{pid}++ if $w->{KILL};
  }

  is(
    [sort { $a->{pid} <=> $b->{pid} } values %workers],
    [
      {pid      => 42, time => 1,  TERM => 1},
      {pid      => 42, time => 1,  TERM => 1},
      {graceful => 2,  pid  => 44, time => 1, KILL => 1, QUIT => 1},
    ],
    'workers killed'
  );
};

done_testing;

sub run_slow_request_in_fork {
  $t0 = time;
  return if fork;
  Mojo::UserAgent->new->get($listen->clone->path('/block'));
  exit 0;
}
