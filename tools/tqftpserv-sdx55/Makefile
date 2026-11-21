CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
LDFLAGS ?= -lqrtr

all: tqftpserv-sdx55

tqftpserv-sdx55: tqftpserv.c translate.c
	$(CC) $(CFLAGS) -o $@ tqftpserv.c translate.c $(LDFLAGS)

clean:
	rm -f tqftpserv-sdx55
