/*
 * display-topology - enable or disable one external macOS display.
 *
 * Original implementation for https://github.com/felickz/dotfiles.
 * The use of CGSConfigureDisplayEnabled and the safety approach were informed by:
 *
 *   macos-displayctl by Hongbo Liu
 *   https://github.com/hiberabyss/macos-displayctl
 *
 *   displayplacer by Jake Hilborn
 *   https://github.com/jakehilborn/displayplacer
 *
 * Both projects are MIT licensed. Their copyright and license notices are preserved in
 * ../THIRD_PARTY_NOTICES.md. This helper intentionally has a narrower interface, applies
 * session-scoped changes, refuses to touch the built-in display, and requires exactly one
 * online external display.
 *
 * CGSConfigureDisplayEnabled is an undocumented Apple API and may change across macOS
 * releases.
 */

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef CGError (*SetDisplayEnabledFn)(
    CGDisplayConfigRef config,
    CGDirectDisplayID display,
    bool enabled);

static int get_online_displays(CGDirectDisplayID **displays, uint32_t *count) {
    CGError error = CGGetOnlineDisplayList(0, NULL, count);
    if (error != kCGErrorSuccess || *count == 0) {
        fprintf(stderr, "display-topology: unable to enumerate displays (%d)\n", error);
        return 1;
    }

    *displays = calloc(*count, sizeof(**displays));
    if (*displays == NULL) {
        fprintf(stderr, "display-topology: out of memory\n");
        return 1;
    }

    error = CGGetOnlineDisplayList(*count, *displays, count);
    if (error != kCGErrorSuccess) {
        fprintf(stderr, "display-topology: unable to enumerate displays (%d)\n", error);
        free(*displays);
        *displays = NULL;
        return 1;
    }

    return 0;
}

static uint32_t find_externals(
    const CGDirectDisplayID *displays,
    uint32_t count,
    CGDirectDisplayID *external) {
    uint32_t external_count = 0;

    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i])) {
            *external = displays[i];
            external_count++;
        }
    }

    return external_count;
}

static void state_path(char *path, size_t size) {
    snprintf(path, size, "/tmp/felickz-display-topology-%u", getuid());
}

static int save_disabled_display(CGDirectDisplayID display) {
    char path[128];
    state_path(path, sizeof(path));
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        perror("display-topology: unable to save disabled display");
        return 1;
    }
    fprintf(file, "%u\n", display);
    fclose(file);
    return 0;
}

static bool load_disabled_display(CGDirectDisplayID *display) {
    char path[128];
    state_path(path, sizeof(path));
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return false;
    }

    unsigned int value = 0;
    bool loaded = fscanf(file, "%u", &value) == 1;
    fclose(file);
    if (loaded) {
        *display = value;
    }
    return loaded;
}

static void clear_disabled_display(void) {
    char path[128];
    state_path(path, sizeof(path));
    unlink(path);
}

static void print_uuid(CGDirectDisplayID display) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (uuid == NULL) {
        printf("unknown");
        return;
    }

    CFStringRef value = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    if (value == NULL) {
        printf("unknown");
        return;
    }

    char buffer[128];
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
    } else {
        printf("unknown");
    }
    CFRelease(value);
}

static int list_displays(void) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (get_online_displays(&displays, &count) != 0) {
        return 1;
    }

    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displays[i];
        printf(
            "id=%u type=%s state=%s vendor=%u model=%u serial=%u uuid=",
            display,
            CGDisplayIsBuiltin(display) ? "built-in" : "external",
            CGDisplayIsActive(display) ? "enabled" : "disabled",
            CGDisplayVendorNumber(display),
            CGDisplayModelNumber(display),
            CGDisplaySerialNumber(display));
        print_uuid(display);
        printf("\n");
    }

    free(displays);
    return 0;
}

static int external_state(void) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (get_online_displays(&displays, &count) != 0) {
        return 1;
    }

    CGDirectDisplayID external = 0;
    uint32_t external_count = find_externals(displays, count, &external);
    int result = 0;
    if (external_count == 1) {
        printf("%s\n", CGDisplayIsActive(external) ? "enabled" : "disabled");
    } else if (external_count == 0 && load_disabled_display(&external)) {
        printf("disabled\n");
    } else {
        fprintf(
            stderr,
            "display-topology: expected exactly one external display, found %u\n",
            external_count);
        result = 1;
    }

    free(displays);
    return result;
}

