package Mojo::Server::DaemonControl::Worker;
use Mojo::Base 'Mojo::Server::Daemon', -signatures;

use Scalar::Util qw(weaken);

sub run ($self, $app, @args) {
  weaken $self;
  my $loop = $self->ioloop;
  $loop->on(finish => sub { $self->max_requests(1) });
  local $SIG{QUIT} = sub { $loop->stop_gracefully };

  $self->load_app($app);
  return $self->SUPER::run(@args);
}

1;
