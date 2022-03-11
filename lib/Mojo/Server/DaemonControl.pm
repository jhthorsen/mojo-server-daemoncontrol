package Mojo::Server::DaemonControl;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use File::Spec::Functions qw(tmpdir);
use Mojo::File qw(path);
use POSIX qw(WNOHANG);
use Scalar::Util qw(weaken);

has graceful_timeout => 120;
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

  $self->{running} = 1;
  $self->emit('start');
  $self->_manage while $self->{running};
}

sub stop ($self, $signal = 'TERM') {
  $self->{running} = 0;
  $self->emit(stop => $signal);
}

sub _inc_workers ($self, $by) {
  $self->workers($self->workers + $by);
  $self->workers(1) if $self->workers < 1;
}

sub _manage ($self) {
}

sub _waitpid ($self) {
  while ((my $pid = waitpid -1, WNOHANG) > 0) {
    $self->emit(reap => $pid);
  }
}

sub DESTROY ($self) {
  my $pid_file = $self->pid_file;
  $pid_file->remove if $pid_file and -e $pid_file;
}

1;
