#!/usr/bin/env perl
use Mojolicious::Lite;
get '/pid' => {text => "pid=$$"};
app->log->level($ENV{MOJO_LOG_LEVEL} || 'error');
app->start;
