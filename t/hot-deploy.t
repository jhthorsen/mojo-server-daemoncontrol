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

subtest 'hot deploy workers' => sub {
  my $dctl = Mojo::Server::DaemonControl->new(
    graceful_timeout   => 2,
    heartbeat_interval => 0.5,
    heartbeat_timeout  => 1,
    listen             => [$listen],
    workers            => 2,
  );

  my ($reloaded, %workers) = (0);
  $dctl->on(
    heartbeat => sub {
      my ($dctl, $w) = @_;
      run_slow_request_in_fork() unless $reloaded++;
      $workers{$w->{pid}} = $w;
      $dctl->stop if grep { $_->{KILL} } values %workers;
    }
  );

  $dctl->on(reap => sub { $workers{$_[1]->{pid}}{reaped} = time });

  $dctl->run($app);
  is int(values %workers), 4, 'started';
  my ($forced) = grep { $_->{KILL} } values %workers;
  my ($normal) = grep { $_->{QUIT} and !$_->{KILL} } values %workers;
  is $normal->{graceful},   $forced->{graceful},            'stopped at the same time';
  is $normal->{reaped} + 2, within($forced->{reaped}, 0.2), 'forced after graceful';
  is int(grep { $_->{TERM} } values %workers), 2,           'new workers';
};

done_testing;

sub run_slow_request_in_fork {
  return if fork;
  my $ua = Mojo::UserAgent->new;
  $ua->ioloop->timer(0.1 => sub { kill USR2 => getppid });
  $ua->get($listen->clone->path('/block'));
  exit 0;
}
