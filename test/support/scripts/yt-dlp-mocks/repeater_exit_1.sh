#!/bin/bash

# Echoes all arguments to stdout, then exits 1.
# Used to verify that echoed arguments do not leak into logs.
echo "$@"
exit 1
