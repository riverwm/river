## Contributing to river

Contributing is as simple as opening a pull request on
[codeberg](https://codeberg.org/river/river).
You'll likely have more success with your contribution if you visit
[#river](https://web.libera.chat/?channels=#river) on irc.libera.chat to discuss
your plans first.

## Commit messages

Please take the time to write a good commit message, having a clean git
history makes maintaining and contributing to river easier. Commit messages
should start with a prefix indicating what part of river is affected by the
change, followed by a brief summary.

For example:

```
build: scan river-status protocol
```

or

```
river-status: send view_tags on view map/unmap
```

In addition to the summary, feel free to add any other details you want preceded
by a blank line. A good rule of thumb is that anything you would write in a pull
request description on codeberg has a place in the commit message as well.

For further details regarding commit style and git history see
[weston's contributing guidelines](https://gitlab.freedesktop.org/wayland/weston/-/blob/master/CONTRIBUTING.md#formatting-and-separating-commits).

## Coding style

Please follow the
[Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
and run `zig fmt` before every commit. With regards to line length, keep it
under 100 columns in general but prioritize readability over adhering to a
strict limit. Note that inserting a trailing comma after the last parameter in
function calls, struct declarations, etc. will cause `zig fmt` to wrap those
lines. I highly recommend configuring your editor to run `zig fmt` on write.

The single additional style rule is to avoid writing `if` statements and
similar across multiple lines without braces:

```zig
test {
    // avoid this
    if (foo)
        bar();

    // prefer this
    if (foo) bar();

    // or this
    if (foo) {
        bar();
    }
}
```

On a higher level, prioritize simplicity of code over nearly everything else.
Performance is only a valid reason for code complexity if there are profiling
results to back it up which demonstrate a significant benefit.
