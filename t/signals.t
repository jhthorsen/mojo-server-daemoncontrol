use Mojo::Base -strict;
use Test2::V0;
use Mojo::Server::DaemonControl;

my $app = 'signal-app.pl';

subtest 'signals - stop' => sub {
  my $dctl = Mojo::Server::DaemonControl->new;
  my @stop;
  for my $sig (qw(INT QUIT TERM)) {
    $dctl->once(stop  => sub { push @stop, $_[1] });
    $dctl->once(start => sub { kill $sig => $$ });
    $dctl->run($app);
  }

  is \@stop, [qw(INT QUIT TERM)], 'INT QUIT TERM';
};

subtest 'signals - workers' => sub {
  my $dctl = Mojo::Server::DaemonControl->new;
  $dctl->once(
    start => sub {
      my $dctl = shift;
      kill TTIN => $$ for 1 .. 2;
      kill TERM => $$;
    }
  );

  $dctl->run($app);
  is $dctl->workers, 6, 'inc workers';

  $dctl->once(
    start => sub {
      my $dctl = shift;
      kill TTOU => $$ for 1 .. 10;
      kill TERM => $$;
    }
  );

  $dctl->run($app);
  is $dctl->workers, 1, 'min workers';
};

subtest 'signals - reap' => sub {
  my $dctl = Mojo::Server::DaemonControl->new;
  my @reap;
  $dctl->once(reap => sub { push @reap, $_[1]; shift->stop });
  $dctl->once(start => sub { my $pid = fork; die $! unless defined $pid; exit unless $pid; });
  $dctl->run($app);
  is int @reap, 1, 'reaped';
};

done_testing;
