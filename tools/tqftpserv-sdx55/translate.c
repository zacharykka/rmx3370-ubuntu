// SPDX-License-Identifier: BSD-3-Clause
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "translate.h"

#define RW_BASE "/var/lib/tqftpserv"

static int mkdir_p(const char *dir)
{
	char tmp[PATH_MAX];
	char *p;
	snprintf(tmp, sizeof(tmp), "%s", dir);
	for (p = tmp + 1; *p; p++) {
		if (*p == /) {
			*p = \0;
			mkdir(tmp, 0755);
			*p = /;
		}
	}
	return mkdir(tmp, 0755);
}

static int open_ro_candidates(const char *rel)
{
	static const char * const prefixes[] = {
		"/lib/firmware/",
		"/lib/firmware/updates/qcom/sdx55m/",
		"/lib/firmware/updates/",
		"/var/lib/bitra/rfs/mdm/mpss/readonly/",
	};
	char path[PATH_MAX];
	for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
		snprintf(path, sizeof(path), "%s%s", prefixes[i], rel);
		int fd = open(path, O_RDONLY);
		if (fd >= 0) {
			fprintf(stderr, "[TQFTP-SDX55] RO hit: %s\n", path);
			return fd;
		}
	}
	fprintf(stderr, "[TQFTP-SDX55] RO miss: %s\n", rel);
	errno = ENOENT;
	return -1;
}

static int open_rw(const char *subdir, const char *rel, int flags)
{
	char full[PATH_MAX];
	char dup[PATH_MAX];
	snprintf(full, sizeof(full), "%s/%s/%s", RW_BASE, subdir, rel);
	snprintf(dup, sizeof(dup), "%s", full);
	mkdir_p(dirname(dup));
	int fd = open(full, flags, 0600);
	fprintf(stderr, "[TQFTP-SDX55] RW (%s) flags=0x%x fd=%d errno=%d\n", full, flags, fd, fd < 0 ? errno : 0);
	return fd;
}

int translate_open(const char *path, int flags)
{
	fprintf(stderr, "[TQFTP-SDX55] translate_open(%s, 0x%x)\n", path, flags);
	if (strstr(path, "..")) {
		errno = EACCES;
		return -1;
	}
	if (!strncmp(path, "/readonly/firmware/image/", 25))
		return open_ro_candidates(path + 25);
	if (!strncmp(path, "/readonly/firmware/", 19))
		return open_ro_candidates(path + 19);
	if (!strncmp(path, "/readonly/vendor/firmware_mnt/image/", 36))
		return open_ro_candidates(path + 36);
	if (!strncmp(path, "/readonly/vendor/firmware/", 26))
		return open_ro_candidates(path + 26);
	if (!strncmp(path, "/readonly/", 10))
		return open_ro_candidates(path + 10);
	if (!strncmp(path, "/readwrite/", 11))
		return open_rw("readwrite", path + 11, flags);
	if (!strncmp(path, "/shared/", 8))
		return open_rw("shared", path + 8, flags);
	if (!strncmp(path, "/hlos/", 6))
		return open_rw("hlos", path + 6, flags);
	/* Fallback: try readonly */
	while (*path == /) path++;
	return open_ro_candidates(path);
}
