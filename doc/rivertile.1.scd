RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - Tiled layout generator for river

# SYNOPSIS

*rivertile*

# DESCRIPTION

*rivertile* is a layout client for river. It provides a simple tiled layout
split main/secondary stacks.

# VALUES

_main_location_ (string: top, bottom, left, or right)
	The location of the main area in the layout.

_main_count_ (int)
	The number of views in the main area of the layout.

_main_factor_ (fixed: [0.1, 0.9])
	The ratio of main area to total layout area.

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
