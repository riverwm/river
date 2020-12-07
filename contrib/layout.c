/*
 * Tiled layout for river, implemented in understandable, simple, commented code.
 * Reading this code should help you get a basic understanding of how to use
 * river-layout to create a basic layout generator and how your layouts can
 * depend on values of river-options.
 *
 * Q: Wow, this is a lot of code just for a layout!
 * A: No, it really is not. Most of the code here is just generic Wayland client
 *    boilerplate. The actual layout part is pretty small.
 *
 * Q: Can I use this to port dwm layouts to river?
 * A: Yes you can! You just need to replace the logic in layout_handle_layout_demand().
 *    You don't even need to fully understand the protocol if all you want to
 *    do is just port some simple layouts.
 *
 * Q: I have no idea how any of this works.
 * A: If all you want to do is create simple layouts, you do not need to
 *    understand the Wayland parts of the code. If you still want to understand
 *    it and are already familiar with how Wayland clients work, read the
 *    protocol. If you are new to writing Wayland client code, you can read
 *    https://wayland-book.com, then read the protocol.
 *
 * Q: How do I build this?
 * A: To build, you need to generate the header and code of the layout protocol
 *    extension and link against them. This is achieved with the following
 *    commands (You may want to setup a build system).
 *
 *        wayland-scanner private-code < river-layout-v1.xml > river-layout-v1.c
 *        wayland-scanner client-header < river-layout-v1.xml > river-layout-v1.h
 *        wayland-scanner private-code < river-options-v2.xml > river-options-v2.c
 *        wayland-scanner client-header < river-options-v2.xml > river-options-v2.h
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o layout.o layout.c
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o river-layout-v1.o river-layout-v1.c
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o river-options-v2.o river-options-v2.c
 *        gcc -o layout layout.o river-layout-v1.o river-options-v2.o -lwayland-client
 */

#include<assert.h>
#include<stdbool.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#include<wayland-client.h>
#include<wayland-client-protocol.h>

#include"river-layout-v1.h"
#include"river-options-v2.h"

/* A few macros to indulge the inner glibc user. */
#define MIN(a, b) ( a < b ? a : b )
#define MAX(a, b) ( a > b ? a : b )
#define CLAMP(a, b, c) ( MIN(MAX(b, c), MAX(MIN(b, c), a)) )

enum Option_type
{
	UINT_OPTION,
	DOUBLE_OPTION
};

struct Option
{
	struct Output *output;
	struct river_option_handle_v2 *handle;
	enum Option_type type;
	union
	{
		uint32_t u;
		double   d;
	} value;
};

struct Output
{
	struct wl_list link;

	struct wl_output       *output;
	struct river_layout_v1 *layout;

	struct Option main_count;
	struct Option main_factor;
	struct Option view_padding;
	struct Option outer_padding;

	bool configured;
};

/* In Wayland it's a good idea to have your main data global, since you'll need
 * it everywhere anyway.
 */
struct wl_display  *wl_display;
struct wl_registry *wl_registry;
struct wl_callback *sync_callback;
struct river_layout_manager_v1 *layout_manager;
struct river_options_manager_v2 *options_manager;
struct wl_list outputs;
bool loop = true;
int ret = EXIT_FAILURE;

