/*
 * Tiled layout for river, implemented in understandable, simple, commented code.
 * Reading this code should help you get a basic understanding of how to use
 * river-layout to create a basic layout generator.
 *
 * Q: Wow, this is a lot of code just for a layout!
 * A: No, it really is not. Most of the code here is just generic Wayland client
 *    boilerplate. The actual layout part is pretty small.
 *
 * Q: Can I use this to port dwm layouts to river?
 * A: Yes you can! You just need to replace the logic in layout_handle_layout_demand().
 *    You don't even need to fully understand the protocol if all you want to
 *    do is just port some layouts.
 *
 * Q: I have no idea how any of this works.
 * A: If all you want to do is create layouts, you do not need to understand
 *    the Wayland parts of the code. If you still want to understand it and are
 *    familiar with how Wayland clients work, read the protocol. If you are new
 *    to writing Wayland client code, you can read https://wayland-book.com,
 *    then read the protocol.
 *
 * Q: How do I build this?
 * A: To build, you need to generate the header and code of the layout protocol
 *    extension and link against them. This is achieved with the following
 *    commands (You may want to setup a build system).
 *
 *        wayland-scanner private-code < river-layout-v3.xml > river-layout-v3.c
 *        wayland-scanner client-header < river-layout-v3.xml > river-layout-v3.h
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o layout.o layout.c
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o river-layout-v3.o river-layout-v3.c
 *        gcc -o layout layout.o river-layout-v3.o -lwayland-client
 */

#include <assert.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>
#include <wayland-client-protocol.h>

#include "river-layout-v3.h"

/* A few macros to indulge the inner glibc user. */
#define MIN(a, b) ( a < b ? a : b )
#define MAX(a, b) ( a > b ? a : b )
#define CLAMP(a, b, c) ( MIN(MAX(b, c), MAX(MIN(b, c), a)) )

struct Output
{
	struct wl_list link;

	struct wl_output       *output;
	struct river_layout_v3 *layout;

	uint32_t main_count;
	double main_ratio;
	uint32_t view_padding;
	uint32_t outer_padding;

	bool configured;
};

/* In Wayland it's a good idea to have your main data global, since you'll need
 * it everywhere anyway.
 */
struct wl_display  *wl_display;
struct wl_registry *wl_registry;
struct wl_callback *sync_callback;
struct river_layout_manager_v3 *layout_manager;
struct wl_list outputs;
bool loop = true;
int ret = EXIT_FAILURE;

static void layout_handle_layout_demand (void *data, struct river_layout_v3 *river_layout_v3,
		uint32_t view_count, uint32_t width, uint32_t height, uint32_t tags, uint32_t serial)
{
	struct Output *output = (struct Output *)data;

	/* Simple tiled layout with no frills.
	 *
	 * If you want to create your own layout, just rip the following code
	 * out and replace it with your own logic. All dynamic tiling layouts
	 * you know, for example from dwm, can be easily ported to river this
	 * way. For more creative layouts, you probably also want to add custom
	 * values. Happy hacking!
	 */
	width -= 2 * output->outer_padding, height -= 2 * output->outer_padding;
	unsigned int main_size, stack_size, view_x, view_y, view_width, view_height;
	if ( output->main_count == 0 )
	{
		main_size  = 0;
		stack_size = width;
	}
	else if ( view_count <= output->main_count )
	{
		main_size  = width;
		stack_size = 0;
	}
	else
	{
		main_size  = width * output->main_ratio;
		stack_size = width - main_size;
	}
	for (unsigned int i = 0; i < view_count; i++)
	{
		if ( i < output->main_count ) /* main area. */
		{
			view_x      = 0;
			view_width  = main_size;
			view_height = height / MIN(output->main_count, view_count);
			view_y      = i * view_height;
		}
		else /* Stack area. */
		{
			view_x      = main_size;
			view_width  = stack_size;
			view_height = height / ( view_count - output->main_count);
			view_y      = (i - output->main_count) * view_height;
		}

		river_layout_v3_push_view_dimensions(output->layout,
				view_x + output->view_padding + output->outer_padding,
				view_y + output->view_padding + output->outer_padding,
				view_width - (2 * output->view_padding),
				view_height - (2 * output->view_padding),
				serial);
	}

	/* Committing the layout means telling the server that your code is done
	 * laying out windows. Make sure you have pushed exactly the right
	 * amount of view dimensions, a mismatch is a protocol error.
	 *
	 * You also have to provide a layout name. This is a user facing string
	 * that the server can forward to status bars. You can use it to tell
	 * the user which layout is currently in use. You could also add some
	 * status information about your layout, but in this example we are
	 * boring and just use a static "[]=" like in dwm.
	 */
	river_layout_v3_commit(output->layout, "[]=", serial);
}

