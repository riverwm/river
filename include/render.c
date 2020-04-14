#define WLR_USE_UNSTABLE
#include <wlr/backend.h>
#include <wlr/backend/noop.h>
#include <wlr/backend/multi.h>
#include <wlr/render/wlr_renderer.h>

struct wlr_backend *river_wlr_backend_autocreate(struct wl_display *display) {
    return wlr_backend_autocreate(display, NULL);
}

struct wlr_renderer *river_wlr_backend_get_renderer(struct wlr_backend *backend) {
    return wlr_backend_get_renderer(backend);
}

bool river_wlr_backend_start(struct wlr_backend *backend) {
    return wlr_backend_start(backend);
}

bool river_wlr_backend_is_multi(struct wlr_backend *backend) {
    return wlr_backend_is_multi(backend);
}

struct wlr_session *river_wlr_backend_get_session(struct wlr_backend *backend) {
    return wlr_backend_get_session(backend);
}

struct wlr_backend *river_wlr_noop_backend_create(struct wl_display *display) {
    return wlr_noop_backend_create(display);
}

struct wlr_output *river_wlr_noop_add_output(struct wlr_backend *backend) {
    return wlr_noop_add_output(backend);
}
