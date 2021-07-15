RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - Tiled layout generator for river

# SYNOPSIS

*rivertile* [_options_]

# DESCRIPTION

*rivertile* is a layout client for *river*(1). It provides a simple tiled
layout with split main/secondary stacks. The initial state may be configured
with various options passed on startup. Some values may additionally be
modified while rivertile is running with the help of *riverctl*(1).

# OPTIONS

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
	Set the initial ratio of main area to total layout area. The _ratio_
	must be between 0.1 and 0.9, inclusive. (Default: 0.6)

# COMMANDS

These commands may be sent to rivertile at runtime with the help of
*riverctl*(1).

*set-main-location* [*top*|*bottom*|*left*|*right*]
	Set the location of the main area in the layout.

*set-main-count* _count_
	Set the number of views in the main area of the layout.

*mod-main-count* _delta_
	Modify the number of views in the main area of the layout by a
	positive or negative _delta_.

*set-main-ratio* _ratio_
	Set the ratio of main area to total layout area. The _ratio_ must
	be between 0.1 and 0.9, inclusive.

*mod-main-ratio* _delta_
	Modify the ratio of main area to total layout area by a positive or
	negative _delta_. The resulting ratio will be clamped to be between
	0.1 and 0.9, inclusive.

# EXAMPLES

Start *rivertile* with 4 pixels outer padding and 2 main views:

	rivertile -outer-padding 4 -main-count 2

Set the main location of rivertile to *top* at runtime:

	riverctl send-layout-cmd rivertile "set-main-location top"

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
