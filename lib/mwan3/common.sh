#!/bin/sh

IP4="ip -4"
IP6="ip -6"
SCRIPTNAME="$(basename "$0")"

MWAN3_STATUS_DIR="/var/run/mwan3"
MWAN3_STATUS_IPTABLES_LOG_DIR="${MWAN3_STATUS_DIR}/iptables_log"
MWAN3TRACK_STATUS_DIR="/var/run/mwan3track"

MWAN3_INTERFACE_MAX=""

MMX_MASK=""
MMX_DEFAULT=""
MMX_BLACKHOLE=""
MM_BLACKHOLE=""

MMX_UNREACHABLE=""
MM_UNREACHABLE=""
MAX_SLEEP=$(((1<<31)-1))

command -v ip6tables > /dev/null
NO_IPV6=$?

NFT="nft"
# IPT4 replaced by nft functions
# IPT6 replaced by nft functions
# IPT4R replaced by nft functions
# IPT6R replaced by nft functions

LOG()
{
	local facility=$1; shift
	# in development, we want to show 'debug' level logs
	# when this release is out of beta, the comment in the line below
	# should be removed
	[ "$facility" = "debug" ] && return
	logger -t "${SCRIPTNAME}[$$]" -p $facility "$*"
}

mwan3_get_true_iface()
{
	local family V
	_true_iface=$2
	config_get family "$2" family ipv4
	if [ "$family" = "ipv4" ]; then
		V=4
	elif [ "$family" = "ipv6" ]; then
		V=6
	fi
	ubus call "network.interface.${2}_${V}" status &>/dev/null && _true_iface="${2}_${V}"
	export "$1=$_true_iface"
}

mwan3_get_src_ip()
{
	local family _src_ip interface true_iface device addr_cmd default_ip IP sed_str
	interface=$2
	mwan3_get_true_iface true_iface $interface

	unset "$1"
	config_get family "$interface" family ipv4
	if [ "$family" = "ipv4" ]; then
		addr_cmd='network_get_ipaddr'
		default_ip="0.0.0.0"
		sed_str='s/ *inet \([^ \/]*\).*/\1/;T;p;q'
		IP="$IP4"
	elif [ "$family" = "ipv6" ]; then
		addr_cmd='network_get_ipaddr6'
		default_ip="::"
		sed_str='s/ *inet6 \([^ \/]*\).* scope.*/\1/;T;p;q'
		IP="$IP6"
	fi

	$addr_cmd _src_ip "$true_iface"
	if [ -z "$_src_ip" ]; then
		if [ "$family" = "ipv6" ]; then
			# on IPv6-PD interfaces (like PPPoE interfaces) we don't
			# have a real address, just a prefix, that can be delegated
			# to interfaces, because using :: (the fallback above) or
			# the local address (fe80:... which will be returned from
			# the sed_str expression defined above) will not work
			# (reliably, if at all) try to find an address which we can
			# use instead
			network_get_prefix6 _src_ip "$true_iface"
			if [ -n "$_src_ip" ]; then
				# got a prefix like 2001:xxxx:yyyy::/48, clean it up to
				# only contain the prefix -> 2001:xxxx:yyyy
				_src_ip=$(echo "$_src_ip" | sed -e 's;:*/.*$;;')
				# find an interface with a delegated address, and use
				# it, this would be sth like 2001:xxxx:yyyy:zzzz:...
				# we just select the first address that matches the prefix
				# NOTE: is there a better/more reliable way to get a
				#       usable address to use as source for pings here?
				local pfx_sed
				pfx_sed='s/ *inet6 \('"$_src_ip"':[0-6a-f:]\+\).* scope.*/\1/'
				_src_ip=$($IP address ls | sed -ne "${pfx_sed};T;p;q")
			fi
		fi
		if [ -z "$_src_ip" ]; then
			network_get_device device $true_iface
			_src_ip=$($IP address ls dev $device 2>/dev/null | sed -ne "$sed_str")
		fi
		if [ -n "$_src_ip" ]; then
			LOG warn "no src $family address found from netifd for interface '$true_iface' dev '$device' guessing $_src_ip"
		else
			_src_ip="$default_ip"
			LOG warn "no src $family address found for interface '$true_iface' dev '$device'"
		fi
	fi
	export "$1=$_src_ip"
}

