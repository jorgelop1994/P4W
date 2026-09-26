#ifndef P4W_PROC_H
#define P4W_PROC_H

#include <stdint.h>
#include <sys/types.h>

/// Memoria que el proceso realmente **posee**: privada + comprimida, sin contar páginas
/// compartidas (dyld shared cache, frameworks). Es la métrica honesta para el costo
/// MARGINAL de N instancias.
///
/// Medido en esta máquina: un proceso `pi` con perfil lean tiene RSS 120 MB pero
/// phys_footprint 77 MB; la diferencia son páginas compartidas que no se pagan por
/// instancia. Devuelve -1 si el pid no existe o la llamada falla.
int64_t p4w_phys_footprint(pid_t pid);

/// Memoria residente (lo que reporta `ps rss`). Incluye páginas compartidas.
int64_t p4w_resident_size(pid_t pid);

/// PIDs hijos directos. Devuelve cuántos escribió, o un valor negativo si falló.
/// `buffer` debe tener lugar para `maxCount` pids.
int p4w_list_children(pid_t pid, pid_t *buffer, int maxCount);

/// PIDs de todos los descendientes (hijos, nietos, …) en anchura.
/// Es la red de seguridad del reaper: hay que enumerarlos ANTES de matar al padre,
/// porque al morir el padre quedan reparentados a launchd y el árbol se pierde.
int p4w_list_descendants(pid_t pid, pid_t *buffer, int maxCount);

/// Termina un proceso y su descendencia. Envía `signal` primero a los descendientes
/// (de hoja hacia la raíz) para no perder el árbol, y después al proceso raíz.
/// Devuelve cuántos procesos señaló, o -1 si no pudo enumerar.
int p4w_terminate_tree(pid_t pid, int signal);

#endif
