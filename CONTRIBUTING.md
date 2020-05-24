## Contributing to river

Contributing is a simple as opening a pull request on our github. You'll likely
have more success with your contribution if you hop on our
[matrix channel](https://matrix.to/#/#river:matrix.org) to discuss your plans
first.

## Commit messages

Please take the time to write a good commit message, having a clean git history
makes maintaining and contributing to river easier. Commit messages should start
with a summary in 50 characters or less. This summary should complete the
sentence "When applied, this commit will...". 

In addition to the summary, feel free to add any other details you want preceded
by a blank line. A good rule of thumb is that anything you would write in a pull
request description on github has a place in the commit message as well.

For more discussion and details of good commit message practices, check out
[this post](https://chris.beams.io/posts/git-commit/).

## Coding style

Please follow the
[Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
and run `zig fmt` before every commit. With regards to line length, consider 100
characters to be a hard upper limit and 80 or less to be the goal. Note that
inserting a trailing comma after the last parameter in function calls, struct
declarations, etc. will cause `zig fmt` to wrap those lines. I highly recommend
configuring your editor to run `zig fmt` on write.

On a higher level, prioritize simplicity of code over nearly everything else.
Performance is only a valid reason for code complexity if there are profiling
results to back it up which demonstrate a significant benefit.
