#define WLR_USE_UNSTABLE
#include <wlr/backend.h>
#include <wlr/render/wlr_renderer.h>

struct wlr_backend *river_wlr_backend_autocreate(struct wl_display *display) {
    return wlr_backend_autocreate(display, NULL);
}

struct wlr_renderer *river_wlr_backend_get_renderer(struct wlr_backend *backend) {
    return wlr_backend_get_renderer(backend);
}
