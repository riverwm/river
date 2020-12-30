RIVER(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

river - Dynamic tiling Wayland compositor

# SYNOPSIS

*river* [*-c* _shell_command_] [*-l* _log_level_]

# DESCRIPTION

*river* is a dynamic tiling Wayland compositor inspired by dwm and bspwm based
on wlroots and written in Zig.

# OPTIONS

*-c* _shell_command_
	Override the default search paths for an init executable: instead
	_shell_command_ will be run with `/bin/sh -c`. See the *CONFIGURATION*
	section for more details.

*-l* _log_level_
	Set the log level of river to a value from 0 to 7 with 0 being the
	least verbose and 7 being the most verbose. The default log level of
	release-safe builds is 5.

# CONFIGURATION

On startup river will look for and run an executable file at one of the
following locations, checked in the order listed:

- $XDG_CONFIG_HOME/river/init
- $HOME/.config/river/init
- /etc/river/init

This executable init file will be run after river's wayland server is
initialized but before entering the main loop. If the process started by
this flag is still running when river exits, river will send SIGTERM and
and wait for it to terminate.

Usually this will be a shell script invoking *riverctl*(1) to create mappings,
start programs such as a status bar, and preform other configuration.

# ENVIRONMENT

The following environment variables are used to configure the keyboard. See
*xkeyboard-config*(7) for possible values.

- XKB_DEFAULT_MODEL
- XKB_DEFAULT_LAYOUT
- XKB_DEFAULT_VARIANT
- XKB_DEFAULT_OPTIONS
- XKB_DEFAULT_RULES

# EXAMPLES

Set the keyboard layout to colemak:

	XKB_DEFAULT_LAYOUT="us(colemak)" river

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*riverctl*(1), *river-layouts*(7), *rivertile*(1)
