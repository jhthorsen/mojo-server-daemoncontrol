# NAME

Mojo::Server::DaemonControl - A Mojolicious daemon manager

# SYNOPSIS

## Commmand line

    $ mojodctl --workers 4 --listen 'http://*:8080' /path/to/my-mojo-app.pl;

## Perl API

    use Mojo::Server::DaemonControl;
    my $listen = Mojo::URL->new('http://*:8080');
    my $dctl   = Mojo::Server::DaemonControl->new(listen => [$listen], workers => 4);

    $dctl->run('/path/to/my-mojo-app.pl');

## Mojolicious application

It is possible to use the ["before\_server\_start" in Mojolicious](https://metacpan.org/pod/Mojolicious#before_server_start) hook to change
server settings. The `$app` is also available, meaning the values can be read
from a config file. See [Mojo::Server::DaemonControl::Worker](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl%3A%3AWorker) and
[Mojo::Server::Daemon](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon) for more information about what to tweak.

    use Mojolicious::Lite -signatures;

    app->hook(before_server_start => sub ($server, $app) {
      if ($sever->isa('Mojo::Server::DaemonControl::Worker')) {
        $server->inactivity_timeout(60);
        $server->max_clients(100);
        $server->max_requests(10);
      }
    });

# DESCRIPTION

[Mojo::Server::DaemonControl](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl) is not a web server. Instead it manages one or
more [Mojo::Server::Daemon](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon) processes that can handle web requests. Each of
these servers are started with [SO\_REUSEPORT](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon#reuse)
enabled.

This means it is only supported on systems that support
[SO\_REUSEPORT](https://lwn.net/Articles/542629/). It also does not support fork
emulation. It should work on most modern Linux based systems though.

This server is an alternative to [Mojo::Server::Hypnotoad](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3AHypnotoad) where each of the
workers handle long running (WebSocket) requests. The main difference is that a
hot deploy will simply start new workers, instead of restarting the manager.
This is useful if you need/want to deploy a new version of your server during
the ["graceful\_timeout"](#graceful_timeout). Normally this is not something you would need, but in
some cases where the graceful timeout and long running requests last for
several hours or even days, then it might come in handy to let the old
code run, while new processes are deployed.

# SIGNALS

## INT, TERM

Shut down server immediately.

## QUIT

Shut down server gracefully.

## TTIN

Increase worker pool by one.

## TTOU

Decrease worker pool by one.

## USR2

Will prevent existing workers from accepting new connections and eventually
stop them, and start new workers in a fresh environment that handles the new
connections. The manager process will remain the same.

# ATTRIBUTES

[Mojo::Server::DaemonControl](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl) inherits all attributes from
[Mojo::EventEmitter](https://metacpan.org/pod/Mojo%3A%3AEventEmitter) and implements the following ones.

## graceful\_timeout

    $timeout = $dctl->graceful_timeout;
    $dctl    = $dctl->graceful_timeout(120);

A worker will be forced stopped if it could not be gracefully stopped after
this amount of time.

## heartbeat\_interval

    $num  = $dctl->heartbeat_interval;
    $dctl = $dctl->heartbeat_interval(5);

Heartbeat interval in seconds. This value is passed on to
["heartbeat\_interval" in Mojo::Server::DaemonControl::Worker](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl%3A%3AWorker#heartbeat_interval).

## heartbeat\_timeout

    $num  = $dctl->heartbeat_timeout;
    $dctl = $dctl->heartbeat_timeout(120);

A worker will be stopped gracefully if a heartbeat has not been seen within
this amount of time.

## listen

    $array_ref = $dctl->listen;
    $dctl      = $dctl->listen([Mojo::URL->new]);

An array-ref of [Mojo::URL](https://metacpan.org/pod/Mojo%3A%3AURL) objects for what to listen to. See
["listen" in Mojo::Server::Daemon](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon#listen) for supported values.

The `reuse=1` query parameter will be added automatically before starting the
[Mojo::Server::Daemon](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon) sub process.

## log

    $log  = $dctl->log;
    $dctl = $dctl->log(Mojo::Log->new);

A [Mojo::Log](https://metacpan.org/pod/Mojo%3A%3ALog) object used for logging.

## pid\_file

    $file = $dctl->pid_file;
    $dctl = $dctl->pid_file(Mojo::File->new);

A [Mojo::File](https://metacpan.org/pod/Mojo%3A%3AFile) object with the path to the pid file.

Note that the PID file must end with ".pid"! Default path is
"$EUID-mojodctl.pid" in ["tmpdir" in File::Spec](https://metacpan.org/pod/File%3A%3ASpec#tmpdir).

## workers

    $int  = $dctl->workers;
    $dctl = $dctl->workers(4);

Number of worker processes, defaults to 4. See ["workers" in Mojo::Server::Prefork](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3APrefork#workers)
for more details.

## worker\_pipe

    $socket = $dctl->worker_pipe;

Holds a [IO::Socket::UNIX](https://metacpan.org/pod/IO%3A%3ASocket%3A%3AUNIX) object used to communicate with workers.

# METHODS

[Mojo::Server::DaemonControl](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl) inherits all methods from
[Mojo::EventEmitter](https://metacpan.org/pod/Mojo%3A%3AEventEmitter) and implements the following ones.

## check\_pid

    $int = $dctl->check_pid;

Returns the PID of the running process documented in ["pid\_file"](#pid_file) or zero (0)
if is is not running.

## ensure\_pid\_file

    $dctl->ensure_pid_file;

Makes sure ["pid\_file"](#pid_file) exists and contains the current PID.

## run

    $dctl->run($app);

Run the menager and wait for ["SIGNALS"](#signals). Note that `$app` is not loaded in
the manager process, which means that each worker does not share any code or
memory.

## stop

    $dctl->stop($signal);

Used to stop the running manager and any ["workers"](#workers) with the `$signal` INT,
QUIT or TERM (default).

# AUTHOR

Jan Henning Thorsen

# COPYRIGHT AND LICENSE

Copyright (C) Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

# SEE ALSO

[Mojo::Server::Daemon](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemon), [Mojo::Server::Hypnotoad](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3AHypnotoad),
[Mojo::Server::DaemonControl::Worker](https://metacpan.org/pod/Mojo%3A%3AServer%3A%3ADaemonControl%3A%3AWorker).