static void layout_handle_namespace_in_use (void *data, struct river_layout_v3 *river_layout_v3)
{
	/* Oh no, the namespace we choose is already used by another client!
	 * All we can do now is destroy the river_layout object. Because we are
	 * lazy, we just abort and let our cleanup mechanism destroy it. A more
	 * sophisticated client could instead destroy only the one single
	 * affected river_layout object and recover from this mishap. Writing
	 * such a client is left as an exercise for the reader.
	 */
	fputs("Namespace already in use.\n", stderr);
	loop = false;
}

static bool skip_whitespace (char **ptr)
{
	if ( *ptr == NULL )
		return false;
	while (isspace(**ptr))
	{
		(*ptr)++;
		if ( **ptr == '\0' )
			return false;
	}
	return true;
}

static bool skip_nonwhitespace (char **ptr)
{
	if ( *ptr == NULL )
		return false;
	while (! isspace(**ptr))
	{
		(*ptr)++;
		if ( **ptr == '\0' )
			return false;
	}
	return true;
}

static const char *get_second_word (char **ptr, const char *name)
{
	/* Skip to the next word. */
	if ( !skip_nonwhitespace(ptr) || !skip_whitespace(ptr) )
	{
		fprintf(stderr, "ERROR: Too few arguments. '%s' needs one argument.\n", name);
		return NULL;
	}

	/* Now we know where the second word begins. */
	const char *second_word = *ptr;

	/* Check if there is a third word. */
	if ( skip_nonwhitespace(ptr) && skip_whitespace(ptr) )
	{
		fprintf(stderr, "ERROR: Too many arguments. '%s' needs one argument.\n", name);
		return NULL;
	}

	return second_word;
}

static void handle_uint32_command (char **ptr, uint32_t *value, const char *name)
{
	const char *second_word = get_second_word(ptr, name);
	if ( second_word == NULL )
		return;
	const int32_t arg = atoi(second_word);
	if ( *second_word == '+' || *second_word == '-' )
		*value = (uint32_t)MAX((int32_t)*value + arg, 0);
	else
		*value = (uint32_t)MAX(arg, 0);
}

static void handle_float_command(char **ptr, double *value, const char *name, double clamp_upper, double clamp_lower)
{
	const char *second_word = get_second_word(ptr, name);
	if ( second_word == NULL )
		return;
	const double arg = atof(second_word);
	if ( *second_word == '+' || *second_word == '-' )
		*value = CLAMP(*value + arg, clamp_upper, clamp_lower);
	else
		*value = CLAMP(arg, clamp_upper, clamp_lower);
}

static bool word_comp (const char *word, const char *comp)
{
	if ( strncmp(word, comp, strlen(comp)) == 0 )
	{
		const char *after_comp = word + strlen(comp);
		if ( isspace(*after_comp) ||  *after_comp == '\0' )
			return true;
	}
	return false;

}

static void layout_handle_user_command (void *data, struct river_layout_v3 *river_layout_manager_v3,
		const char *_command)
{
	/* The user_command event will be received whenever the user decided to
	 * send us a command. As an example, commands can be used to change the
	 * layout values. Parsing the commands is the job of the layout
	 * generator, the server just sends us the raw string.
	 *
	 * After this event is recevied, the views on the output will be
	 * re-arranged and so we will also receive a layout_demand event.
	 */

	struct Output *output = (struct Output *)data;

	/* Skip preceding whitespace. */
	char *command = (char *)_command;
	if (! skip_whitespace(&command))
		return;

	if (word_comp(command, "main_count"))
		handle_uint32_command(&command, &output->main_count, "main_count");
	else if (word_comp(command, "view_padding"))
		handle_uint32_command(&command, &output->view_padding, "view_padding");
	else if (word_comp(command, "outer_padding"))
		handle_uint32_command(&command, &output->outer_padding, "outer_padding");
	else if (word_comp(command, "main_ratio"))
		handle_float_command(&command, &output->main_ratio, "main_ratio", 0.1, 0.9);
	else if (word_comp(command, "reset"))
	{
		/* This is an example of a command that does something different
		 * than just modifying a value. It resets all values to their
		 * defaults.
		 */

		if ( skip_nonwhitespace(&command) && skip_whitespace(&command) )
		{
			fputs("ERROR: Too many arguments. 'reset' has no arguments.\n", stderr);
			return;
		}

		output->main_count    = 1;
		output->main_ratio    = 0.6;
		output->view_padding  = 5;
		output->outer_padding = 5;
	}
	else
		fprintf(stderr, "ERROR: Unknown command: %s\n", command);
}

static const struct river_layout_v3_listener layout_listener = {
	.namespace_in_use = layout_handle_namespace_in_use,
	.layout_demand    = layout_handle_layout_demand,
	.user_command     = layout_handle_user_command,
};

static void configure_output (struct Output *output)
{
	output->configured = true;

	/* The namespace of the layout is how the compositor chooses what layout
	 * to use. It can be any arbitrary string. It should describe roughly
	 * what kind of layout your client will create, so here we use "tile".
	 */
	output->layout = river_layout_manager_v3_get_layout(layout_manager,
			output->output, "tile");
	river_layout_v3_add_listener(output->layout, &layout_listener, output);
}

