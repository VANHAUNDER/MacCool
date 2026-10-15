#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t conn = 0;

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}
static void key_to_str(uint32_t k, char out[5]) {
    out[0] = k >> 24; out[1] = k >> 16; out[2] = k >> 8; out[3] = k; out[4] = 0;
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) { if (conn) { IOServiceClose(conn); conn = 0; } }

static int call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t r = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData), out, &outSize);
    if (r != KERN_SUCCESS) return -1;
    return out->result == 0 ? 0 : -2;
}

static int key_info(uint32_t key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &out)) return -1;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, char type[5], uint8_t *bytes, uint32_t *size) {
    if (smc_open()) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = str_to_key(key);
    if (key_info(in.key, &in.keyInfo)) return -1;
    in.data8 = SMC_CMD_READ_BYTES;
    if (call(&in, &out)) return -1;
    if (type) key_to_str(in.keyInfo.dataType, type);
    *size = in.keyInfo.dataSize;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    if (smc_open()) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = str_to_key(key);
    if (key_info(in.key, &in.keyInfo)) return -1;
    if (in.keyInfo.dataSize != size) return -3;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

uint32_t smc_key_count(void) {
    char t[5]; uint8_t b[32]; uint32_t n;
    if (smc_read("#KEY", t, b, &n)) return 0;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

int smc_key_at(uint32_t index, char key[5]) {
    if (smc_open()) return -1;
    SMCKeyData in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX; in.data32 = index;
    if (call(&in, &out)) return -1;
    key_to_str(out.key, key);
    return 0;
}

int smc_read_double(const char *key, double *out) {
    char t[5]; uint8_t b[32]; uint32_t n;
    if (smc_read(key, t, b, &n)) return -1;
    if (!strcmp(t, "flt ") && n == 4) { float f; memcpy(&f, b, 4); *out = f; return 0; }
    if (!strcmp(t, "ui8 ")) { *out = b[0]; return 0; }
    if (!strcmp(t, "ui16")) { *out = (b[0] << 8) | b[1]; return 0; }
    if (!strcmp(t, "ui32")) { *out = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]); return 0; }
    if (!strcmp(t, "fpe2")) { *out = ((b[0] << 8) | b[1]) / 4.0; return 0; }
    if (!strcmp(t, "sp78")) { *out = (int16_t)((b[0] << 8) | b[1]) / 256.0; return 0; }
    return -2;
}
