#!/bin/bash

awk -F: '$2 == ""  { print $1, "has no password" }' /etc/shadow
