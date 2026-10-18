#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct NocturneTunnel NocturneTunnel;
// Constructors block for at most 20s. Invoke away from the UI thread.
// Each successful handle and returned string must be freed exactly once.
NocturneTunnel *nocturne_remote_host(const char *url, const uint8_t key[32], uint16_t workspace_port, char **error);
NocturneTunnel *nocturne_remote_client(const char *url, const char *endpoint_id, bool streaming, char **error);
char *nocturne_remote_id(const NocturneTunnel *handle);
uint16_t nocturne_remote_port(const NocturneTunnel *handle);
int32_t nocturne_remote_route(const NocturneTunnel *handle);
int32_t nocturne_remote_authorize(const NocturneTunnel *handle, uint16_t source_port, const char *device_id);
void nocturne_remote_revoke(const NocturneTunnel *handle, const char *device_id);
void nocturne_remote_stop(NocturneTunnel *handle);
void nocturne_remote_string_free(char *value);
