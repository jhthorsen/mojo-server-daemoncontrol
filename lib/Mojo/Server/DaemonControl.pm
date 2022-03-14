package Mojo::Server::DaemonControl;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use File::Spec::Functions qw(tmpdir);
use IO::Select;
use IO::Socket::UNIX;
use Mojo::File qw(curfile path);
use Mojo::Log;
use Mojo::URL;
use Mojo::Util qw(steady_time);
use POSIX qw(WNOHANG);
use Scalar::Util qw(weaken);

# This should be considered internal for now
our $MOJODCTL = do {
  my $x = $0 =~ m!\bmojodctl$! && -x $0 ? $0 : $ENV{MOJODCTL_BINARY};
  $x ||= curfile->dirname->dirname->dirname->dirname->child(qw(script mojodctl));
  -x $x ? $x : 'mojodctl';
};

has graceful_timeout  => 120;
has heartbeat_timeout => 30;
has listen            => sub ($self) { [Mojo::URL->new('http://*:8080')] };
has log               => sub ($self) { $self->_build_log };
has pid_file          => sub ($self) { $self->_build_pid_file };
has workers           => 4;
has worker_pipe       => sub ($self) { $self->_build_worker_pipe };

sub check_pid ($self) {
  return 0 unless my $pid = -r $self->pid_file && $self->pid_file->slurp;
  chomp $pid;
  return $pid if $pid && kill 0, $pid;
  $self->pid_file->remove;
  return 0;
}

