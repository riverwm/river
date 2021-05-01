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

*-main-factor* _ratio_
	Set the initial ratio of main area to total layout area. (Default: 0.6)

# VALUES

These values may be modified while rivertile is running with the help of
*riverctl*(1).

_main_location_ (string: top, bottom, left, or right)
	The location of the main area in the layout.

_main_count_ (int)
	The number of views in the main area of the layout.

_main_factor_ (fixed: [0.1, 0.9])
	The ratio of main area to total layout area.

# EXAMPLES

Start *rivertile* with 4 pixels outer padding and 2 main views:

	rivertile -outer-padding 4 -main-count 2

Set the main location of rivertile to top at runtime:

	riverctl send-layout-value rivertile string main_location top

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
