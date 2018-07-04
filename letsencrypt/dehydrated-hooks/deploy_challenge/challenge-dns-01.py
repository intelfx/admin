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

import linode_api4 as L
import dns.resolver


def wait(*, name, type, target):
	delay = 1
	while True:
		try:
			for r in dns.resolver.query(name, 'TXT'):
				r = [ str(b, encoding='ascii') for b in r.strings ]
				if r != [target]:
					raise RuntimeError(f'Wrong record type {type} name {name} target {target} actual {r}')
				return
		except dns.resolver.NXDOMAIN as e:
			pass

		logging.info(f'will wait for {delay} seconds for record type {type} name {name} target {target} to appear')
		time.sleep(delay)
		delay = min(60, delay*2)


def deploy(*, domain, name, type, target):
	logging.info(f'will create record type {type} name {name} target {target}')
	domain.record_create(record_type=type, name=name, target=target, ttl_sec=60)
	wait(name=name, type=type, target=target)


def clean(*, domain, name, type, target):
	# Read existing records
	found = False
	for r in domain.records:
		if (r.type == type and
		    f'{r.name}.{config.domain}' == name and
		    r.target == target):
			logging.info(f'will delete record id {r.id} type {r.type} name {r.name} target {r.target}')
			r.delete()
			found = True
	if not found:
		raise RuntimeError(f'Failed to find record type {type} name {name} target {target}')

actions = {
	'deploy_challenge': deploy,
	'clean_challenge': clean,
}


lib.configure_logging(prefix='DNS-01: ')

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=actions.keys())
parser.add_argument('domain')
parser.add_argument('challenge_token')
parser.add_argument('dns_token')
args = parser.parse_args()

lib.configure_logging(prefix=f'DNS-01: {args.domain}: ')

#
# DNS: linode.com
#

config = yaml.load(open('letsencrypt.yaml'))
config = lib.attrdict(config)
config = config.linode

#
# Sanity-check requested domain vs config
#

def subdomain_of(subdomain, domain):
	return subdomain == domain or subdomain.endswith('.' + domain)

if not subdomain_of(args.domain, config.domain):
	raise RuntimeError(f'DNS-01: {args.domain}: config is for {config.domain}')


#
# Configure DNS resolver to query target nameservers directly
#

try:
	R = dns.resolver.Resolver(configure=False)
	R.nameservers = list({
		ai[4][0]
		for ns in config.nameservers
		for ai in socket.getaddrinfo(ns)
	})
	dns.resolver.default_resolver = R
except AttributeError:
	pass

linode = L.LinodeClient(config.token)
domains = linode.domains(L.Domain.domain == config.domain)
domains = list(domains)

if len(domains) != 1:
	raise RuntimeError(f'DNS-01: {args.domain}: Linode reports {len(domains)} domains matching {config.domain}')

actions[args.action](
	domain = domains[0],
	name=f'_acme-challenge.{args.domain}', # {config.domain} will be stripped by Linode
	target=args.dns_token,
	type='TXT'
)
