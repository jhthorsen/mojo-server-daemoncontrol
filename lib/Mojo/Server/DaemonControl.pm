package Mojo::Server::DaemonControl;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use File::Spec::Functions qw(tmpdir);
use Mojo::File qw(curfile path);
use Mojo::Log;
use Mojo::URL;
use Mojo::Util qw(steady_time);
use POSIX qw(WNOHANG);
use Scalar::Util qw(weaken);
use Time::HiRes qw(sleep);

# This should be considered internal for now
our $MOJODCTL = do {
  my $x = $0 =~ m!\bmojodctl$! && -x $0 ? $0 : $ENV{MOJODCTL_BINARY};
  $x ||= curfile->dirname->dirname->dirname->dirname->child(qw(script mojodctl));
  -x $x ? $x : 'mojodctl';
};

has graceful_timeout => 120;
has listen           => sub ($self) { [Mojo::URL->new('http://*:8080')] };
has log              => sub ($self) { $self->_build_log };
has pid_file         => sub { path(tmpdir, sprintf '%s-mojo-daemon-control.pid', $<) };
has workers          => 4;

sub check_pid ($self) {
  return 0 unless my $pid = -r $self->pid_file && $self->pid_file->slurp;
  chomp $pid;
  return $pid if $pid && kill 0, $pid;
  $self->pid_file->remove;
  return 0;
}

sub ensure_pid_file ($self, $pid) {
  return 1 if -s (my $file = $self->pid_file);
  $self->log->info("Writing pid $pid to @{[$self->pid_file]}");
  return $file->spurt("$pid\n")->chmod(0644) && 1;
}

sub run ($self, $app) {
  weaken $self;
  local $SIG{CHLD} = sub { $self->_waitpid };
  local $SIG{INT}  = sub { $self->stop('INT') };
  local $SIG{QUIT} = sub { $self->stop('QUIT') };
  local $SIG{TERM} = sub { $self->stop('TERM') };
  local $SIG{TTIN} = sub { $self->_inc_workers(1) };
  local $SIG{TTOU} = sub { $self->_inc_workers(-1) };

  @$self{qw(pool running)} = ({}, 1);
  $self->emit('start');
  $self->log->info("Manager for $app started");
  $self->_manage($app) while $self->{running};
  $self->log->info("Manager for $app stopped");
}

sub stop ($self, $signal = 'TERM') {
  $self->{stop_signal} = $signal;
  $self->log->info("Manager will stop workers with signal $signal");
  return $self->emit(stop => $signal);
}

sub _build_log ($self) {
  $ENV{MOJO_LOG_LEVEL} ||= $ENV{HARNESS_IS_VERBOSE} ? 'debug' : 'error' if $ENV{HARNESS_ACTIVE};
  return Mojo::Log->new(level => $ENV{MOJO_LOG_LEVEL});
}

sub _inc_workers ($self, $by) {
  $self->workers($self->workers + $by);
  $self->workers(1) if $self->workers < 1;
}

sub _manage ($self, $app) {
  my $pool = $self->{pool};

  # Should not call _manage() too often. Also, sleep() will be interrupted
  # when a signal (Ex SIGCHLD) occurs.
  my ($l, $t) = ($self->{managed_at}, steady_time);
  return sleep 0.2 if $l and $t - $l < 0.2;
  $self->{managed_at} = $t;

  if (my $signal = $self->{stop_signal}) {

    # Fully stopped
    return delete @$self{qw(running stop_signal)} unless keys %$pool;

    # Stop running workers
    $self->log->debug(sprintf 'kill %s %s == %s', $signal, $_, kill $signal => $_)
      for keys %{$self->{pool}};
    sleep 1;
  }
  else {
    # Make sure we have enough workers and a pid file
    my $need = $self->workers - int grep { !$_->{graceful} } values %$pool;
    $self->log->debug("Manager starting $need workers") if $need > 0;
    $self->_spawn($app) while !$self->{stop_signal} && $need-- > 0;
    $self->ensure_pid_file($$) unless $self->{stop_signal};
  }
}

sub _spawn ($self, $app) {
  my @args;
  push @args, map {
    my $url = $_->clone;
    $url->query->param(reuse => 1);
    (-l => $url->to_string);
  } @{$self->listen};

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $self->emit(spawn => $pid)->{pool}{$pid} = {time => steady_time} if $pid;

  # Child
  $ENV{MOJO_SERVER_DAEMON_MANAGER_CLASS} = 'Mojo::Server::DaemonControl::Worker';
  $self->log->debug("Exec $^X $MOJODCTL $app daemon @args");
  exec $^X, $MOJODCTL => $app => daemon => @args;
  die "Could not exec $app: $!";
}

sub _waitpid ($self) {
  while ((my $pid = waitpid -1, WNOHANG) > 0) {
    next unless delete $self->{pool}{$pid};
    $self->log->debug("Worker $pid stopped");
    $self->emit(reap => $pid);
  }
}

sub DESTROY ($self) {
  my $pid_file = $self->pid_file;
  $pid_file->remove if $pid_file and -e $pid_file;
}

1;
