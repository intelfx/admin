#!/bin/python3


#
# imports
#

import lib

import os
import sys
import socket
import subprocess
import csv
import re
import yaml
import traceback
from datetime import date, time, datetime, timedelta, timezone
from time import sleep
import dateutil
import logging
import itertools

import influxdb


#
# data types
#

class IPv4:
	def __init__(self, string, subnet_bits = None):
		match = re.fullmatch("(\d+)\.(\d+)\.(\d+)\.(\d+)(/(\d+))?", string)
		if not match:
			raise ValueError(f"wrong IPv4 address/subnet textual representation: {string}")

		self._as_octets = (int(match.group(1)),
				   int(match.group(2)),
				   int(match.group(3)),
				   int(match.group(4)))
		self._as_value = (self._as_octets[0] << 24 |
				  self._as_octets[1] << 16 |
				  self._as_octets[2] << 8 |
				  self._as_octets[3])
		if subnet_bits is not None:
			self._subnet_bits = subnet_bits
		elif match.group(6):
			self._subnet_bits = int(match.group(6))
		else:
			self._subnet_bits = 32
		self._subnet_mask = 0xFFFFFFFF - (1 << (32 - self._subnet_bits)) + 1

	def __hash__(self):
		return hash((self._as_value, self._subnet_bits))

	def __contains__(self, arg):
		if not isinstance(arg, IPv4):
			arg = IPv4(arg)

		return (arg._subnet_bits >= self._subnet_bits and
		        (arg._as_value & self._subnet_mask) == (self._as_value & self._subnet_mask))

	def __eq__(self, arg):
		if not isinstance(arg, IPv4):
			arg = IPv4(arg)

		return (arg._subnet_bits == self._subnet_bits and
		        arg._as_value == self._as_value)

	def __str__(self):
		octets = self._as_octets
		bits = self._subnet_bits
		if bits < 32:
			return f"{octets[0]}.{octets[1]}.{octets[2]}.{octets[3]}/{bits}"
		else:
			return f"{octets[0]}.{octets[1]}.{octets[2]}.{octets[3]}"

	def __repr__(self):
		return f"IPv4('{str(self)}')"

	def __format__(self, *args, **kwargs):
		return str(self).__format__(*args, **kwargs)


class Flow:
	def __init__(self, flow):
		self.time_start = datetime.strptime(flow["ts"], "%Y-%m-%d %H:%M:%S.%f").astimezone()
		self.time_end = datetime.strptime(flow["te"], "%Y-%m-%d %H:%M:%S.%f").astimezone()

		self.src_addr = IPv4(flow["sa"].strip())
		self.dst_addr = IPv4(flow["da"].strip())

		self.proto = int(flow["pr"].strip()) # left-aligned & csv reader does not skip trailing whitespace

		if self.proto == 6 or self.proto == 17:
			self.src_port = int(flow["sp"].strip())
			self.dst_port = int(flow["dp"].strip())
		else:
			# neither TCP nor UDP
			self.src_port = 0
			self.dst_port = 0

		self.traffic_to_dst = int(flow["ibyt"].strip())
		self.traffic_to_src = int(flow["obyt"].strip())

		self.reverse = False # whether "dst" opened connection to "src"

		self.src_rank = None
		self.dst_rank = None
		self.src_name = None
		self.dst_name = None
		self.src_port_name = None
		self.dst_port_name = None

		self.loglevel = logging.DEBUG

	def swap(self):
		(self.src_addr, self.dst_addr) = (self.dst_addr, self.src_addr)
		(self.src_port, self.dst_port) = (self.dst_port, self.src_port)
		(self.traffic_to_dst, self.traffic_to_src) = (self.traffic_to_src, self.traffic_to_dst)
		(self.src_rank, self.dst_rank) = (self.dst_rank, self.src_rank)
		(self.src_name, self.dst_name) = (self.dst_name, self.src_name)
		(self.src_port_name, self.dst_port_name) = (self.dst_port_name, self.src_port_name)
		self.reverse = not self.reverse

	def set_loglevel(self, loglevel):
		self.loglevel = max(self.loglevel, loglevel)


#
# helper functions
#

