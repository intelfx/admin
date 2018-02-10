#!/usr/bin/env python3

#
# A helper script for the "server behind a NAT with forwarded ports" setup.
# Fetch external IP from the NAT box and update it in various places across the system.
#

import argparse
import re
import subprocess
import socket
import yaml
import json
import requests
import logging

import lib

regex_ipv4 = '(?P<address>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)'
regex_ipv4_mask = regex_ipv4 + '/(?P<netmask>[0-9]+)'
def check_ipv4(ipv4, *, netmask=False):
	if netmask:
		regex = regex_ipv4_mask
		msg = f'{ipv4} is not a valid IPv4+netmask'
	else:
		regex = regex_ipv4
		msg = f'{ipv4} is not a valid IPv4'

	match = re.fullmatch(regex, ipv4, re.ASCII)
	if match is None:
		raise ValueError(msg)
	return match


config = yaml.load(open('/etc/admin/update-ip.yaml'))
config = lib.attrdict(config)


external_ip = lib.run(
	[
		'ssh',
		'-o', f'IdentityFile={config.router.identity}',
		f'{config.router.host}',
		f':put [/ip address get [find interface={config.router.interface}] address]',
	],
	stdout=subprocess.PIPE,
)
external_ip = check_ipv4(external_ip.stdout.strip(), netmask=True).group('address')
logging.info(f'External IP: {external_ip}')

#
# DNS: pdd.yandex.ru
#

pdd = lib.Pdd(config.pdd)
resp = pdd.list()

# Remove up-to-date ones
config.pdd.records = set(config.pdd.records)
resp = filter(lambda r: r.record_id in config.pdd.records, resp)
for r in resp:
	if r.content == external_ip:
		logging.info(f'DNS: skipping record id {r.record_id} type {r.type} name {r.subdomain} -- up-to-date')
	else:
		logging.info(f'DNS: will update record id {r.record_id} type {r.type} name {r.subdomain} content {r.content} -> {external_ip}')
		pdd.edit(r.record_id, external_ip)

#
# Turnserver
#

turnserver_conf = open('/etc/turnserver.conf').read()
turnserver_conf_new = re.sub('(?<=\nexternal-ip=).+(?=\n)', external_ip, turnserver_conf)
if turnserver_conf != turnserver_conf_new:
	logging.info('turnserver: config updated, writing and restarting')
	open('/etc/turnserver.conf', 'w').write(turnserver_conf_new)
	lib.run(['systemctl', 'try-reload-or-restart', 'turnserver'])
