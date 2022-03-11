package Mojo::Server::DaemonControl;
use Mojo::Base -base, -signatures;

use File::Spec::Functions qw(tmpdir);
use Mojo::File qw(path);

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

sub DESTROY ($self) {
  my $pid_file = $self->pid_file;
  $pid_file->remove if $pid_file and -e $pid_file;
}

1;
