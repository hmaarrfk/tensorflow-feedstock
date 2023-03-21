#!/bin/bash
exit 0

set -euxo pipefail

${CC} ${CFLAGS} ${LDFLAGS} -o test_c test_c.c -ltensorflow
./test_c