static void layout_handle_layout_demand (void *data, struct river_layout_v1 *river_layout_v1,
		uint32_t view_count, uint32_t width, uint32_t height, uint32_t tags, uint32_t serial)
{
	struct Output *output = (struct Output *)data;

	/* Simple tiled layout with no frills.
	 *
	 * If you want to create your own simple layout, just rip the following
	 * code out and replace it with your own logic. All content un-aware
	 * dynamic tiling layouts you know, for example from dwm, can be easily
	 * ported to river this way. If you want to create layouts that are
	 * content aware, meaning they react to the currently visible windows,
	 * you have to create handlers for the advertise_view and advertise_done
	 * events. Happy hacking!
	 */
	width -= 2 * output->outer_padding.value.u, height -= 2 * output->outer_padding.value.u;
	const double main_factor = CLAMP(output->main_factor.value.d, 0.1, 0.9);
	unsigned int main_size, stack_size, view_x, view_y, view_width, view_height;
	if ( output->main_count.value.u == 0 )
	{
		main_size  = 0;
		stack_size = width;
	}
	else if ( view_count <= output->main_count.value.u )
	{
		main_size  = width;
		stack_size = 0;
	}
	else
	{
		main_size  = width * main_factor;
		stack_size = width - main_size;
	}
	for (unsigned int i = 0; i < view_count; i++)
	{
		if ( i < output->main_count.value.u ) /* main area. */
		{
			view_x      = 0;
			view_width  = main_size;
			view_height = height / MIN(output->main_count.value.u, view_count);
			view_y      = i * view_height;
		}
		else /* Stack area. */
		{
			view_x      = main_size;
			view_width  = stack_size;
			view_height = height / ( view_count - output->main_count.value.u);
			view_y      = (i - output->main_count.value.u) * view_height;
		}

		river_layout_v1_push_view_dimensions(output->layout, serial,
				view_x + output->view_padding.value.u + output->outer_padding.value.u,
				view_y + output->view_padding.value.u + output->outer_padding.value.u,
				view_width - (2 * output->view_padding.value.u),
				view_height - (2 * output->view_padding.value.u));
	}

	river_layout_v1_commit(output->layout, serial);
}

static void layout_handle_namespace_in_use (void *data, struct river_layout_v1 *river_layout_v1)
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

/* A no-op function we plug into listeners when we don't want to handle an event. */
static void noop () {}

static const struct river_layout_v1_listener layout_listener = {
	.namespace_in_use = layout_handle_namespace_in_use,
	.layout_demand    = layout_handle_layout_demand,
	.advertise_view   = noop,
	.advertise_done   = noop,
};

static void option_handle_uint (void *data, struct river_option_handle_v2 *handle,
		uint32_t value)
{
	struct Option *option = (struct Option *)data;

	/* We have received an event with the value of this option. But we
	 * can only use it if it matches the type we want.
	 */
	if ( option->type == UINT_OPTION )
	{
		option->value.u = value;

		/* Our layout depends on the value of this option. We need to
		 * signal the compositor that one of the parameters we use to
		 * generate the layout has changed. It may then decide to start
		 * a new layout demand process.
		 */
		river_layout_v1_parameters_changed(option->output->layout);
	}
}

static void option_handle_fixed (void *data, struct river_option_handle_v2 *handle,
		wl_fixed_t value)
{
	struct Option *option = (struct Option *)data;

	if ( option->type == DOUBLE_OPTION )
	{
		option->value.d = wl_fixed_to_double(value);
		river_layout_v1_parameters_changed(option->output->layout);
	}
}

static const struct river_option_handle_v2_listener option_listener = {
	.int_value    = noop,
	.uint_value   = option_handle_uint,
	.fixed_value  = option_handle_fixed,
	.string_value = noop,

	/* This event will be sent by the compositor when the requested option does
	 * not exist. Since we declared all options we plan on using at startup, we
	 * can safely ignore this event.
	 */
	.undeclared   = noop,
};