readfile() {
	[ -f "$2" ] || return 1
	# read returns 1 on EOF
	read -d'\0' $1 <"$2" || :
}

mwan3_get_mwan3track_status()
{
	local interface=$2
	local track_ips pid cmdline started
	mwan3_list_track_ips()
	{
		track_ips="$1 $track_ips"
	}
	config_list_foreach "$interface" track_ip mwan3_list_track_ips

	if [ -z "$track_ips" ]; then
		export -n "$1=disabled"
		return
	fi
	readfile pid $MWAN3TRACK_STATUS_DIR/$interface/PID 2>/dev/null
	if [ -z "$pid" ]; then
		export -n "$1=down"
		return
	fi
	readfile cmdline /proc/$pid/cmdline 2>/dev/null
	if [ $cmdline != "/bin/sh/usr/sbin/mwan3track${interface}" ]; then
		export -n "$1=down"
		return
	fi
	readfile started $MWAN3TRACK_STATUS_DIR/$interface/STARTED
	case "$started" in
		0)
			export -n "$1=paused"
			;;
		1)
			export -n "$1=active"
			;;
		*)
			export -n "$1=down"
			;;
	esac
}

mwan3_init()
{
	local bitcnt mmdefault source_routing

	config_load mwan3

	[ -d $MWAN3_STATUS_DIR ] || mkdir -p $MWAN3_STATUS_DIR/iface_state
	[ -d "$MWAN3_STATUS_IPTABLES_LOG_DIR" ] || mkdir -p "$MWAN3_STATUS_IPTABLES_LOG_DIR"

	# mwan3's MARKing mask (at least 3 bits should be set)
	if [ -e "${MWAN3_STATUS_DIR}/mmx_mask" ]; then
		readfile MMX_MASK "${MWAN3_STATUS_DIR}/mmx_mask"
		MWAN3_INTERFACE_MAX=$(uci_get_state mwan3 globals iface_max)
	else
		config_get MMX_MASK globals mmx_mask '0x3F00'
		echo "$MMX_MASK"| tr 'A-F' 'a-f' > "${MWAN3_STATUS_DIR}/mmx_mask"
		LOG debug "Using firewall mask ${MMX_MASK}"

		bitcnt=$(mwan3_count_one_bits MMX_MASK)
		mmdefault=$(((1<<bitcnt)-1))
		MWAN3_INTERFACE_MAX=$((mmdefault-3))
		uci_toggle_state mwan3 globals iface_max "$MWAN3_INTERFACE_MAX"
		LOG debug "Max interface count is ${MWAN3_INTERFACE_MAX}"
	fi

	# remove "linkdown", expiry and source based routing modifiers from route lines
	config_get_bool source_routing globals source_routing 0
	[ $source_routing -eq 1 ] && unset source_routing
	MWAN3_ROUTE_LINE_EXP="s/offload//; s/linkdown //; s/expires [0-9]\+sec//; s/error [0-9]\+//; ${source_routing:+s/default\(.*\) from [^ ]*/default\1/;} p"

	# mark mask constants
	bitcnt=$(mwan3_count_one_bits MMX_MASK)
	mmdefault=$(((1<<bitcnt)-1))
	MM_BLACKHOLE=$((mmdefault-2))
	MM_UNREACHABLE=$((mmdefault-1))

	# MMX_DEFAULT should equal MMX_MASK
	MMX_DEFAULT=$(mwan3_id2mask mmdefault MMX_MASK)
	MMX_BLACKHOLE=$(mwan3_id2mask MM_BLACKHOLE MMX_MASK)
	MMX_UNREACHABLE=$(mwan3_id2mask MM_UNREACHABLE MMX_MASK)
}

# maps the 1st parameter so it only uses the bits allowed by the bitmask (2nd parameter)
# which means spreading the bits of the 1st parameter to only use the bits that are set to 1 in the 2nd parameter
# 0 0 0 0 0 1 0 1 (0x05) 1st parameter
# 1 0 1 0 1 0 1 0 (0xAA) 2nd parameter
#     1   0   1          result
mwan3_id2mask()
{
	local bit_msk bit_val result
	bit_val=0
	result=0
	for bit_msk in $(seq 0 31); do
		if [ $((($2>>bit_msk)&1)) = "1" ]; then
			if [ $((($1>>bit_val)&1)) = "1" ]; then
				result=$((result|(1<<bit_msk)))
			fi
			bit_val=$((bit_val+1))
		fi
	done
	printf "0x%x" $result
}

