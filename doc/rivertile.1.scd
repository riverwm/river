RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - tiled layout generator for river

# SYNOPSIS

*rivertile* [_options_]

# DESCRIPTION

*rivertile* is a layout client for *river*(1). It provides a simple tiled
layout with split main/secondary stacks. The initial state may be configured
with various options passed on startup. Some values may additionally be
modified while rivertile is running with the help of *riverctl*(1).

# OPTIONS

*-help*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-view-padding* _pixels_
	Set the padding around views in pixels. (Default: 6)

*-outer-padding* _pixels_
	Set the padding around the edge of the layout area in pixels.
	(Default: 6)

*-main-location* [*top*|*bottom*|*left*|*right*]
	Set the initial location of the main area in the layout.
	(Default: *left*)

*-main-count* _count_
	Set the initial number of views in the main area of the
	layout. (Default: 1)

*-main-ratio* _ratio_
	Set the initial ratio of the main area to total layout area. The
	_ratio_ must be between 0.1 and 0.9, inclusive. (Default: 0.6)

# COMMANDS

These commands may be sent to rivertile at runtime with the help of
*riverctl*(1).

*main-location* [*top*|*bottom*|*left*|*right*]
	Set the location of the main area in the layout.

*main-count* _value_
	Set or modify the number of views in the main area of the layout. If
	_value_ is prefixed by a +/- sign, _value_ is added/subtracted from the
	current count. If there is no sign, the main count is set to _value_.

*main-ratio* _value_
	Set or modify the ratio of the main area to total layout area. If
	_value_ is prefixed by a +/- sign, _value_ is added/subtracted from
	the current ratio. If there is no sign, the main ratio is set to
	_value_. Note that the ratio will always be clamped to the range
	0.1 to 0.9.

# EXAMPLES

Start *rivertile* with 4 pixels outer padding and the *top* main location:

	rivertile -outer-padding 4 -main-location top

Increase the main ratio by 0.1 at runtime:

	riverctl send-layout-cmd rivertile "main-ratio +0.1"

Set the main count to 3 at runtime:

	riverctl send-layout-cmd rivertile "main-count 3"

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
