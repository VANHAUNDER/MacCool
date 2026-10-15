// maccoolctl — минимальный помощник для управления вентиляторами.
// Запись в SMC требует root, поэтому этот бинарник устанавливается
// с владельцем root и битом setuid. Он принимает только три команды:
//   maccoolctl auto          — вернуть управление системе
//   maccoolctl max           — все вентиляторы на максимум
//   maccoolctl set <0-100>   — процент между минимумом и максимумом
#include "smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fan_count(void) {
    double n = 0;
    if (smc_read_double("FNum", &n)) return 0;
    return (int)n;
}

static int write_u8(const char *key, uint8_t v) { return smc_write(key, &v, 1); }

static int write_float(const char *key, float v) {
    uint8_t b[4];
    memcpy(b, &v, 4);
    return smc_write(key, b, 4);
}

static int set_auto(int fans) {
    int err = 0;
    char key[5];
    for (int i = 0; i < fans; i++) {
        snprintf(key, sizeof key, "F%dmd", i);
        if (write_u8(key, 0)) err = 1;
    }
    return err;
}

static int set_percent(int fans, double pct) {
    int err = 0;
    char key[5];
    for (int i = 0; i < fans; i++) {
        double mn = 0, mx = 0;
        snprintf(key, sizeof key, "F%dMn", i);
        smc_read_double(key, &mn);
        snprintf(key, sizeof key, "F%dMx", i);
        smc_read_double(key, &mx);
        if (mx <= 0) { err = 1; continue; }
        double rpm = mn + (mx - mn) * pct / 100.0;

        snprintf(key, sizeof key, "F%dmd", i);
        if (write_u8(key, 1)) err = 1;
        snprintf(key, sizeof key, "F%dTg", i);
        if (write_float(key, (float)rpm)) err = 1;
    }
    return err;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: maccoolctl auto | max | set <0-100>\n");
        return 2;
    }
    // Для setuid-бинарника поднимаем реальный uid до root, иначе AppleSMC не даст писать.
    if (geteuid() == 0) setuid(0);

    if (smc_open()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    int fans = fan_count();
    if (fans <= 0) { fprintf(stderr, "no fans found\n"); return 1; }

    int err;
    if (!strcmp(argv[1], "auto")) {
        err = set_auto(fans);
    } else if (!strcmp(argv[1], "max")) {
        err = set_percent(fans, 100);
    } else if (!strcmp(argv[1], "set") && argc == 3) {
        char *end;
        double pct = strtod(argv[2], &end);
        if (*end || pct < 0 || pct > 100) { fprintf(stderr, "percent must be 0-100\n"); return 2; }
        err = set_percent(fans, pct);
    } else {
        fprintf(stderr, "unknown command\n");
        return 2;
    }
    smc_close();
    if (err) {
        fprintf(stderr, geteuid() == 0 ? "SMC write failed\n" : "SMC write failed (need root)\n");
        return 1;
    }
    return 0;
}
