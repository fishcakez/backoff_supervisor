backoff_supervisor
==================

`backoff_supervisor` is a `simple_one_for_one` supervisor with the
following differences:

* Maximum of 1 child. `start_child/2` returns
  `{error, {already_started, Pid}}` when attempting to start a second
  child.

* Maximum restarts of `0`. If a permanent child exits the supervisor
  will shutdown. If a transient child exits abnormally the supervisor
  will shutdown.

* Automatically attempts to start a child after an initial delay, if no
  child is present.

* If an automatic attempt to start a child returns `ignore`, will try
  again after a longer delay (up to a maximum), if no child present.

* If an automatic attempt to start a child returns `{error, _}` the
  supervisor will shutdown.

`backoff_supervisor` exports the same functions as `supervisor` and
requires a single callback `init/1`:
```erlang
-callback init(Args :: any()) ->
    {ok, {{BackoffType :: normal | jitter, BackoffStart :: pos_integer(),
           BackoffMax :: pos_integer() | infinity},
          [ChildSpec :: supervisor:child_spec(), ...]}} |
    ignore.
```

The backoff specification uses the `backoff` library with corresponding
type, start and maximum. As with a `simple_one_for_one` `supervisor`
there must be exactly one child specification.

License
-------

Apache License, Version 2.0
