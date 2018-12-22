#!/bin/bash

for disk in /dev/sd[a-z]; do
	sg_reset -vH "$disk" || true # sg_reset exits with 1 somewhy
done