static void configure_output (struct Output *output)
{
	output->configured = true;

	/* The namespace of the layout is how the compositor chooses what layout
	 * to use. It can be any arbitrary string. It should describe roughly
	 * what kind of layout your client will create, so here we use "tile".
	 */
	output->layout = river_layout_manager_v1_get_layout(layout_manager,
			output->output, "tile");
	river_layout_v1_add_listener(output->layout, &layout_listener, output);

	/* The amount of main views and other such values are communicated using
	 * river-options. You can have an arbitrary amount of options which hold
	 * arbitrary values. Here we are boring and just use the ones you'd
	 * typically expect for typical tiled layouts.
	 *
	 * Careful: Options can have a wrong type (set by other clients) which
	 * is a special case we have to handle. In case of this example layout
	 * generator it is handled by simply ignoring the wrong events and falling
	 * back to defaults.
	 */
	output->main_count.handle = river_options_manager_v2_get_option_handle(
		options_manager, "main_count", output->output);
	river_option_handle_v2_add_listener(output->main_count.handle,
		&option_listener, &output->main_count);

	output->main_factor.handle = river_options_manager_v2_get_option_handle(
		options_manager, "main_factor", output->output);
	river_option_handle_v2_add_listener(output->main_factor.handle,
		&option_listener, &output->main_factor);

	output->view_padding.handle = river_options_manager_v2_get_option_handle(
		options_manager, "view_padding", output->output);
	river_option_handle_v2_add_listener(output->view_padding.handle,
		&option_listener, &output->view_padding);

	output->outer_padding.handle = river_options_manager_v2_get_option_handle(
		options_manager, "outer_padding", output->output);
	river_option_handle_v2_add_listener(output->outer_padding.handle,
		&option_listener, &output->outer_padding);
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

	output->main_count.value.u = 1;
	output->main_count.handle  = NULL;
	output->main_count.type    = UINT_OPTION;
	output->main_count.output  = output;

	output->main_factor.value.d = 0.6;
	output->main_factor.handle  = NULL;
	output->main_factor.type    = DOUBLE_OPTION;
	output->main_factor.output  = output;

	output->view_padding.value.u = 5;
	output->view_padding.handle  = NULL;
	output->view_padding.type    = UINT_OPTION;
	output->view_padding.output  = output;

	output->outer_padding.value.u = 5;
	output->outer_padding.handle  = NULL;
	output->outer_padding.type    = UINT_OPTION;
	output->outer_padding.output  = output;

	/* If we already have the river_layout_manager and the river_options_manager,
	 * we can get a river_layout for this output.
	 */
	if ( layout_manager != NULL && options_manager != NULL )
		configure_output(output);

	wl_list_insert(&outputs, &output->link);
	return true;
}

static void destroy_output (struct Output *output)
{
	if ( output->layout != NULL )
		river_layout_v1_destroy(output->layout);
	if ( output->main_count.handle != NULL )
		river_option_handle_v2_destroy(output->main_count.handle);
	if ( output->main_factor.handle != NULL )
		river_option_handle_v2_destroy(output->main_factor.handle);
	if ( output->view_padding.handle != NULL )
		river_option_handle_v2_destroy(output->view_padding.handle);
	if ( output->outer_padding.handle != NULL )
		river_option_handle_v2_destroy(output->outer_padding.handle);
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
	if (! strcmp(interface, river_layout_manager_v1_interface.name))
		layout_manager = wl_registry_bind(registry, name,
				&river_layout_manager_v1_interface, 1);
	else if (! strcmp(interface, river_options_manager_v2_interface.name))
		options_manager = wl_registry_bind(registry, name,
				&river_options_manager_v2_interface, 1);
	else if (! strcmp(interface, wl_output_interface.name))
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
		fputs("Wayland compositor does not support river-layout-v1.\n", stderr);
		ret = EXIT_FAILURE;
		loop = false;
		return;
	}

	if ( options_manager == NULL )
	{
		fputs("Wayland compositor does not support river-options-v2.\n", stderr);
		ret = EXIT_FAILURE;
		loop = false;
		return;
	}

	/* The options we want to use may not exist yet, so let's declare them with
	 * some sensible defaults. If they do already exists, river will ignore this.
	 * How these options are named and what you end up doing with them is totally
	 * up to your creativity.
	 */
	 river_options_manager_v2_declare_uint_option(options_manager, "main_count", 1);
	 river_options_manager_v2_declare_fixed_option(options_manager, "main_factor", wl_fixed_from_double(0.6));
	 river_options_manager_v2_declare_uint_option(options_manager, "view_padding", 5);
	 river_options_manager_v2_declare_uint_option(options_manager, "outer_padding", 5);

	/* If outputs were registered before both river_layout_manager and
	 * river_options_manager where available, they won't have a river_layout
	 * nor the option handles, so we need to create those here.
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

	wl_registry = wl_display_get_registry(wl_display);
	wl_registry_add_listener(wl_registry, &registry_listener, NULL);

	/* The sync callback we attach here will be called when all previous
	 * requests have been handled by the server.
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
		river_layout_manager_v1_destroy(layout_manager);
	if ( options_manager != NULL )
		river_options_manager_v2_destroy(options_manager);

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