# counts how many bits are set to 1
# n&(n-1) clears the lowest bit set to 1
mwan3_count_one_bits()
{
	local count n
	count=0
	n=$(($1))
	while [ "$n" -gt "0" ]; do
		n=$((n&(n-1)))
		count=$((count+1))
	done
	echo $count
}

get_uptime() {
	local _tmp
	readfile _tmp /proc/uptime
	if [ $# -eq 0 ]; then
		echo "${_tmp%%.*}"
	else
		export -n "$1=${_tmp%%.*}"
	fi
}

get_online_time() {
	local time_n time_u iface
	iface="$2"
	readfile time_u "$MWAN3TRACK_STATUS_DIR/${iface}/ONLINE" 2>/dev/null
	[ -z "${time_u}" ] || [ "${time_u}" = "0" ] || {
		get_uptime time_n
		export -n "$1=$((time_n-time_u))"
	}
}

# ============================================================
# NFTables wrapper functions (replaces iptables/ipset calls)
# ============================================================

NFT="nft"
MWAN3_NFT_TABLE="inet mwan3"
MWAN3_NFT_LOG_DIR="${MWAN3_STATUS_DIR}/nft_log"

# 初始化 mwan3 nft table
nft_init_table()
{
	$NFT add table inet mwan3 2>/dev/null
	$NFT add chain inet mwan3 prerouting '{ type filter hook prerouting priority mangle; policy accept; }' 2>/dev/null
	$NFT add chain inet mwan3 output '{ type route hook output priority mangle; policy accept; }' 2>/dev/null
	$NFT add chain inet mwan3 mwan3_rules 2>/dev/null
	mkdir -p "$MWAN3_NFT_LOG_DIR"
}

# 删除 mwan3 nft table
nft_flush_table()
{
	$NFT delete table inet mwan3 2>/dev/null
}

# 创建 nft set（替代 ipset create）
# 用法: nft_set_create <setname> [ipv6]
nft_set_create()
{
	local setname="$1"
	local family="${2:-ipv4}"
	if [ "$family" = "ipv6" ]; then
		$NFT add set inet mwan3 "$setname" '{ type ipv6_addr; flags interval; }' 2>/dev/null
	else
		$NFT add set inet mwan3 "$setname" '{ type ipv4_addr; flags interval; }' 2>/dev/null
	fi
}

# 清空 nft set（替代 ipset flush）
nft_set_flush()
{
	$NFT flush set inet mwan3 "$1" 2>/dev/null
}

# 向 nft set 添加元素（替代 ipset add）
nft_set_add()
{
	$NFT add element inet mwan3 "$1" "{ $2 }" 2>/dev/null
}

# 批量恢复 nft 规则（替代 iptables-restore）
nft_restore()
{
	$NFT -f - 2>&1
}

# 添加 mwan3 mark 规则到指定 chain
# 用法: nft_mark_rule <chain> <match> <mark> <mask>
nft_mark_rule()
{
	local chain="$1" match="$2" mark="$3" mask="$4"
	$NFT add rule inet mwan3 "$chain" $match meta mark set "meta mark & ~${mask} | ${mark}"
}

# 添加 policy chain 跳转规则
nft_policy_rule()
{
	local chain="$1" policy_chain="$2" match="$3"
	$NFT add rule inet mwan3 "$chain" $match jump "$policy_chain"
}

# 检查 chain 是否存在
nft_chain_exists()
{
	$NFT list chain inet mwan3 "$1" >/dev/null 2>&1
}

# 创建 policy chain
nft_create_chain()
{
	$NFT add chain inet mwan3 "$1" 2>/dev/null
}

# 删除 chain
nft_delete_chain()
{
	$NFT flush chain inet mwan3 "$1" 2>/dev/null
	$NFT delete chain inet mwan3 "$1" 2>/dev/null
}

# 列出 chain 规则（替代 iptables -S）
nft_list_chain()
{
	$NFT list chain inet mwan3 "$1" 2>/dev/null
}

# 统计 chain 规则（替代 iptables -L -v）
nft_list_rules()
{
	$NFT list chain inet mwan3 "$1" 2>/dev/null
}
