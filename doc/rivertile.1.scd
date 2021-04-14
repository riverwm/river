RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - Tiled layout generator for river

# SYNOPSIS

*rivertile*

# DESCRIPTION

*rivertile* is a layout client for river. It provides a simple tiled layout
split main/secondary stacks.

# OPTIONS

These options may be set using *riverctl*(1) or another river-options
wayland client. *rivertile* declares these options on startup, so setting
these options before starting rivertile requires them to be declared manually.

*main_location* (string, default "top")
	The location of the main area. Vaild locations are "top", "bottom",
	"left", and "right".

*main_count* (uint, default 1)
	The number of main views.

*main_factor* (fixed, default 0.6)
	The percentage of the layout area reserved for main views. *rivertle*
	clamps this to the range `[0.1, 0.9]`.

*view_padding* (uint, default 6)
	Padding around every view in pixels.

*outer_padding* (uint, default 6)
	Padding around the edge of the layout area in pixels.

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
