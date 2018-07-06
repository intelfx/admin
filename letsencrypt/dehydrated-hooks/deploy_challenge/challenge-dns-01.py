#!/usr/bin/env python3

import sys
import argparse
import logging
import yaml
import json
import requests
import socket
import time

import lib

import linode_api4
import dns.resolver


def wait(*, name, type, target):
	delay = 1
	while True:
		try:
			answers = {
				str(b, encoding='ascii')
				for r in dns.resolver.query(name, 'TXT')
				for b in r.strings
			}
			if answers == {target}:
				break
			logging.debug(f'wrong record type {type} name {name} target {target} actual {answers}')
		except dns.resolver.NXDOMAIN as e:
			logging.debug(f'NXDOMAIN looking for record type {type} name {name}')
			pass

		logging.info(f'will wait for {delay} seconds for record type {type} name {name} target {target} to appear')
		time.sleep(delay)
		delay = min(300, delay*2)

	logging.info(f'will wait another {delay} seconds')
	time.sleep(delay)


def find(zone, name, type, target=None):
	for r in zone.records:
		if (r.type == type and
		    f'{r.name}.{zone.domain}' == name and
		    target is None or r.target == target):
			yield r


def deploy(*, zone, name, type, target):
	for r in find(zone=zone, name=name, type=type):
		logging.info(f'will delete record id {r.id} type {r.type} name {r.name} target {r.target}')
		r.delete()

	logging.info(f'will create record type {type} name {name} target {target}')
	zone.record_create(record_type=type, name=name, target=target, ttl_sec=60)
	wait(name=name, type=type, target=target)


def clean(*, zone, name, type, target):
	# Read existing records
	found = False
	for r in find(zone=zone, name=name, type=type, target=target):
		logging.info(f'will delete record id {r.id} type {r.type} name {r.name} target {r.target}')
		r.delete()
		found = True
	if not found:
		logging.warn(f'could not find record type {type} name {name} target {target}')


#
# action map
#

actions = {
	'deploy_challenge': deploy,
	'clean_challenge': clean,
}


#
# main: parse arguments
#

lib.configure_logging(prefix='DNS-01: ')

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=actions.keys())
parser.add_argument('domain')
parser.add_argument('challenge_token')
parser.add_argument('dns_token')
args = parser.parse_args()

lib.configure_logging(prefix=f'DNS-01: {args.domain}: ')


#
# load config
#

config = yaml.load(open('letsencrypt.yaml'))
config = lib.attrdict(config)


#
# Configure DNS resolver to query target nameservers directly
#

try:
	R = dns.resolver.Resolver(configure=False)
	R.nameservers = list({
		ai[4][0]
		for ns in config.nameservers
		for ai in socket.getaddrinfo(ns, None)
	})
	dns.resolver.default_resolver = R
except AttributeError:
	logging.warn('using default resolver, adverse caching may occur')
	pass


#
# DNS: linode.com
#

def subdomain_of(subdomain, domain):
	return subdomain == domain or subdomain.endswith('.' + domain)

config = config.linode
linode = linode_api4.LinodeClient(config.token)
zones = [
	d
	for d
	in linode.domains()
	if subdomain_of(args.domain, d.domain)
]

if len(zones) != 1:
	raise RuntimeError(f'DNS-01: {args.domain}: found {len(zones)} matching zones')

actions[args.action](
	zone = zones[0],
	name=f'_acme-challenge.{args.domain}', # zone prefix will be stripped by Linode
	target=args.dns_token,
	type='TXT'
)
