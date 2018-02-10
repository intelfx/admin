#!/usr/bin/env python3

import sys
import argparse
import logging
import yaml
import json
import requests

import lib


def deploy(*, name, type, content):
	logging.info(f'will create record type {type} name {name} content {content}')
	pdd.add(name=name, type=type, content=content, ttl='60')


def clean(*, name, type, content):
	# Read existing records
	records = pdd.list()
	for r in records:
		if (r.type == type and
		    r.fqdn == name and
		    r.content == content):
			id = r.record_id
			break
	else:
		raise RuntimeError(f'Failed to find record type {_type} name {_name} content {content}')

	logging.info(f'will delete record id {id} type {type} name {name} content {content}')
	pdd.delete(id=id)


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
# DNS: pdd.yandex.ru
#

config = yaml.load(open('letsencrypt.yaml'))
config = lib.attrdict(config)
pdd = lib.Pdd(config.pdd)

def subdomain_of(subdomain, domain):
	return subdomain == domain or subdomain.endswith('.' + domain)

if not subdomain_of(args.domain, pdd.domain):
	raise RuntimeError(f'DNS-01: {args.domain}: config is for {pdd.domain}')

actions[args.action](
	name=f'_acme-challenge.{args.domain}',
	content=args.dns_token,
	type='TXT'
)