# HACK to combat strange transient problems
def getnameinfo_repeated(sockaddr, *args, **kwargs):
	addr = sockaddr[0]
	port = sockaddr[1]

	max_tries = 10
	tries = 0
	while True:
		tries += 1
		try:
			ret = socket.getnameinfo(sockaddr, *args, **kwargs)
			return ret
		except OSError as e:
			l.warning(f"({tries}/{max_tries}) failed to resolve {addr}:{port} with {e}")
			if tries >= max_tries:
				raise
			sleep(1)
			continue


# HACK to combat strange transient problems
def getaddrinfo_repeated(host, port, *args, **kwargs):
	max_tries = 10
	tries = 0
	while True:
		tries += 1
		try:
			ret = socket.getaddrinfo(host, port, *args, **kwargs)
			return ret
		except OSError as e:
			l.warning(f"({tries}/{max_tries}) failed to resolve {host}:{port} with {e}")
			if tries >= max_tries:
				raise
			sleep(1)
			continue


def load_aux_addresses(cfg):
	# we fetch aux addresses via a DNS query for an artificial domain name
	fqdn = cfg.query_fqdn
	l.info(f"loading aux addresses via nameserver query for {fqdn}")

	# HACK to combat strange transient problems
	addrs = getaddrinfo_repeated(fqdn, None, family = socket.AF_INET)
	addrs = set([ a[4][0]
	              for a
	              in addrs])

	# we assign those addresses to another domain name
	fqdn = cfg.mapping_fqdn

	return { IPv4(a): fqdn
	         for a
	         in addrs }


def nfdump(infile):
	nfdump_fields = ["ts", "te", "sa", "sp", "da", "dp", "pr", "ibyt", "obyt"]
	nfdump_fmt = "fmt:" + ",".join([ "%"+f for f in nfdump_fields ])
	nfdump = [ "nfdump", "-r", infile, "-o", nfdump_fmt, "-q", "-b", "-N" ]

	l.info(f"launching {nfdump} to parse")
	nfdump = subprocess.Popen(nfdump,
	                          stdin = subprocess.DEVNULL,
	                          stdout = subprocess.PIPE,
			          universal_newlines = True)

	nfdump = csv.DictReader(nfdump.stdout, fieldnames = nfdump_fields,
	                        skipinitialspace = True)

	nfdump = map(lambda x: lib.attrconvert(x), nfdump)

	return nfdump


def resolve_name_and_port(flow, addr, port, rank, flags = 0):
	if addr in cfg.aux:
		r_addr = cfg.aux[addr]

		# TODO find a way to disable hostname resolution in getnameinfo (akin to passing NULL to host)
		# until then, disable name resolution effectively
		flags &= ~socket.NI_NAMEREQD
		flags | socket.NI_NUMERICHOST
		_, r_port = socket.getnameinfo(('127.0.0.1', port), flags)
	else:
		addr = str(addr)

		# local names must be resolvable
		if rank > 0:
			flags |= socket.NI_NAMEREQD
			flags &= ~socket.NI_NUMERICHOST

		# HACK to combat strange transient problems
		r_addr, r_port = getnameinfo_repeated((addr, port), flags)

	if (flags & socket.NI_NAMEREQD) and r_addr == str(addr):
		flow.set_loglevel(logging.WARNING)
		l.warning(f"non-resolution detected: {r_addr}")

	if r_addr.find('.') == -1:
		flow.set_loglevel(logging.WARNING)
		l.warning(f"rejecting non-FQDN resolution {addr} -> {r_addr}")
		r_addr = str(addr)

	return r_addr, r_port


def local_rank(ipv4):
	if ipv4 in cfg.subnet:
		return 2
	if ipv4 in cfg.aux:
		return 1
	for s in cfg.subnets_addn:
		if ipv4 in s:
			return 0.5
	return 0


def process(flow):
	# resolve
	flow.src_rank = local_rank(flow.src_addr)
	flow.dst_rank = local_rank(flow.dst_addr)

	# always have local address as source
	if flow.dst_rank > flow.src_rank:
		flow.swap()

	if flow.src_rank == 0:
		flow.set_loglevel(logging.WARNING)
		l.warning(f"source address with rank 0: {flow.src_addr}")

	dst_flags = 0
	if flow.src_addr in cfg.numeric_dst_hosts:
		dst_flags |= socket.NI_NUMERICHOST

	flow.src_name, flow.src_port_name = resolve_name_and_port(flow, flow.src_addr, flow.src_port, flow.src_rank, 0)
	flow.dst_name, flow.dst_port_name = resolve_name_and_port(flow, flow.dst_addr, flow.dst_port, flow.dst_rank, dst_flags)

	# try to guess if "dst" opened connection to "src" (port number heuristic)
	if flow.src_port < 1024 and flow.dst_port > 1024:
		flow.reverse = True

	# try to guess if "dst" opened connection to "src" (port naming heuristic)
	if flow.dst_port_name == str(flow.dst_port) and flow.src_port_name != str(flow.src_port):
		flow.reverse = True

	return flow


