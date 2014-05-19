#!/bin/bash

awk -F: '$3 == 0 { print $1, "is a superuser" }' /etc/passwd