static int active_display_count(void) {
    uint32_t count = 0;
    CGError error = CGGetActiveDisplayList(0, NULL, &count);
    if (error != kCGErrorSuccess) {
        return -1;
    }
    return (int)count;
}

static int configure_external(bool enabled, const char *explicit_id) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (get_online_displays(&displays, &count) != 0) {
        return 1;
    }

    CGDirectDisplayID external = 0;
    uint32_t external_count = find_externals(displays, count, &external);
    bool currently_enabled = external_count == 1 && CGDisplayIsActive(external);

    if (explicit_id != NULL) {
        char *end = NULL;
        unsigned long value = strtoul(explicit_id, &end, 10);
        if (end == explicit_id || *end != '\0' || value > UINT32_MAX) {
            fprintf(stderr, "display-topology: invalid display ID: %s\n", explicit_id);
            free(displays);
            return 1;
        }
        external = (CGDirectDisplayID)value;
        currently_enabled = false;
    } else if (external_count == 0 && enabled && load_disabled_display(&external)) {
        currently_enabled = false;
    } else if (external_count != 1) {
        fprintf(
            stderr,
            "display-topology: expected exactly one online external display, found %u\n",
            external_count);
        free(displays);
        return 1;
    }

    for (uint32_t i = 0; i < count; i++) {
        if (displays[i] == external && CGDisplayIsBuiltin(displays[i])) {
            fprintf(stderr, "display-topology: refusing to target the built-in display\n");
            free(displays);
            return 1;
        }
    }

    if (currently_enabled == enabled) {
        printf(
            "External display %u is already %s\n",
            external,
            enabled ? "enabled" : "disabled");
        free(displays);
        return 0;
    }

    if (!enabled) {
        int active_count = active_display_count();
        if (active_count <= 1) {
            fprintf(
                stderr,
                "display-topology: refusing to disable the last active display\n");
            free(displays);
            return 1;
        }
        if (save_disabled_display(external) != 0) {
            free(displays);
            return 1;
        }
    }

    void *core_graphics = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_NOW | RTLD_LOCAL);
    if (core_graphics == NULL) {
        fprintf(
            stderr,
            "display-topology: unable to load CoreGraphics: %s\n",
            dlerror());
        if (!enabled) {
            clear_disabled_display();
        }
        free(displays);
        return 1;
    }

    SetDisplayEnabledFn set_enabled =
        (SetDisplayEnabledFn)dlsym(core_graphics, "CGSConfigureDisplayEnabled");
    if (set_enabled == NULL) {
        fprintf(
            stderr,
            "display-topology: CGSConfigureDisplayEnabled is unavailable\n");
        if (!enabled) {
            clear_disabled_display();
        }
        dlclose(core_graphics);
        free(displays);
        return 1;
    }

    CGDisplayConfigRef config = NULL;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (error == kCGErrorSuccess) {
        error = set_enabled(config, external, enabled);
    }
    if (error != kCGErrorSuccess) {
        if (config != NULL) {
            CGCancelDisplayConfiguration(config);
        }
        fprintf(
            stderr,
            "display-topology: unable to configure display %u (%d)\n",
            external,
            error);
        if (!enabled) {
            clear_disabled_display();
        }
        dlclose(core_graphics);
        free(displays);
        return 1;
    }

    error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    dlclose(core_graphics);
    free(displays);
    if (error != kCGErrorSuccess) {
        fprintf(
            stderr,
            "display-topology: unable to apply display configuration (%d)\n",
            error);
        if (!enabled) {
            clear_disabled_display();
        }
        return 1;
    }

    if (enabled) {
        clear_disabled_display();
    }

    printf(
        "%s external display %u\n",
        enabled ? "Enabled" : "Disabled",
        external);
    return 0;
}

static void usage(const char *program) {
    fprintf(
        stderr,
        "Usage:\n"
        "  %s list\n"
        "  %s state\n"
        "  %s enable [display-id]\n"
        "  %s disable\n",
        program,
        program,
        program,
        program);
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        usage(argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "list") == 0) {
        return list_displays();
    }
    if (strcmp(argv[1], "state") == 0) {
        return external_state();
    }
    if (strcmp(argv[1], "enable") == 0) {
        return configure_external(true, argc == 3 ? argv[2] : NULL);
    }
    if (argc == 2 && strcmp(argv[1], "disable") == 0) {
        return configure_external(false, NULL);
    }

    usage(argv[0]);
    return 2;
}