sub ensure_pid_file ($self, $pid) {
  return $self if -s (my $file = $self->pid_file);
  $self->log->info("Writing pid $pid to @{[$self->pid_file]}");
  return $file->spurt("$pid\n")->chmod(0644) && $self;
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
  $self->worker_pipe;    # Make sure we have a working pipe
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

sub _build_pid_file ($self) {
  my $basename = sprintf '%s-mojo-daemon-control.pid', $ENV{HARNESS_ACTIVE} ? $$ : $>;
  return path(tmpdir, $basename);
}

sub _build_worker_pipe ($self) {
  my $path = $self->pid_file->to_string =~ s!\.pid$!.sock!r;
  die qq(PID file "@{[$self->pid_file]}" must end with ".pid") unless $path =~ m!\.sock$!;
  path($path)->remove if -S $path;
  return IO::Socket::UNIX->new(Listen => 1, Local => $path, Type => SOCK_DGRAM)
    || die "Can't create a worker pipe: $@";
}

sub _inc_workers ($self, $by) {
  $self->workers($self->workers + $by);
  $self->workers(1) if $self->workers < 1;
}

sub _kill ($self, $signal, $w, $reason = "with $signal") {
  $w->{$signal} = kill($signal => $w->{pid}) // 0;
  $self->log->info("Stopping worker $w->{pid} $reason == $w->{$signal}");
}

sub _manage ($self, $app) {
  $self->_read_heartbeat;

  # Stop workers and eventually manager
  my $pool = $self->{pool};
  if (my $signal = $self->{stop_signal}) {
    return delete @$self{qw(running stop_signal)} unless keys %$pool;    # Fully stopped
    return map { $_->{$signal} || $self->_kill($signal => $_) } values %{$self->{pool}};
  }

  # Make sure we have enough workers and a pid file
  my $need = $self->workers - int grep { !$_->{graceful} } values %$pool;
  $self->log->debug("Manager starting $need workers") if $need > 0;
  $self->_spawn($app) while !$self->{stop_signal} && $need-- > 0;
  $self->ensure_pid_file($$) unless $self->{stop_signal};
}

sub _read_heartbeat ($self) {
  my $select = $self->{select} ||= IO::Select->new($self->worker_pipe);
  return unless $select->can_read(0.1);
  return unless $self->worker_pipe->sysread(my $chunk, 4194304);

  my $time = steady_time;
  while ($chunk =~ /(\d+):(\w)\n/g) {
    next unless my $w = $self->{pool}{$1};
    $w->{graceful} ||= $time if $2 eq 'g';
    $w->{time} = $time;
    $self->emit(heartbeat => $w);
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
  return $self->emit(spawn => $self->{pool}{$pid} = {pid => $pid, time => steady_time}) if $pid;

  # Child
  my $ht = $self->heartbeat_timeout;
  $ENV{MOJO_SERVER_DAEMON_HEARTBEAT_INTERVAL} ||= $ht >= 20 ? 5 : 1;    # TODO
  $ENV{MOJO_SERVER_DAEMON_MANAGER_CLASS} = 'Mojo::Server::DaemonControl::Worker';
  $ENV{MOJO_SERVER_DAEMON_MANAGER_PIPE}  = $self->worker_pipe->hostpath;
  $self->log->debug("Exec $^X $MOJODCTL $app daemon @args");
  exec $^X, $MOJODCTL => $app => daemon => @args;
  die "Could not exec $app: $!";
}

sub _waitpid ($self) {
  while ((my $pid = waitpid -1, WNOHANG) > 0) {
    next unless my $w = delete $self->{pool}{$pid};
    $self->log->debug("Worker $pid stopped");
    $self->emit(reap => $w);
  }
}

sub DESTROY ($self) {
  my $path = $self->pid_file;
  $path->remove if $path and -e $path;

  my $worker_pipe = $self->{worker_pipe};
  path($worker_pipe->hostpath)->remove if $worker_pipe and -S $worker_pipe->hostpath;
}

1;

=encoding utf8

=head1 NAME

Mojo::Server::DaemonControl - A Mojolicious daemon manager

=head1 SYNOPSIS

=head2 Commmand line

  $ mojodctl --workers 4 --listen 'http://*:8080' /path/to/my-mojo-app.pl;

=head2 Perl API

  use Mojo::Server::DaemonControl;
  my $listen = Mojo::URL->new('http://*:8080');
  my $dctl   = Mojo::Server::DaemonControl->new(listen => [$listen], workers => 4);

  $dctl->run('/path/to/my-mojo-app.pl');

=head1 DESCRIPTION

L<Mojo::Server::DaemonControl> is not a web server. Instead it manages one or
more L<Mojo::Server::Daemon> processes that can handle web requests. Each of
these servers are started with L<SO_REUSEPORT|Mojo::Server::Daemon/reuse>
enabled.

This means it is only supported on systems that support
L<SO_REUSEPORT|https://lwn.net/Articles/542629/>. It also does not support fork
emulation. It should work on most modern Linux based systems though.

This server is an alternative to L<Mojo::Server::Hypnotoad> where each of the
workers handle long running (WebSocket) requests. The main difference is that a
hot reload will simply start new workers, instead of restarting the manager.
This is useful if you need/want to deploy a new version of your server during
the L</graceful_timeout>. Normally this is not something you would need, but in
some cases where the graceful timeout and long running requests last for
several hours or even days, then it might come in handy to let the old
code run, while new processes are deployed.

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

TODO: Zero downtime software upgrade.

=head1 ATTRIBUTES

L<Mojo::Server::DaemonControl> inherits all attributes from
L<Mojo::EventEmitter> and implements the following ones.

=head2 graceful_timeout

  $timeout = $dctl->graceful_timeout;
  $dctl    = $dctl->graceful_timeout(120);

TODO

=head2 listen

  $array_ref = $dctl->listen;
  $dctl      = $dctl->listen([Mojo::URL->new]);

An array-ref of L<Mojo::URL> objects for what to listen to. See
L<Mojo::Server::Daemon/listen> for supported values.

The C<reuse=1> query parameter will be added automatically before starting the
L<Mojo::Server::Daemon> sub process.

=head2 log

  $log  = $dctl->log;
  $dctl = $dctl->log(Mojo::Log->new);

A L<Mojo::Log> object used for logging.

=head2 pid_file

  $file = $dctl->pid_file;
  $dctl = $dctl->pid_file(Mojo::File->new);

A L<Mojo::File> object with the path to the pid file.

Note that the PID file must end with ".pid"! Default path is
"$EUID-mojo-daemon-control.pid" in L<File::Spec/tmpdir>.

=head2 workers

  $int  = $dctl->workers;
  $dctl = $dctl->workers(4);

Number of worker processes, defaults to 4. See L<Mojo::Server::Prefork/workers>
for more details.

=head2 worker_pipe

  $socket = $dctl->worker_pipe;

Holds a L<IO::Socket::UNIX> object used to communicate with workers.

=head1 METHODS

L<Mojo::Server::DaemonControl> inherits all methods from
L<Mojo::EventEmitter> and implements the following ones.

=head2 check_pid

  $int = $dctl->check_pid;

Returns the PID of the running process documented in L</pid_file> or zero (0)
if is is not running.

=head2 ensure_pid_file

  $dctl->ensure_pid_file;

Makes sure L</pid_file> exists and contains the current PID.

=head2 run

  $dctl->run($app);

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
