package Mojo::Server::DaemonControl;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use File::Spec;
use IO::Select;
use Mojo::File qw(curfile path);
use Mojo::Server::Daemon;
use Mojo::Util qw(steady_time);
use Mojolicious;
use POSIX qw(WNOHANG);

our $VERSION = '0.04';

# This should be considered internal for now
our $MOJODCTL = do {
  my $x = $0 =~ m!\bmojodctl$! && -x $0 ? $0 : $ENV{MOJODCTL_BINARY};
  $x ||= curfile->dirname->dirname->dirname->dirname->child(qw(script mojodctl));
  -x $x ? $x : 'mojodctl';
};

has cleanup            => 0;
has graceful_timeout   => 120;
has heartbeat_interval => 5;
has heartbeat_timeout  => 50;
has listen             => sub ($self) { [split /,/, $ENV{MOJO_LISTEN} || 'http://*:8080'] };
has log                => sub ($self) { $self->_build_log };
has pid_file           => sub ($self) { path(File::Spec->tmpdir, path($0)->basename . '.pid') };
has workers            => 4;

has _listen_handles => sub ($self) {
  my $daemon = Mojo::Server::Daemon->new(listen => $self->listen, silent => 1);
  my $loop   = $daemon->start->ioloop;
  my @fh     = map { $loop->acceptor($_)->handle } @{$daemon->acceptors};
  die "Did you forget to specify listen addresses?" unless @fh;
  return \@fh;
};

sub check_pid ($self) {
  return 0 unless my $pid = -r $self->pid_file && $self->pid_file->slurp;
  chomp $pid;
  return $pid if $pid && kill 0, $pid;
  $self->pid_file->remove;
  return 0;
}

sub ensure_pid_file ($self, $pid) {
  return $self if -s (my $file = $self->pid_file);
  $self->log->info("Writing pid $pid to $file");
  return $file->spurt("$pid\n")->chmod(0644) && $self;
}

sub reload ($self, $app) {
  return _errno(3) unless my $pid = $self->check_pid;
  $self->log->info("Starting hot deployment of $pid");
  return kill(USR2 => $pid) ? _errno(0) : _errno(1);
}

sub run ($self, $app) {

  # Cannot run two daemons at the same time
  if (my $pid = $self->check_pid) {
    $self->log->info("Manager for $app is already running ($pid)");
    return _errno(16);
  }

  # Listen for signals and start the daemon
  local $SIG{CHLD} = sub { $self->_waitpid };
  local $SIG{INT}  = sub { $self->stop('INT') };
  local $SIG{QUIT} = sub { $self->stop('QUIT') };
  local $SIG{TERM} = sub { $self->stop('TERM') };
  local $SIG{TTIN} = sub { $self->workers($self->workers + 1) };
  local $SIG{TTOU} = sub { $self->workers($self->workers - 1) if $self->workers > 0 };
  local $SIG{USR2} = sub { $self->_start_hot_deployment };

  $self->cleanup(1)->ensure_pid_file($self->{pid} = $$);
  $self->_create_worker_read_write_pipe;
  $self->_listen_handles;

  @$self{qw(pid pool running)} = ($$, {}, 1);
  $self->emit('start');
  $self->log->info("Manager for $app started");
  $self->_manage($app) while $self->{running};
  $self->log->info("Manager for $app stopped");
  $self->cleanup(0)->pid_file->remove;
  return _errno(0);
}

sub stop ($self, $signal = 'TERM') {
  $self->{stop_signal} = $signal;
  $self->log->info("Manager will stop workers with signal $signal");
  return $self->emit(stop => $signal);
}

sub _build_log ($self) {
  my $level = $ENV{MOJO_LOG_LEVEL}
    || ($ENV{HARNESS_IS_VERBOSE} ? 'debug' : $ENV{HARNESS_ACTIVE} ? 'error' : 'info');
  return Mojo::Log->new(level => $level);
}

sub _create_worker_read_write_pipe ($self) {
  return if $self->{worker_read};
  pipe $self->{worker_read}, $self->{worker_write} or die "pipe: $!";
}

sub _errno ($n) { $! = $n }

sub _kill ($self, $signal, $w, $level, $reason) {
  return if $w->{$signal};
  $w->{$signal} = kill($signal, $w->{pid}) || 0;
  $self->log->$level("$reason (signalled=$w->{$signal})");
}

