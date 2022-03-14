#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

get '/pid' => {text => "pid=$$"};

websocket '/ws' => sub ($c) {
  $c->inactivity_timeout($c->param('t') || 2);
  $c->send({json => {pid => $$}});
};

app->log->level($ENV{MOJO_LOG_LEVEL} || 'error');
app->start;
