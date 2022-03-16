#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

get '/block' => sub ($c) { $c->render_later; sleep 5 };
get '/pid'   => {text => "pid=$$"};

get '/slow' => sub ($c) {
  my $t = $c->param('t') || 2;
  $c->inactivity_timeout($t + 1);
  $c->render_later;
  Mojo::Promise->timer($t)->then(sub { $c->render(text => 'slow') });
};

app->log->level($ENV{MOJO_LOG_LEVEL} || 'error');
app->start;
