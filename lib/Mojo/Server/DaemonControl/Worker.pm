package Mojo::Server::DaemonControl::Worker;
use Mojo::Base 'Mojo::Server::Daemon', -signatures;

use Scalar::Util qw(weaken);

sub run ($self, $app, @) {
  weaken $self;
  my $loop = $self->ioloop;
  $loop->on(finish => sub { $self->max_requests(1) });
  local $SIG{QUIT} = sub { $loop->stop_gracefully };
  return $self->tap(load_app => $app)->SUPER::run;
}

1;

=encoding utf8

=head1 NAME

Mojo::Server::DaemonControl::Worker - A Mojolicious daemon that can shutdown gracefully

=head1 SYNOPSIS

  use Mojo::Server::DaemonControl::Worker;
  my $daemon = Mojo::Server::DaemonControl::Worrker->new(listen => ['http://*:8080']);
  $daemon->run;

=head1 DESCRIPTION

L<Mojo::Server::DaemonControl::Worker> is a sub class of
L<Mojo::Server::Daemon>, that is used by L<Mojo::Server::DaemonControl>
to support graceful shutdown and hot deployment.

=head1 SIGNALS

The L<Mojo::Server::DaemonControl::Worker> process can be controlled by the
same signals as L<Mojo::Server::Daemon>, but it also supports the following
signals.

=head2 QUIT

Used to shut down the server gracefully.

=head1 EVENTS

L<Mojo::Server::DaemonControl::Worker> inherits all events from
L<Mojo::Server::Daemon>.

=head1 ATTRIBUTES

L<Mojo::Server::DaemonControl::Worker> inherits all attributes from
L<Mojo::Server::Daemon>.

=head1 METHODS

L<Mojo::Server::DaemonControl::Worker> inherits all methods from
L<Mojo::Server::Daemon> and implements the following ones.

=head2 run

  $daemon->run($app);

Load C<$app> using L<Mojo::Server/load_app> and run server and wait for
L</SIGNALS>.

=head1 SEE ALSO

L<Mojo::Server::DaemonControl>.

=cut
