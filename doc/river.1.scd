RIVER(1) "github.com/riverwm/river" "General Commands Manual"

# NAME

river - dynamic tiling Wayland compositor

# SYNOPSIS

*river* [_options_]

# DESCRIPTION

*river* is a dynamic tiling Wayland compositor. Window management is based on
a stack of views laid out dynamically by an external layout generator. Tags
are used instead of workspaces allowing for increased flexibility.

All configuration and control happens at runtime through Wayland protocols,
including several river-specific protocol extensions. The *riverctl*(1)
utility may be used to communicate with river over these protocols.

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-c* _shell_command_
	Override the default search paths for an init executable: instead
	_shell_command_ will be run with _/bin/sh -c_. See the *CONFIGURATION*
	section for more details.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level of river. At the *error* log level, only errors
	are logged.  At the *debug* log level, everything is logged including
	verbose debug messages.

*-no-xwayland*
	Disable xwayland at runtime even if river has been built with support.

# CONFIGURATION

On startup river will run an executable file at $XDG_CONFIG_HOME/river/init if
such an executable exists. If $XDG_CONFIG_HOME is not set, ~/.config/river/init
will be used instead.

The executable init file will be run as a process group leader after river's
Wayland server is initialized but before entering the main loop. On exit,
river will send SIGTERM to this process group.

Usually this executable is a shell script invoking *riverctl*(1) to create
mappings, start programs such as a layout generator or status bar, and
perform other configuration.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/riverwm/river>.

# SEE ALSO

*riverctl*(1), *rivertile*(1)
