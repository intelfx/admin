#!/bin/bash

for disk in /dev/sd[a-z]; do
	sg_reset -vH "$disk" &
done
wait
