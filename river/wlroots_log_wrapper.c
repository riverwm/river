#include <assert.h>
#include <stdarg.h>
#include <stdlib.h>

#include <wlr/util/log.h>

#define BUFFER_SIZE 1024

void river_wlroots_log_callback(enum wlr_log_importance importance, const char *ptr, size_t len);

static void callback(enum wlr_log_importance importance, const char *fmt, va_list args) {
	char buffer[BUFFER_SIZE];

	// Need to make a copy of the args in case our buffer isn't big
	// enough and we need to use them again.
	va_list args_copy;
	va_copy(args_copy, args);

	const int length = vsnprintf(buffer, BUFFER_SIZE, fmt, args);
	// Need to add one for the terminating 0 byte
	if (length + 1 <= BUFFER_SIZE) {
		// The formatted string fit within our buffer, pass it on to river
		river_wlroots_log_callback(importance, buffer, length);
	} else {
		// The formatted string did not fit in our buffer, we need
		// to allocate enough memory to hold it.
		char *allocated_buffer = malloc(length + 1);
		if (allocated_buffer != NULL) {
			const int length2 = vsnprintf(allocated_buffer, length + 1, fmt, args_copy);
			assert(length2 == length);
			river_wlroots_log_callback(importance, allocated_buffer, length);
			free(allocated_buffer);
		}
	}

	va_end(args_copy);
}

void river_init_wlroots_log(enum wlr_log_importance importance) {
	wlr_log_init(importance, callback);
}
