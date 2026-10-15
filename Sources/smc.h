#ifndef SMC_H
#define SMC_H
#include <stdint.h>
#include <stdbool.h>

// Низкоуровневый доступ к System Management Controller (датчики, вентиляторы).
int  smc_open(void);
void smc_close(void);
// Чтение ключа: возвращает 0 при успехе, кладёт тип (4 символа) и байты.
int  smc_read(const char *key, char type[5], uint8_t *bytes, uint32_t *size);
// Запись ключа (нужен root).
int  smc_write(const char *key, const uint8_t *bytes, uint32_t size);
uint32_t smc_key_count(void);
int  smc_key_at(uint32_t index, char key[5]);
// Удобные обёртки: значение как double (поддерживает flt, ui8/16/32, fpe2, sp78).
int  smc_read_double(const char *key, double *out);
#endif