sub _manage ($self, $app) {

  # Make sure we have a PID file and get status from workers
  $self->ensure_pid_file($self->{pid});
  $self->_read_heartbeat;

  # Stop workers and eventually manager
  my $pool = $self->{pool};
  if (my $signal = $self->{stop_signal}) {
    return delete @$self{qw(running stop_signal)} unless keys %$pool;    # Fully stopped
    return map { $_->{$signal} ||= kill $signal, $_->{pid} } values %$pool;
  }

  # Decrease workers on SIGTTOU
  my $time       = steady_time;
  my @maybe_stop = grep { !$_->{graceful} } values %$pool;
  $_->{graceful} = $time for splice @maybe_stop, $self->workers;

  # Figure out worker health
  my $ht = $self->heartbeat_timeout;
  my (@graceful, @healthy, @starting);
  for my $pid (sort keys %$pool) {
    my $w = $pool->{$pid} or next;
    if    ($w->{graceful})            { push @graceful, $pid }
    elsif (!$w->{time})               { push @starting, $pid }
    elsif ($w->{time} + $ht <= $time) { $w->{graceful} //= $time; push @graceful, $pid }
    else                              { push @healthy, $pid }
  }

  # Start or stop workers based on worker health
  my $n_missing = $self->workers - (@healthy + @starting);
  if ($n_missing > 0) {
    $self->log->info("Manager starting $n_missing workers");
    $self->_spawn($app) while !$self->{stop_signal} && $n_missing-- > 0;
  }
  elsif (!@starting) {
    my $gt = $self->graceful_timeout;
    for my $pid (@graceful) {
      next unless my $w = $pool->{$pid};
      if ($gt && $w->{graceful} + $gt < $time) {
        $self->_kill(KILL => $w, warn => "Stopping worker $pid immediately");
      }
      else {
        $self->_kill(QUIT => $w, info => "Stopping worker $pid gracefully ($gt seconds)");
      }
    }
  }
}

sub _read_heartbeat ($self) {
  my $select = $self->{select} ||= IO::Select->new($self->{worker_read});
  return unless $select->can_read(0.1);
  return unless $self->{worker_read}->sysread(my $chunk, 4194304);

  my $time = steady_time;
  while ($chunk =~ s/mojodctl:\d+:(\d+):(\w)\n//mg) {
    next unless my $w = $self->{pool}{$1};
    ($w->{killed} = $time), $self->log->fatal("Worker $w->{pid} force killed") if $2 eq 'k';
    $w->{graceful} ||= $time if $2 eq 'g';
    $w->{time} = $time;
    $self->emit(heartbeat => $w);
  }
}

sub _spawn ($self, $app) {

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  if ($pid) {
    my $w = $self->{pool}{$pid} = {pid => $pid, time => steady_time};
    $self->log->info("Worker $pid started");
    return $self->emit(spawn => $w);
  }

  # Child
  $ENV{MOJO_LOG_LEVEL} ||= $self->log->level;
  $ENV{MOJODCTL_CONTROL_CLASS}      = 'Mojo::Server::DaemonControl::Worker';
  $ENV{MOJODCTL_HEARTBEAT_FD}       = fileno $self->{worker_write};
  $ENV{MOJODCTL_HEARTBEAT_INTERVAL} = $self->heartbeat_interval;

  my @args;
  for my $fh ($self->{worker_write}, @{$self->_listen_handles}) {

    # Remove close-on-exec flag
    # https://stackoverflow.com/questions/14351147/perl-passing-an-open-socket-across-fork-exec
    my $flags = fcntl $fh, F_GETFD, 0 or die "fcntl F_GETFD: $!";
    fcntl $fh, F_SETFD, $flags & ~FD_CLOEXEC or die "fcntl F_SETFD: $!";

    next if $fh eq $self->{worker_write};
    my $url = Mojo::URL->new('http://127.0.0.1');
    $url->query->param(fd => fileno $fh);
    push @args, -l => $url->to_string;
  }

  $self->log->debug("Starting $^X $MOJODCTL $app daemon @args");
  exec $^X, $MOJODCTL => $app => daemon => @args;
  die "Could not exec $app: $!";
}

sub _start_hot_deployment ($self) {
  $self->log->info('Starting hot deployment.');
  my $time = steady_time;
  $_->{graceful} = $time for values %{$self->{pool}};
}

sub _waitpid ($self) {
  while ((my $pid = waitpid -1, WNOHANG) > 0) {
    next unless my $w = delete $self->{pool}{$pid};
    $self->log->info("Worker $pid stopped");
    $self->emit(reap => $w);
  }
}

sub DESTROY ($self) {
  my $path = $self->cleanup && $self->pid_file;
  $path->remove if $path and -e $path;
}

1;

=encoding utf8

=head1 NAME

Mojo::Server::DaemonControl - A Mojolicious daemon manager

=head1 SYNOPSIS

=head2 Commmand line

  # Start the manager
  $ mojodctl -l 'http://*:8080' -P /tmp/myapp.pid -w 4 /path/to/myapp.pl;

  # Reload the manager
  $ mojodctl -R -P /tmp/myapp.pid /path/to/myapp.pl;

  # For more options
  $ mojodctl --help

=head2 Perl API

  use Mojo::Server::DaemonControl;
  my $dctl = Mojo::Server::DaemonControl->new(listen => ['http://*:8080'], workers => 4);
  $dctl->run('/path/to/my-mojo-app.pl');

=head2 Mojolicious application

It is possible to use the L<Mojolicious/before_server_start> hook to change
server settings. The C<$app> is also available, meaning the values can be read
from a config file. See L<Mojo::Server::DaemonControl::Worker> and
L<Mojo::Server::Daemon> for more information about what to tweak.

  use Mojolicious::Lite -signatures;

  app->hook(before_server_start => sub ($server, $app) {
    if ($sever->isa('Mojo::Server::DaemonControl::Worker')) {
      $server->inactivity_timeout(60);
      $server->max_clients(100);
      $server->max_requests(10);
    }
  });

=head1 DESCRIPTION

L<Mojo::Server::DaemonControl> is not a web server. Instead it manages one or
more L<Mojo::Server::Daemon> processes that can handle web requests.

This server is an alternative to L<Mojo::Server::Hypnotoad> where each of the
workers handle long running (WebSocket) requests. The main difference is that a
hot deploy will simply start new workers, instead of restarting the manager.
This is useful if you need/want to deploy a new version of your server during
the L</graceful_timeout>. Normally this is not something you would need, but in
some cases where the graceful timeout and long running requests last for
several hours or even days, then it might come in handy to let the old
code run, while new processes are deployed.

Note that L<Mojo::Server::DaemonControl> is currently EXPERIMENTAL and it has
not been tested in production yet. Feedback is more than welcome.

=head1 SIGNALS

=head2 INT, TERM

Shut down server immediately.

=head2 QUIT

Shut down server gracefully.

=head2 TTIN

Increase worker pool by one.

=head2 TTOU

Decrease worker pool by one.

=head2 USR2

Will prevent existing workers from accepting new connections and eventually
stop them, and start new workers in a fresh environment that handles the new
connections. The manager process will remain the same.

  $ mojodctl
    |- myapp.pl-1647405707
    |- myapp.pl-1647405707
    |- myapp.pl-1647405707
    |- myapp.pl
    |- myapp.pl
    '- myapp.pl

EXPERIMENTAL: The workers that waits to be stopped will have a timestamp
appended to C<$0> to illustrate which is new and which is old.

=head1 ATTRIBUTES

L<Mojo::Server::DaemonControl> inherits all attributes from
L<Mojo::EventEmitter> and implements the following ones.

=head2 cleanup

  $bool = $dctl->cleanup;
  $dctl = $dctl->cleanup(1);

Set this to true and L<Mojo::Server::DaemonControl> will remove L</pid_file>
when this object goes out of scope.

=head2 graceful_timeout

  $timeout = $dctl->graceful_timeout;
  $dctl    = $dctl->graceful_timeout(120);

A worker will be forced stopped if it could not be gracefully stopped after
this amount of time.

=head2 heartbeat_interval

  $num  = $dctl->heartbeat_interval;
  $dctl = $dctl->heartbeat_interval(5);

Heartbeat interval in seconds. This value is passed on to
L<Mojo::Server::DaemonControl::Worker/heartbeat_interval>.

=head2 heartbeat_timeout

  $num  = $dctl->heartbeat_timeout;
  $dctl = $dctl->heartbeat_timeout(120);

A worker will be stopped gracefully if a heartbeat has not been seen within
this amount of time.

=head2 listen

  $array_ref = $dctl->listen;
  $dctl      = $dctl->listen(['http://127.0.0.1:3000']);

Array reference with one or more locations to listen on.
See L<Mojo::Server::Daemon/listen> for more details.

=head2 log

  $log  = $dctl->log;
  $dctl = $dctl->log(Mojo::Log->new);

A L<Mojo::Log> object used for logging.

=head2 pid_file

  $file = $dctl->pid_file;
  $dctl = $dctl->pid_file(Mojo::File->new);

A L<Mojo::File> object with the path to the pid file.

Note that the PID file must end with ".pid"! Default path is "mojodctl.pid" in
L<File::Spec/tmpdir>.

=head2 workers

  $int  = $dctl->workers;
  $dctl = $dctl->workers(4);

Number of worker processes, defaults to 4. See L<Mojo::Server::Prefork/workers>
for more details.

=head1 METHODS

L<Mojo::Server::DaemonControl> inherits all methods from
L<Mojo::EventEmitter> and implements the following ones.

=head2 check_pid

  $int = $dctl->check_pid;

Returns the PID of the running process documented in L</pid_file> or zero (0)
if it is not running.

=head2 ensure_pid_file

  $dctl->ensure_pid_file($pid);

Makes sure L</pid_file> exists and contains the current PID.

=head2 reload

  $int = $dctl->reload($app);

Tries to reload a running instance by sending L</USR2> to L</pid_file>.

=head2 run

  $int = $dctl->run($app);

Run the menager and wait for L</SIGNALS>. Note that C<$app> is not loaded in
the manager process, which means that each worker does not share any code or
memory.

=head2 stop

  $dctl->stop($signal);

Used to stop the running manager and any L</workers> with the C<$signal> INT,
QUIT or TERM (default).

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

Copyright (C) Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojo::Server::Daemon>, L<Mojo::Server::Hypnotoad>,
L<Mojo::Server::DaemonControl::Worker>.

=cut