def filter_negative(flow):
	# Filter IPsec ESP tunnel mode streams
	if ((flow.src_port == 4500 and flow.dst_port == 4500) or
	    (flow.proto == 50) or (flow.proto == 51)):
		return True
	return False


def log_flow(logger, flow, *args, **kwargs):
	if not logger.isEnabledFor(flow.loglevel):
		return

	if flow.reverse:
		direction = "<<->"
	else:
		direction = "<->>"

	if flow.src_name is None:
		flow.src_name = str(flow.src_addr)
	if flow.dst_name is None:
		flow.dst_name = str(flow.dst_addr)
	if flow.src_port_name is None:
		flow.src_port_name = str(flow.src_port)
	if flow.dst_port_name is None:
		flow.dst_port_name = str(flow.dst_port)

	logger.log(flow.loglevel, f"flow @ {flow.time_start:%Y-%m-%d %H:%M:%S.%f} - {flow.time_end:%Y-%m-%d %H:%M:%S.%f}: src {flow.src_name:>30.30}:{flow.src_port_name:<10.10} {direction} dst {flow.dst_name:>30.30}:{flow.dst_port_name:<10.10}, traffic {flow.traffic_to_src} s{direction}d {flow.traffic_to_dst} bytes", *args, **kwargs)


def hack_wiggle_time(flow, unique):
	flow.time_end += timedelta(microseconds = unique)


def make_influx(flow):
	out = {
		"measurement": cfg.measurement,
		"tags": {
			"src_addr": flow.src_name,
			"dst_addr": flow.dst_name,
			"inbound": flow.reverse,
			"target_port": flow.dst_port if not flow.reverse else flow.src_port,
		},
		"fields": {
			"bytes_in": flow.traffic_to_src,
			"bytes_out": flow.traffic_to_dst,
			"ephemeral_port": flow.src_port if not flow.reverse else flow.dst_port,
			"proto": flow.proto,
		},
		"time": flow.time_end
	}

	return out


#
# main
#

def excepthook(exctype, value, traceback):
	l.error(f"Uncaught exception of type {exctype}: {value}", exc_info = value)
	sys.__excepthook__(exctype, value, traceback)
sys.excepthook = excepthook

sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering = 1)
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering = 1)

l = logging.getLogger()

parser = argparse.ArgumentParser()
parser.add_argument("file")
args = parser.parse_args()

l.info(f"input: {args.file}")
file_dir = os.path.dirname(args.file)
cfg = os.path.join(file_dir, "config.yaml")

l.info(f"loading config at {cfg}")
cfg = lib.attrconvert(yaml.load(open(cfg)))

l.info(f"measurement: {cfg.measurement}")
cfg.subnet = IPv4(cfg.subnet)
l.info(f"local subnet: {cfg.subnet}")
l.info(f"unresolved local aux mappings: {cfg.aux}")
cfg.subnets_addn = [ IPv4(s) for s in cfg.get("subnets_addn", []) ]
l.info(f"additional local subnets: {cfg.subnets_addn}")
cfg.numeric_dst_hosts = [ IPv4(s) for s in cfg.get("numeric_dst_hosts", []) ]
l.info(f"not resolving dst-address for hosts: {cfg.numeric_dst_hosts}")
l.info(f"influxdb instance from {cfg.influx.uri}")
l.info(f"influxdb raw data RP: {cfg.influx.rp_raw}")
l.info(f"influxdb aggregated data RPs: {[ x.rp for x in cfg.influx.aggregations ]}")

if os.isatty(sys.stderr.fileno()):
	cfg_highlight_on = lib.run(["tput", "bold"], stdout=subprocess.PIPE).stdout
	cfg_highlight_off = lib.run(["tput", "sgr0"], stdout=subprocess.PIPE).stdout
else:
	cfg_highlight_on = ""
	cfg_highlight_off = ""

if "verbose" in cfg:
	if cfg.verbose:
		l.setLevel(logging.DEBUG)
