# Error applet support

The AM library-applet creator supports the foreground error applet (`0x0e`, mode `0`). It returns a real accessor,
accepts input storage, and acknowledges `Start` without a native dialog. Completion signals the state-change event;
`IsCompleted`, `GetResult` and empty output reads follow that state. The library-applet launchable event is signalled.
Each event query returns a fresh handle, so closing a previous guest handle cannot invalidate a later query.

Known error layouts log numeric error fields. Message/context bytes are not dumped. This is a headless acknowledgement,
not an implementation of player selection, the keyboard, web pages or other interactive applets. Unsupported applet
types, modes and commands fail explicitly. Storage is limited to 1 MiB and an accessor queues at most 16 inputs.

Inputs resolve through their actual moved storage session or the request's own domain; no global last-written storage
is used. Queued storage retains its data until start/close. Storage offsets and domain command-body lengths are bounded,
including malformed requests whose trailing padding resembles valid arguments.

`python3 tools/test_am_applet.py` exercises the production AM/IPC/kernel handlers without game files. It covers the
protocol, event close/requery and handle-slot reuse, moved/domain input identity, storage lifetime and bounds, malformed
domain framing and reset. For sanitizer checks:

```sh
TEST_CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tools/test_am_applet.py
```

The tests do not reproduce an in-game error dialog or prove that a reported game freeze came from this missing protocol.
