function __fish_riverctl_complete_no_subcommand
    for i in (commandline -opc)
        if contains -- $i close csd-filter-add exit float-filter-add focus-output focus-view layout mod-main-count mod-main-factor move resize snap send-to-output spawn swap toggle-float toggle-fullscreen zoom set-focused-tags set-view-tags toggle-focused-tags toggle-view-tags spawn-tagmask declare-mode enter-mode map map-pointer unmap unmap-pointer attach-mode background-color border-color-focused border-color-unfocused border-width focus-follows-cursor opacity outer-padding set-repeat view-padding xcursor-theme declare-option get-option set-option unset-option mod-option output_title
            return 1
        end
    end
    return 0
end

# Actions
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a close                  -d 'Close the focued view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a csd-filter-add         -d 'Add app-id to the CSD filter list'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a exit                   -d 'Exit the compositor, terminating the Wayland session'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a float-filter-add       -d 'Add app-id to the float filter list'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-output           -d 'Focus the next or previous output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-view             -d 'Focus the next or previous view in the stack'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a layout                 -d 'Provide a command which river will use for generating the layour of non-floating windows'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a mod-main-count         -d 'Increase or decrease the number of "main" views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a mod-main-factor        -d 'Increase or decrease the "main factor"'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a move                   -d 'Move the focused view in the specified direction'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a resize                 -d 'Resize the focused view along the given axis'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a snap                   -d 'Snap the focused view to the specified screen edge'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a send-to-output         -d 'Send the focused view to the next/previous output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a spawn                  -d 'Run shell_command using /bin/sh -c'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a swap                   -d 'Swap the focused view with the next/previous visible non-floating view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-float           -d 'Toggle the floating state of the focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-fullscreen      -d 'Toggle the fullscreen state of the focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a zoom                   -d 'Bump the focused view to the top of the layout stack'
# Tag managements
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-focused-tags       -d 'Show views with tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-view-tags          -d 'Assign the currently focused view the tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-focused-tags    -d 'Toggle visibility of views with tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-view-tags       -d 'Toggle the tags of the currently focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a spawn-tagmask          -d 'Set a tagmask to filter the tags assigned to newly spawned views on the focused output'
# Mappings
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a declare-mode           -d 'Create a new mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a enter-mode             -d 'Switch to given mode if it exists'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a map                    -d 'Run command when key is pressed while modifiers are held down and in the specified mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a map-pointer            -d 'Move or resize views when button and modifers are held down while in the specified mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a unmap                  -d 'Remove the mapping defined by the arguments'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a unmap-pointer          -d 'Remove the pointer mapping defined by the arguments'
# Configuration
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a attach-mode            -d 'Configure where new views should attach to the view stack for the currently focused output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a background-color       -d 'Set the background color'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-color-focused   -d 'Set the border color of focused views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-color-unfocused -d 'Set the border color of unfocused views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-width           -d 'Set the border width to pixels'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-follows-cursor   -d 'Configure the focus behavior when moving cursor'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a opacity                -d 'Configure server-side opacity of views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a outer-padding          -d 'Set the padding around the edge of the screen to pixels'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-repeat             -d 'Set the keyboard repeat rate and repeat delay'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a view-padding           -d 'Set the padding around the edge of each view to pixels'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a xcursor-theme          -d 'Set the xcursor theme'
# Options
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a declare-option         -d 'Declare a new option with the given type and initial value'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a get-option             -d 'Print the current value of the given option to stdout'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-option             -d 'Set the value of the specified option'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a unset-option           -d 'Unset the value of the specified option for the given output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a mod-option             -d 'Add value to the value of the specified option'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a output_title           -d 'Changing this option changes the title of the Wayland and X11 backend outputs'

# Subcommands
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-output'         -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-view'           -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from layout'               -a 'full'
complete -c riverctl -x -n '__fish_seen_subcommand_from move'                 -a 'up down left right'
complete -c riverctl -x -n '__fish_seen_subcommand_from resize'               -a 'horizontal vertical'
complete -c riverctl -x -n '__fish_seen_subcommand_from snap'                 -a 'up down left right'
complete -c riverctl -x -n '__fish_seen_subcommand_from send-to-output'       -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from swap'                 -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from map'                  -a '-release'
complete -c riverctl -x -n '__fish_seen_subcommand_from unmap'                -a '-release'
complete -c riverctl -x -n '__fish_seen_subcommand_from attach-mode'          -a 'top bottom'
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-follows-cursor' -a 'disabled normal strict'
complete -c riverctl -x -n '__fish_seen_subcommand_from get-option'           -a '-output -focused-output'
complete -c riverctl -x -n '__fish_seen_subcommand_from set-option'           -a '-output -focused-output'
complete -c riverctl -x -n '__fish_seen_subcommand_from unset-option'         -a '-output -focused-output'
complete -c riverctl -x -n '__fish_seen_subcommand_from mod-option'           -a '-output -focused-output'