else:
	if os.isatty(sys.stderr.fileno()):
		l.setLevel(logging.DEBUG)

# Up to this point, we did not perform any meaningful things.
# Check if we actually have any flows to report.

l.info(f"parsing {args.file} via nfdump as csv output")
flows = nfdump(args.file)
flows_out = []

# this is how to "peek" an entry from an iterator
# we could just collect that into a list and check its length, but...
try:
	flow_first = next(flows)
	# some versions of nfdump print "No matched flows" instead of printing nothing
	if flow_first.ts == "No matched flows":
		raise StopIteration
	flows = itertools.chain([ flow_first ], flows)
except StopIteration:
	l.info("no input flows -- quitting early")
	os.unlink(input)
	sys.exit(0)

# Otherwise, continue connecting to external services and do meaningful work.

cfg.aux = load_aux_addresses(cfg.aux)
l.info(f"local aux mappings: {cfg.aux}")

influx = influxdb.InfluxDBClient.from_dsn(cfg.influx.uri)
l.info(f"InfluxDB client object: {influx}")

warned_flows = 0
failed_flows = 0
total_flows = 0
filtered_flows = 0
for flow in flows:
	try:
		total_flows += 1

		# parse
		flow = Flow(flow)

		# resolve
		flow = process(flow)

		# filter
		if filter_negative(flow):
			filtered_flows += 1

			# log
			log_flow(l, flow)
			l.log(flow.loglevel, f"flow filtered")
		else:
			# XXX: hack to make timestamps unique
			hack_wiggle_time(flow, len(flows_out))

			# generate output
			flows_out += [ make_influx(flow) ]

			# log
			log_flow(l, flow)

	except Exception as e:
		flow.set_loglevel(logging.ERROR)

		# log
		log_flow(l, flow)
		l.log(flow.loglevel, f"failed to process flow: {e}", exc_info = e)

	if flow.loglevel >= logging.ERROR:
		failed_flows += 1
	elif flow.loglevel >= logging.WARNING:
		warned_flows += 1

l.info(f"Raw total flows: {total_flows}")
l.info(f"Raw written flows: {len(flows_out)}")
if warned_flows > 0:
	l.warning(f"Raw warned flows: {warned_flows}")
if failed_flows > 0:
	l.error(f"Raw failed flows: {failed_flows}")

if len(flows_out) == 0:
	l.info("no processed flows after filtering -- quitting early")
	os.unlink(input)
	sys.exit(0)

# sort by time
flows_out.sort(key = lambda f: f.time)
flow_ts_min = flows_out[0].time
flow_ts_max = flows_out[-1].time
l.info(f"Raw time range: from {flow_ts_min} to {flow_ts_max}")

# write raw points
influx.write_points(flows_out, retention_policy = cfg.influx.rp_raw, time_precision = 'u')

# XXX: CQs are not featureful enough to do what we want (they cannot be delayed or re-run on historical intervals if data is inserted with delays or out of order),
#      so we perform aggregation by hand
for agg in cfg.influx.aggregations:
	l.info(f"Aggregation {agg.rp}: interval {agg.group_by_time}, keys {agg.group_by_keys}, fields {agg.new_fields}")

	if agg.group_by_time != "1m":
		raise NotImplementedError(f"Aggregation {agg.rp}: unsupported grouping interval of {agg.group_by_time}")

	# calculate boundaries for the aggregating query
	agg_ts_min = flow_ts_min.replace(second = 0, microsecond = 0)
	agg_ts_max = (flow_ts_max + timedelta(minutes = 1)).replace(second = 0, microsecond = 0)
	l.info(f"Aggregation {agg.rp}: updating from {agg_ts_min} to {agg_ts_max}")

	# construct the aggregating query
	agg_query = f"""
	SELECT sum("bytes_in") as "bytes_in", sum("bytes_out") as "bytes_out", {agg.new_fields}
	INTO "{agg.rp}"."{cfg.measurement}"
	FROM "{cfg.influx.rp_raw}"."{cfg.measurement}"
	WHERE time >= '{agg_ts_min.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}' and
	      time < '{agg_ts_max.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}'
	GROUP BY time({agg.group_by_time}), {agg.group_by_keys}
	"""

	influx.query(query = agg_query)

	l.info(f"Aggregation {agg.rp}: done")

if failed_flows > 0:
	sys.exit(1)

os.unlink(input)
