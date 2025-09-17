#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "libkmod.h"
#include "libfdt.h"

char **modules = NULL;
int module_count = 0;
char **files = NULL;
int file_count = 0;

void add_string_to_list(char ***list, int *count, const char *str) {
    for (int i = 0; i < *count; i++) {
        if (strcmp((*list)[i], str) == 0) {
            return;
        }
    }
    *list = realloc(*list, (*count + 1) * sizeof(char *));
    (*list)[(*count)++] = strdup(str);
}

void find_modules_in_dtb(const char *dtb_path, struct kmod_ctx *ctx) {
    int fd = open(dtb_path, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return;
    }

    struct stat st;
    fstat(fd, &st);
    void *fdt = malloc(st.st_size);
    read(fd, fdt, st.st_size);
    close(fd);

    if (fdt_check_header(fdt) != 0) {
        fprintf(stderr, "Invalid DTB file: %s\n", dtb_path);
        free(fdt);
        return;
    }

    int offset, len;
    for (offset = fdt_next_node(fdt, -1, NULL); offset >= 0; offset = fdt_next_node(fdt, offset, NULL)) {
        const char *compatible = fdt_getprop(fdt, offset, "compatible", &len);
        if (compatible) {
            const char *p = compatible;
            while (p < compatible + len) {
                char modalias[512];
                snprintf(modalias, sizeof(modalias), "of:N*T*C%s", p);

                struct kmod_list *list = NULL;
                if (kmod_module_new_from_lookup(ctx, modalias, &list) == 0 && list) {
                    struct kmod_list *l;
                    kmod_list_foreach(l, list) {
                        struct kmod_module *mod = kmod_module_get_module(l);
                        add_string_to_list(&modules, &module_count, kmod_module_get_name(mod));
                        kmod_module_unref(mod);
                    }
                    kmod_module_unref_list(list);
                }
                p += strlen(p) + 1;
            }
        }

        const char *firmware_name = fdt_getprop(fdt, offset, "firmware-name", NULL);
        if (firmware_name) {
            char file_path[1024];
            snprintf(file_path, sizeof(file_path), "/lib/firmware/%s", firmware_name);
            add_string_to_list(&files, &file_count, file_path);
        }
    }

    free(fdt);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <module_dir> <dtb_file1> [<dtb_file2> ...]\n", argv[0]);
        return 1;
    }

    const char *module_dir = argv[1];
    struct kmod_ctx *ctx;

    ctx = kmod_new(module_dir, NULL);
    if (ctx == NULL) {
        fprintf(stderr, "Failed to create kmod context\n");
        return 1;
    }

    for (int i = 2; i < argc; i++) {
        find_modules_in_dtb(argv[i], ctx);
    }

    for (int i = 0; i < module_count; i++) {
        struct kmod_module *mod;
        if (kmod_module_new_from_name(ctx, modules[i], &mod) == 0) {
            struct kmod_list *info = NULL;
            if (kmod_module_get_info(mod, &info) >= 0 && info) {
                struct kmod_list *l;
                kmod_list_foreach(l, info) {
                    const char *key = kmod_module_info_get_key(l);
                    const char *value = kmod_module_info_get_value(l);
                    if (key && value && strcmp(key, "firmware") == 0) {
                        char file_path[1024];
                        snprintf(file_path, sizeof(file_path), "/lib/firmware/%s", value);
                        add_string_to_list(&files, &file_count, file_path);
                    }
                }
                kmod_module_info_free_list(info);
            }
            kmod_module_unref(mod);
        }
    }

    printf("MODULES=(\n");
    for (int i = 0; i < module_count; i++) {
        printf("    %s\n", modules[i]);
        free(modules[i]);
    }
    printf(")\n\n");
    free(modules);

    printf("FILES=(\n");
    for (int i = 0; i < file_count; i++) {
        printf("    %s\n", files[i]);
        free(files[i]);
    }
    printf(")\n");
    free(files);

    kmod_unref(ctx);
    return 0;
}