static bool create_output (struct wl_output *wl_output)
{
	struct Output *output = calloc(1, sizeof(struct Output));
	if ( output == NULL )
	{
		fputs("Failed to allocate.\n", stderr);
		return false;
	}

	output->output     = wl_output;
	output->layout     = NULL;
	output->configured = false;

	/* These are the parameters of our layout. In this case, they are the
	 * ones you'd typically expect from a dynamic tiling layout, but if you
	 * are creative, you can do more. You can use any arbitrary amount of
	 * all kinds of values in your layout. If the user wants to change a
	 * value, the server lets us know using user_command event of the
	 * river_layout object.
	 *
	 * A layout generator is responsible for having sane defaults for all
	 * layout values. The server only sends user_command events when there
	 * actually is a command the user wants to send us.
	 */
	output->main_count    = 1;
	output->main_ratio    = 0.6;
	output->view_padding  = 5;
	output->outer_padding = 5;

	/* If we already have the river_layout_manager, we can get a
	 * river_layout object for this output.
	 */
	if ( layout_manager != NULL )
		configure_output(output);

	wl_list_insert(&outputs, &output->link);
	return true;
}

static void destroy_output (struct Output *output)
{
	if ( output->layout != NULL )
		river_layout_v3_destroy(output->layout);
	wl_output_destroy(output->output);
	wl_list_remove(&output->link);
	free(output);
}

static void destroy_all_outputs ()
{
	struct Output *output, *tmp;
	wl_list_for_each_safe(output, tmp, &outputs, link)
		destroy_output(output);
}

static void registry_handle_global (void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version)
{
	if ( strcmp(interface, river_layout_manager_v3_interface.name) == 0 )
		layout_manager = wl_registry_bind(registry, name,
				&river_layout_manager_v3_interface, 1);
	else if ( strcmp(interface, wl_output_interface.name) == 0 )
	{
		struct wl_output *wl_output = wl_registry_bind(registry, name,
				&wl_output_interface, version);
		if (! create_output(wl_output))
		{
			loop = false;
			ret = EXIT_FAILURE;
		}
	}
}

/* A no-op function we plug into listeners when we don't want to handle an event. */
static void noop () {}

static const struct wl_registry_listener registry_listener = {
	.global        = registry_handle_global,
	.global_remove = noop
};

static void sync_handle_done (void *data, struct wl_callback *wl_callback,
		uint32_t irrelevant)
{
	wl_callback_destroy(wl_callback);
	sync_callback = NULL;

	/* When this function is called, the registry finished advertising all
	 * available globals. Let's check if we have everything we need.
	 */
	if ( layout_manager == NULL )
	{
		fputs("Wayland compositor does not support river-layout-v3.\n", stderr);
		ret = EXIT_FAILURE;
		loop = false;
		return;
	}

	/* If outputs were registered before the river_layout_manager is
	 * available, they won't have a river_layout, so we need to create those
	 * here.
	 */
	struct Output *output;
	wl_list_for_each(output, &outputs, link)
		if (! output->configured)
			configure_output(output);
}

static const struct wl_callback_listener sync_callback_listener = {
	.done = sync_handle_done,
};

static bool init_wayland (void)
{
	/* We query the display name here instead of letting wl_display_connect()
	 * figure it out itself, because libwayland (for legacy reasons) falls
	 * back to using "wayland-0" when $WAYLAND_DISPLAY is not set, which is
	 * generally not desirable.
	 */
	const char *display_name = getenv("WAYLAND_DISPLAY");
	if ( display_name == NULL )
	{
		fputs("WAYLAND_DISPLAY is not set.\n", stderr);
		return false;
	}

	wl_display = wl_display_connect(display_name);
	if ( wl_display == NULL )
	{
		fputs("Can not connect to Wayland server.\n", stderr);
		return false;
	}

	wl_list_init(&outputs);

	/* The registry is a global object which is used to advertise all
	 * available global objects.
	 */
	wl_registry = wl_display_get_registry(wl_display);
	wl_registry_add_listener(wl_registry, &registry_listener, NULL);

	/* The sync callback we attach here will be called when all previous
	 * requests have been handled by the server. This allows us to know the
	 * end of the startup, at which point all necessary globals should be
	 * bound.
	 */
	sync_callback = wl_display_sync(wl_display);
	wl_callback_add_listener(sync_callback, &sync_callback_listener, NULL);

	return true;
}

static void finish_wayland (void)
{
	if ( wl_display == NULL )
		return;

	destroy_all_outputs();

	if ( sync_callback != NULL )
		wl_callback_destroy(sync_callback);
	if ( layout_manager != NULL )
		river_layout_manager_v3_destroy(layout_manager);

	wl_registry_destroy(wl_registry);
	wl_display_disconnect(wl_display);
}

int main (int argc, char *argv[])
{
	if (init_wayland())
	{
		ret = EXIT_SUCCESS;
		while ( loop && wl_display_dispatch(wl_display) != -1 );
	}
	finish_wayland();
	return ret;
}
