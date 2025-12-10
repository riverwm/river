RIVER(1)

# NAME

river - dynamic tiling Wayland compositor

# SYNOPSIS

*river* [_options_]

# DESCRIPTION

River is a non-monolithic Wayland compositor, it does not combine the compositor
and window manager into one program. Instead, users can choose any window
manager implementing the river-window-management-v1 protocol.

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

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs. For example, *kanshi*(1) could be started
to manage output configuration.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about river's development, see
<https://isaacfreund.com/software/river>.
