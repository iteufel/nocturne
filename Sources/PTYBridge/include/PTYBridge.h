#pragma once
#include <sys/types.h>
pid_t nocturne_pty_spawn(int *master, const char *home, const char *user, unsigned short columns, unsigned short rows);
int nocturne_pty_resize(int master, unsigned short columns, unsigned short rows);
void nocturne_pty_terminate(pid_t pid);
