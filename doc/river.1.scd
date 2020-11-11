RIVER(1) "github.com/ifreund/river" "General Commands Manual"
# NAME

river - dynamic tiling Wayland compositor

# SYNOPSIS

*river* [*-c* _shell_command_] [*-l* _log_level_]

# DESCRIPTION

*river* is a dynamic tiling Wayland compositor inspired by dwm and
bspwm based on wlroots and written in Zig.

# OPTIONS

*-c* _shell_command_
	Run a shell command or give the path to a script that will be run
	after river's wayland server is initialized but before entering the
	main loop. You may use this to configure river and define keymaps
	using *riverctl*(1), start programs such as a status bar, or perhaps
	run a service manager. If the process started by this flag is still
	running when river exits, river will send SIGTERM and and wait for it
	to terminate.

*-l* _log_level_
	Set the log level of river to a value from 0 to 7 with 0 being the
	least verbose and 7 being the most verbose. The default log level of
	release-safe builds is 5.

# CONFIGURATION

You can define the list of programs which should float in _Config.zig_.
Make your changes and recompile.

Experimental XWayland support can be enabled on compile-time with the
_-Dxwayland=true_ flag.

# ENVIRONMENT

The following environment variables are used to configure the keyboard. See
*xkeyboard-config*(7) for possible values.

- XKB_DEFAULT_MODEL
- XKB_DEFAULT_LAYOUT
- XKB_DEFAULT_VARIANT
- XKB_DEFAULT_OPTIONS
- XKB_DEFAULT_RULES

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*riverctl*(1), *river-layouts*(7), *rivertile*(1)
