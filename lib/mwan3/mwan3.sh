#!/bin/sh

. "${IPKG_INSTROOT}/usr/share/libubox/jshn.sh"
. "${IPKG_INSTROOT}/lib/mwan3/common.sh"

CONNTRACK_FILE="/proc/net/nf_conntrack"
IPv6_REGEX="([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,7}:|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|"
IPv6_REGEX="${IPv6_REGEX}[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|"
IPv6_REGEX="${IPv6_REGEX}:((:[0-9a-fA-F]{1,4}){1,7}|:)|"
IPv6_REGEX="${IPv6_REGEX}fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|"
IPv6_REGEX="${IPv6_REGEX}::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"
IPv4_REGEX="((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"

DEFAULT_LOWEST_METRIC=256

mwan3_push_update()
{
	# legacy stub - no longer used, kept for compatibility
	:
}

mwan3_report_policies_nft()
{
	local policy="$1"
	nft list chain inet mwan3 "$policy" 2>/dev/null | grep comment | 		awk '{for(i=1;i<=NF;i++) if($i=="comment") print $(i+1), $(i+2), $(i+3)}'
}

mwan3_update_dev_to_table()
{
	local _tid
	# shellcheck disable=SC2034
	mwan3_dev_tbl_ipv4=" "
	# shellcheck disable=SC2034
	mwan3_dev_tbl_ipv6=" "

	update_table()
	{
		local family curr_table device enabled
		let _tid++
		config_get family "$1" family ipv4
		network_get_device device "$1"
		[ -z "$device" ] && return
		config_get_bool enabled "$1" enabled
		[ "$enabled" -eq 0 ] && return
		curr_table=$(eval "echo	 \"\$mwan3_dev_tbl_${family}\"")
		export "mwan3_dev_tbl_$family=${curr_table}${device}=$_tid "
	}
	network_flush_cache
	config_foreach update_table interface
}

mwan3_update_iface_to_table()
{
	local _tid
	mwan3_iface_tbl=" "
	update_table()
	{
		let _tid++
		export mwan3_iface_tbl="${mwan3_iface_tbl}${1}=$_tid "
	}
	config_foreach update_table interface
}

mwan3_route_line_dev()
{
	# must have mwan3 config already loaded
	# arg 1 is route device
	local _tid route_line route_device route_family entry curr_table
	route_line=$2
	route_family=$3
	route_device=$(echo "$route_line" | sed -ne "s/.*dev \([^ ]*\).*/\1/p")
	unset "$1"
	[ -z "$route_device" ] && return

	curr_table=$(eval "echo \"\$mwan3_dev_tbl_${route_family}\"")
	for entry in $curr_table; do
		if [ "${entry%%=*}" = "$route_device" ]; then
			_tid=${entry##*=}
			export "$1=$_tid"
			return
		fi
	done
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

mwan3_get_iface_id()
{
	local _tmp
	[ -z "$mwan3_iface_tbl" ] && mwan3_update_iface_to_table
	_tmp="${mwan3_iface_tbl##* ${2}=}"
	_tmp=${_tmp%% *}
	export "$1=$_tmp"
}

mwan3_set_custom_ipset_v4()
{
	local custom_network_v4
	for custom_network_v4 in $($IP4 route list table "$1" | awk '{print $1}' | grep -E "$IPv4_REGEX"); do
		LOG notice "Adding network $custom_network_v4 from table $1 to mwan3_custom_v4 nft set"
		nft_set_add mwan3_custom_ipv4 "$custom_network_v4"
	done
}

mwan3_set_custom_ipset_v6()
{
	local custom_network_v6
	for custom_network_v6 in $($IP6 route list table "$1" | awk '{print $1}' | grep -E "$IPv6_REGEX"); do
		LOG notice "Adding network $custom_network_v6 from table $1 to mwan3_custom_v6 nft set"
		nft_set_add mwan3_custom_ipv6 "$custom_network_v6"
	done
}

mwan3_set_custom_ipset()
{
	nft_set_create mwan3_custom_ipv4
	nft_set_flush mwan3_custom_ipv4
	config_list_foreach "globals" "rt_table_lookup" mwan3_set_custom_ipset_v4
	if [ $NO_IPV6 -eq 0 ]; then
		nft_set_create mwan3_custom_ipv6 ipv6
		nft_set_flush mwan3_custom_ipv6
		config_list_foreach "globals" "rt_table_lookup" mwan3_set_custom_ipset_v6
	fi
}


mwan3_set_connected_ipv4()
{
	local connected_network_v4
	local candidate_list cidr_list

	nft_set_create mwan3_connected_ipv4
	nft_set_flush mwan3_connected_ipv4

	candidate_list=""
	cidr_list=""
	route_lists()
	{
		$IP4 route | awk '{print $1}'
		$IP4 route list table 0 | awk '{print $2}'
	}
	for connected_network_v4 in $(route_lists | grep -E "$IPv4_REGEX"); do
		if [ -z "${connected_network_v4##*/*}" ]; then
			cidr_list="$cidr_list $connected_network_v4"
		else
			candidate_list="$candidate_list $connected_network_v4"
		fi
	done
	for connected_network_v4 in $cidr_list $candidate_list; do
		nft_set_add mwan3_connected_ipv4 "$connected_network_v4"
	done
	nft_set_add mwan3_connected_ipv4 "224.0.0.0/3"
}

mwan3_set_connected_ipv6()
{
	local connected_network_v6
	[ $NO_IPV6 -eq 0 ] || return

	nft_set_create mwan3_connected_ipv6 ipv6
	nft_set_flush mwan3_connected_ipv6

	for connected_network_v6 in $($IP6 route | awk '{print $1}' | grep -E "$IPv6_REGEX"); do
		[ -z "${connected_network_v6##*/*}" ] && nft_set_add mwan3_connected_ipv6 "$connected_network_v6"
	done
}

mwan3_set_connected_ipset()
{
	nft_set_create mwan3_connected_ipv4
	nft_set_flush mwan3_connected_ipv4
	if [ $NO_IPV6 -eq 0 ]; then
		nft_set_create mwan3_connected_ipv6 ipv6
		nft_set_flush mwan3_connected_ipv6
	fi
}

mwan3_set_dynamic_ipset()
{
	nft_set_create mwan3_dynamic_ipv4
	nft_set_flush mwan3_dynamic_ipv4
	if [ $NO_IPV6 -eq 0 ]; then
		nft_set_create mwan3_dynamic_ipv6 ipv6
		nft_set_flush mwan3_dynamic_ipv6
	fi
}

mwan3_set_general_rules()
{
	local IP

	for IP in "$IP4" "$IP6"; do
		[ "$IP" = "$IP6" ] && [ $NO_IPV6 -ne 0 ] && continue
		RULE_NO=$((MM_BLACKHOLE+2000))
		if [ -z "$($IP rule list | awk -v var="$RULE_NO:" '$1 == var')" ]; then
			$IP rule add pref $RULE_NO fwmark $MMX_BLACKHOLE/$MMX_MASK blackhole
		fi

		RULE_NO=$((MM_UNREACHABLE+2000))
		if [ -z "$($IP rule list | awk -v var="$RULE_NO:" '$1 == var')" ]; then
			$IP rule add pref $RULE_NO fwmark $MMX_UNREACHABLE/$MMX_MASK unreachable
		fi
	done
}

mwan3_set_general_iptables()
{
	local family error

	nft_init_table

	for family in ipv4 ipv6; do
		[ "$family" = "ipv6" ] && [ $NO_IPV6 -ne 0 ] && continue

		nft_create_chain mwan3_ifaces_in
		nft_create_chain mwan3_rules

		for chain in custom connected dynamic; do
			nft_create_chain mwan3_${chain}_${family}
			nft add rule inet mwan3 mwan3_${chain}_${family} 				ip daddr @mwan3_${chain}_${family} 				meta mark set "meta mark & ~${MMX_MASK} | ${MMX_DEFAULT}" 2>/dev/null
		done

		nft_create_chain mwan3_hook

		if [ "$family" = "ipv6" ]; then
			nft add rule inet mwan3 mwan3_hook icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, nd-redirect } return 2>/dev/null
		fi

		nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} == 0 ct mark set meta mark 2>/dev/null
		nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} == 0 meta mark set ct mark 2>/dev/null
		nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} == 0 jump mwan3_ifaces_in 2>/dev/null

		for chain in custom connected dynamic; do
			nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} == 0 jump mwan3_${chain}_${family} 2>/dev/null
		done

		nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} == 0 jump mwan3_rules 2>/dev/null
		nft add rule inet mwan3 mwan3_hook ct mark set meta mark 2>/dev/null

		for chain in custom connected dynamic; do
			nft add rule inet mwan3 mwan3_hook meta mark and ${MMX_MASK} != ${MMX_DEFAULT} jump mwan3_${chain}_${family} 2>/dev/null
		done
	done

	nft add rule inet mwan3 prerouting jump mwan3_hook 2>/dev/null
	nft add rule inet mwan3 output jump mwan3_hook 2>/dev/null
	LOG notice "mwan3_set_general_iptables: nft rules applied"
}

mwan3_create_iface_iptables()
{
	local id family device mark

	config_get family "$1" family ipv4
	mwan3_get_iface_id id "$1"
	[ -n "$id" ] || return 0
	device="$2"
	mark=$(mwan3_id2mask id MMX_MASK)

	nft_create_chain "mwan3_iface_in_$1"
	nft flush chain inet mwan3 "mwan3_iface_in_$1" 2>/dev/null

	for chain in custom connected dynamic; do
		nft add rule inet mwan3 "mwan3_iface_in_$1" 			iifname "$device" ip saddr @mwan3_${chain}_${family} 			meta mark and ${MMX_MASK} == 0 			meta mark set "meta mark & ~${MMX_MASK} | ${MMX_DEFAULT}" 2>/dev/null
	done

	nft add rule inet mwan3 "mwan3_iface_in_$1" 		iifname "$device" meta mark and ${MMX_MASK} == 0 		meta mark set "meta mark & ~${MMX_MASK} | ${mark}" 2>/dev/null

	nft list chain inet mwan3 mwan3_ifaces_in 2>/dev/null | grep -q "mwan3_iface_in_$1" || 		nft add rule inet mwan3 mwan3_ifaces_in meta mark and ${MMX_MASK} == 0 jump "mwan3_iface_in_$1" 2>/dev/null

	LOG debug "create_iface_iptables: mwan3_iface_in_$1 applied via nft"
}

mwan3_delete_iface_iptables()
{
	config_get family "$1" family ipv4
	nft flush chain inet mwan3 mwan3_ifaces_in 2>/dev/null
	nft_delete_chain "mwan3_iface_in_$1"
	LOG debug "delete_iface_iptables: mwan3_iface_in_$1 removed from nft"
}

mwan3_extra_tables_routes()
{
	$IP route list table "$1"
}

mwan3_get_routes()
{
	{
		$IP route list table main
		config_list_foreach "globals" "rt_table_lookup" mwan3_extra_tables_routes
	} | sed -ne "$MWAN3_ROUTE_LINE_EXP" | sort -u
}

mwan3_create_iface_route()
{
	local tid route_line family IP id tbl
	config_get family "$1" family ipv4
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ]; then
		IP="$IP6"
	fi

	tbl=$($IP route list table $id 2>/dev/null)$'\n'
	mwan3_update_dev_to_table
	mwan3_get_routes | while read -r route_line; do
		mwan3_route_line_dev "tid" "$route_line" "$family"
		{ [ -z "${route_line##default*}" ] || [ -z "${route_line##fe80::/64*}" ]; } && [ "$tid" != "$id" ] && continue
		if [ -z "$tid" ] || [ "$tid" = "$id" ]; then
			# possible that routes are already in the table
			# if 'connected' was called after 'ifup'
			[ -n "$tbl" ] && [ -z "${tbl##*$route_line$'\n'*}" ] && continue
			$IP route add table $id $route_line ||
				LOG debug "Route '$route_line' already added to table $id"
		fi

	done
}

mwan3_delete_iface_route()
{
	local id family

	config_get family "$1" family ipv4
	mwan3_get_iface_id id "$1"

	if [ -z "$id" ]; then
		LOG warn "delete_iface_route: could not find table id for interface $1"
		return 0
	fi

	if [ "$family" = "ipv4" ]; then
		$IP4 route flush table "$id"
	elif [ "$family" = "ipv6" ] && [ $NO_IPV6 -eq 0 ]; then
		$IP6 route flush table "$id"
	fi
}

mwan3_create_iface_rules()
{
	local id family IP

	config_get family "$1" family ipv4
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ] && [ $NO_IPV6 -eq 0 ]; then
		IP="$IP6"
	else
		return
	fi

	mwan3_delete_iface_rules "$1"

	$IP rule add pref $((id+1000)) iif "$2" lookup "$id"
	$IP rule add pref $((id+2000)) fwmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK" lookup "$id"
	$IP rule add pref $((id+3000)) fwmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK" unreachable
}

mwan3_delete_iface_rules()
{
	local id family IP rule_id

	config_get family "$1" family ipv4
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ] && [ $NO_IPV6 -eq 0 ]; then
		IP="$IP6"
	else
		return
	fi

	for rule_id in $(ip rule list | awk -F : '$1 % 1000 == '$id' && $1 > 1000 && $1 < 4000 {print $1}'); do
		$IP rule del pref $rule_id
	done
}

mwan3_delete_iface_ipset_entries()
{
	local id setname

	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0

	for setname in $(nft list sets inet mwan3 2>/dev/null | awk '$2=="set" && $3~/^mwan3_rule_/ {print $3}'); do
		nft flush set inet mwan3 "$setname" 2>/dev/null || \
			LOG notice "failed to flush $setname"
	done
}


mwan3_set_policy()
{
	local id iface family metric probability weight device is_lowest is_offline total_weight
	local policy="$2"

	is_lowest=0
	config_get iface "$1" interface
	config_get metric "$1" metric 1
	config_get weight "$1" weight 1

	[ -n "$iface" ] || return 0
	network_get_device device "$iface"
	[ "$metric" -gt $DEFAULT_LOWEST_METRIC ] && LOG warn "Member interface $iface has >$DEFAULT_LOWEST_METRIC metric" && return 0

	mwan3_get_iface_id id "$iface"
	[ -n "$id" ] || return 0

	[ "$(mwan3_get_iface_hotplug_state "$iface")" = "online" ]
	is_offline=$?

	config_get family "$iface" family ipv4

	if [ "$family" = "ipv4" ] && [ $is_offline -eq 0 ]; then
		if [ "$metric" -lt "$lowest_metric_v4" ]; then
			is_lowest=1
			total_weight_v4=$weight
			lowest_metric_v4=$metric
		elif [ "$metric" -eq "$lowest_metric_v4" ]; then
			total_weight_v4=$((total_weight_v4+weight))
			total_weight=$total_weight_v4
		else
			return
		fi
	elif [ "$family" = "ipv6" ] && [ $NO_IPV6 -eq 0 ] && [ $is_offline -eq 0 ]; then
		if [ "$metric" -lt "$lowest_metric_v6" ]; then
			is_lowest=1
			total_weight_v6=$weight
			lowest_metric_v6=$metric
		elif [ "$metric" -eq "$lowest_metric_v6" ]; then
			total_weight_v6=$((total_weight_v6+weight))
			total_weight=$total_weight_v6
		else
			return
		fi
	fi

	if [ $is_lowest -eq 1 ]; then
		nft flush chain inet mwan3 "mwan3_policy_$policy" 2>/dev/null
		nft add rule inet mwan3 "mwan3_policy_$policy" 			meta mark and ${MMX_MASK} == 0 			meta mark set "meta mark & ~${MMX_MASK} | $(mwan3_id2mask id MMX_MASK)" 			comment "$iface $weight $weight" 2>/dev/null
	elif [ $is_offline -eq 0 ]; then
		probability=$((weight*100/total_weight))
		nft add rule inet mwan3 "mwan3_policy_$policy" 			meta mark and ${MMX_MASK} == 0 			numgen random mod 100 lt ${probability} 			meta mark set "meta mark & ~${MMX_MASK} | $(mwan3_id2mask id MMX_MASK)" 			comment "$iface $weight $total_weight" 2>/dev/null
	fi
}

mwan3_create_policies_iptables()
{
	local last_resort lowest_metric_v4 lowest_metric_v6 total_weight_v4 total_weight_v6 policy

	policy="$1"
	config_get last_resort "$1" last_resort unreachable

	if [ "$1" != "$(echo "$1" | cut -c1-15)" ]; then
		LOG warn "Policy $1 exceeds max of 15 chars. Not setting policy" && return 0
	fi

	nft_create_chain "mwan3_policy_$1"
	nft flush chain inet mwan3 "mwan3_policy_$1" 2>/dev/null

	case "$last_resort" in
		blackhole)
			nft add rule inet mwan3 "mwan3_policy_$1" meta mark and ${MMX_MASK} == 0 meta mark set "meta mark & ~${MMX_MASK} | ${MMX_BLACKHOLE}" comment "blackhole" 2>/dev/null
			;;
		default)
			nft add rule inet mwan3 "mwan3_policy_$1" meta mark and ${MMX_MASK} == 0 meta mark set "meta mark & ~${MMX_MASK} | ${MMX_DEFAULT}" comment "default" 2>/dev/null
			;;
		*)
			nft add rule inet mwan3 "mwan3_policy_$1" meta mark and ${MMX_MASK} == 0 meta mark set "meta mark & ~${MMX_MASK} | ${MMX_UNREACHABLE}" comment "unreachable" 2>/dev/null
			;;
	esac

	lowest_metric_v4=$DEFAULT_LOWEST_METRIC
	total_weight_v4=0
	lowest_metric_v6=$DEFAULT_LOWEST_METRIC
	total_weight_v6=0

	config_list_foreach "$1" use_member mwan3_set_policy "$1"
}

mwan3_set_policies_iptables()
{
	config_foreach mwan3_create_policies_iptables policy
}

mwan3_set_sticky_iptables()
{
	local interface="${1}"
	local rule="${2}"
	local ipv="${3}"
	local policy="${4}"

	local id iface
	for iface in $(echo "$current" | grep "^-A $policy" | cut -s -d'"' -f2 | awk '{print $1}'); do
		if [ "$iface" = "$interface" ]; then

			mwan3_get_iface_id id "$iface"

			[ -n "$id" ] || return 0
			if [ -z "${current##*-N mwan3_iface_in_${iface}$'\n'*}" ]; then
				mwan3_push_update -I "mwan3_rule_$rule" \
						  -m mark --mark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK" \
						  -m set ! --match-set "mwan3_rule_${ipv}_${rule}" src,src \
						  -j MARK --set-xmark "0x0/$MMX_MASK"
				mwan3_push_update -I "mwan3_rule_$rule" \
						  -m mark --mark "0/$MMX_MASK" \
						  -j MARK --set-xmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK"
			fi
		fi
	done
}

mwan3_set_sticky_ipset()
{
	local rule="$1"
	local mmx="$2"
	local timeout="$3"

	nft add set inet mwan3 "mwan3_rule_ipv4_$rule" 		"{ type ipv4_addr . mark; flags timeout; timeout ${timeout}s; }" 2>/dev/null
	[ $NO_IPV6 -eq 0 ] && 		nft add set inet mwan3 "mwan3_rule_ipv6_$rule" 			"{ type ipv6_addr . mark; flags timeout; timeout ${timeout}s; }" 2>/dev/null
}

mwan3_set_user_iptables_rule()
{
	local ipset family proto src_ip src_port src_iface src_dev
	local sticky dest_ip dest_port use_policy timeout policy rule ipv
	local global_logging rule_logging loglevel rule_policy

	rule="$1"
	ipv="$2"
	rule_policy=0
	config_get sticky "$1" sticky 0
	config_get timeout "$1" timeout 600
	config_get ipset "$1" ipset
	config_get proto "$1" proto all
	config_get src_ip "$1" src_ip
	config_get src_iface "$1" src_iface
	config_get src_port "$1" src_port
	config_get dest_ip "$1" dest_ip
	config_get dest_port "$1" dest_port
	config_get use_policy "$1" use_policy
	config_get family "$1" family any
	config_get rule_logging "$1" logging 0
	config_get global_logging globals logging 0
	config_get loglevel globals loglevel notice

	[ "$ipv" = "ipv6" ] && [ $NO_IPV6 -ne 0 ] && return
	[ "$family" = "ipv4" ] && [ "$ipv" = "ipv6" ] && return
	[ "$family" = "ipv6" ] && [ "$ipv" = "ipv4" ] && return

	if [ -n "$src_iface" ]; then
		network_get_device src_dev "$src_iface"
		if [ -z "$src_dev" ]; then
			LOG notice "could not find device for src_iface $src_iface in rule $rule"
			return
		fi
	fi

	[ -z "$use_policy" ] && return

	# build nft match expressions
	local match=""
	[ "$proto" != "all" ] && match="$match meta l4proto $proto"
	[ -n "$src_ip" ] && match="$match ip saddr $src_ip"
	[ -n "$dest_ip" ] && match="$match ip daddr $dest_ip"
	[ -n "$src_dev" ] && match="$match iifname "$src_dev""
	[ -n "$ipset" ] && match="$match ip daddr @${ipset}"
	[ -n "$src_port" ] && match="$match th sport { $src_port }"
	[ -n "$dest_port" ] && match="$match th dport { $dest_port }"
	match="$match meta mark and ${MMX_MASK} == 0"

	if [ "$use_policy" = "default" ]; then
		policy="meta mark set "meta mark & ~${MMX_MASK} | ${MMX_DEFAULT}""
	elif [ "$use_policy" = "unreachable" ]; then
		policy="meta mark set "meta mark & ~${MMX_MASK} | ${MMX_UNREACHABLE}""
	elif [ "$use_policy" = "blackhole" ]; then
		policy="meta mark set "meta mark & ~${MMX_MASK} | ${MMX_BLACKHOLE}""
	else
		rule_policy=1
		nft_create_chain "mwan3_policy_$use_policy"
		policy="jump mwan3_policy_$use_policy"
	fi

	if [ "$global_logging" = "1" ] && [ "$rule_logging" = "1" ]; then
		nft add rule inet mwan3 mwan3_rules $match log prefix "MWAN3($rule): " level $loglevel 2>/dev/null
	fi

	nft add rule inet mwan3 mwan3_rules $match $policy comment "$rule" 2>/dev/null
}

mwan3_set_user_iface_rules()
{
	local current iface update family error device is_src_iface
	iface=$1
	device=$2

	if [ -z "$device" ]; then
		LOG notice "set_user_iface_rules: could not find device corresponding to iface $iface"
		return
	fi

	config_get family "$iface" family ipv4

	nft list chain inet mwan3 mwan3_rules 2>/dev/null | grep -q "iifname.*$device" && return

	is_src_iface=0

	iface_rule()
	{
		local src_iface
		config_get src_iface "$1" src_iface
		[ "$src_iface" = "$iface" ] && is_src_iface=1
	}
	config_foreach iface_rule rule
	[ $is_src_iface -eq 1 ] && mwan3_set_user_rules
}

mwan3_set_user_rules()
{
	local ipv

	# flush mwan3_rules chain then repopulate
	nft flush chain inet mwan3 mwan3_rules 2>/dev/null

	for ipv in ipv4 ipv6; do
		[ "$ipv" = "ipv6" ] && [ $NO_IPV6 -ne 0 ] && continue
		config_foreach mwan3_set_user_iptables_rule rule "$ipv"
	done

	LOG debug "set_user_rules: nft mwan3_rules chain updated"
}

mwan3_interface_hotplug_shutdown()
{
	local interface status device ifdown
	interface="$1"
	ifdown="$2"
	[ -f $MWAN3TRACK_STATUS_DIR/$interface/STATUS ] && {
		readfile status $MWAN3TRACK_STATUS_DIR/$interface/STATUS
	}

	[ "$status" != "online" ] && [ "$ifdown" != 1 ] && return

	if [ "$ifdown" = 1 ]; then
		env -i ACTION=ifdown \
			INTERFACE=$interface \
			DEVICE=$device \
			sh /etc/hotplug.d/iface/15-mwan3
	else
		[ "$status" = "online" ] && {
			env -i MWAN3_SHUTDOWN="1" \
				ACTION="disconnected" \
				INTERFACE="$interface" \
				DEVICE="$device" /sbin/hotplug-call iface
		}
	fi

}

mwan3_interface_shutdown()
{
	mwan3_interface_hotplug_shutdown $1
	mwan3_track_clean $1
}

mwan3_ifup()
{
	local interface=$1
	local caller=$2

	local up l3_device status true_iface

	if [ "${caller}" = "cmd" ]; then
		# It is not necessary to obtain a lock here, because it is obtained in the hotplug
		# script, but we still want to do the check to print a useful error message
		/etc/init.d/mwan3 running || {
			echo 'The service mwan3 is global disabled.'
			echo 'Please execute "/etc/init.d/mwan3 start" first.'
			exit 1
		}
		config_load mwan3
	fi
	mwan3_get_true_iface true_iface $interface
	status=$(ubus -S call network.interface.$true_iface status)

	[ -n "$status" ] && {
		json_load "$status"
		json_get_vars up l3_device
	}
	hotplug_startup()
	{
		env -i MWAN3_STARTUP=$caller ACTION=ifup \
		    INTERFACE=$interface DEVICE=$l3_device \
		    sh /etc/hotplug.d/iface/15-mwan3
	}

	if [ "$up" != "1" ] || [ -z "$l3_device" ]; then
		return
	fi

	if [ "${caller}" = "init" ]; then
		hotplug_startup &
		hotplug_pids="$hotplug_pids $!"
	else
		hotplug_startup
	fi

}

mwan3_set_iface_hotplug_state() {
	local iface=$1
	local state=$2

	echo "$state" > "$MWAN3_STATUS_DIR/iface_state/$iface"
}

mwan3_get_iface_hotplug_state() {
	local iface=$1
	local state=offline
	# 优先读 mwan3track STATUS 文件
	if [ -f "$MWAN3TRACK_STATUS_DIR/$iface/STATUS" ]; then
		readfile state "$MWAN3TRACK_STATUS_DIR/$iface/STATUS"
	else
		readfile state "$MWAN3_STATUS_DIR/iface_state/$iface"
	fi
	echo "$state"
}

mwan3_report_iface_status()
{
	local device result tracking IP IPT
	local status online uptime result

	mwan3_get_iface_id id "$1"
	network_get_device device "$1"
	config_get_bool enabled "$1" enabled 0
	config_get family "$1" family ipv4

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	fi

	if [ "$family" = "ipv6" ]; then
		IP="$IP6"
	fi

	if [ -f "$MWAN3TRACK_STATUS_DIR/${1}/STATUS" ]; then
		readfile status "$MWAN3TRACK_STATUS_DIR/${1}/STATUS"
	else
		status="unknown"
	fi

	if [ "$status" = "online" ]; then
		get_online_time online "$1"
		network_get_uptime uptime "$1"
		online="$(printf '%02dh:%02dm:%02ds\n' $((online/3600)) $((online%3600/60)) $((online%60)))"
		uptime="$(printf '%02dh:%02dm:%02ds\n' $((uptime/3600)) $((uptime%3600/60)) $((uptime%60)))"
		result="$(mwan3_get_iface_hotplug_state $1) $online, uptime $uptime"
	else
		result=0
		[ -n "$($IP rule | awk '$1 == "'$((id+1000)):'"')" ] ||
			result=$((result+1))
		[ -n "$($IP rule | awk '$1 == "'$((id+2000)):'"')" ] ||
			result=$((result+2))
		[ -n "$($IP rule | awk '$1 == "'$((id+3000)):'"')" ] ||
			result=$((result+4))
		[ -n "$($IPT -S mwan3_iface_in_$1 2> /dev/null)" ] ||
			result=$((result+8))
		[ -n "$($IP route list table $id default dev $device 2> /dev/null)" ] ||
			result=$((result+16))
		[ "$result" = "0" ] && result=""
	fi

	mwan3_get_mwan3track_status tracking $1
	if [ -n "$result" ]; then
		echo " interface $1 is $status and tracking is $tracking ($result)"
	else
		echo " interface $1 is $status and tracking is $tracking"
	fi
}

mwan3_report_policies()
{
	local ipt="$1"
	local policy="$2"

	local percent total_weight weight iface

	total_weight=$($ipt -S "$policy" | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | head -1 | awk '{print $3}')

	if [ -n "${total_weight##*[!0-9]*}" ]; then
		for iface in $($ipt -S "$policy" | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | awk '{print $1}'); do
			weight=$($ipt -S "$policy" | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | awk '$1 == "'$iface'"' | awk '{print $2}')
			percent=$((weight*100/total_weight))
			echo " $iface ($percent%)"
		done
	else
		echo " $($ipt -S "$policy" | grep -v '.*--comment "out .*" .*$' | sed '/.*--comment \([^ ]*\) .*$/!d;s//\1/;q')"
	fi
}

mwan3_report_policies_v4()
{
	local policy

	for policy in $(nft_list_chain | awk '{print $2}' | grep mwan3_policy_ | sort -u); do
		echo "$policy:" | sed 's/mwan3_policy_//'
		mwan3_report_policies_nft "$policy"
	done
}

mwan3_report_policies_v6()
{
	local policy

	for policy in $(nft_list_chain | awk '{print $2}' | grep mwan3_policy_ | sort -u); do
		echo "$policy:" | sed 's/mwan3_policy_//'
		mwan3_report_policies_nft "$policy"
	done
}

mwan3_report_connected_v4()
{
	if [ -n "$(nft_list_chain mwan3_connected_ipv4 2> /dev/null)" ]; then
		nft list set inet mwan3 mwan3_connected_ipv4 | grep add | cut -d " " -f 3
	fi
}

mwan3_report_connected_v6()
{
	if [ -n "$(nft_list_chain mwan3_connected_ipv6 2> /dev/null)" ]; then
		nft list set inet mwan3 mwan3_connected_ipv6 | grep add | cut -d " " -f 3
	fi
}

mwan3_report_rules_v4()
{
	if [ -n "$(nft_list_chain mwan3_rules 2> /dev/null)" ]; then
		nft_list_rules mwan3_rules 2> /dev/null | tail -n+3 | sed 's/mark.*//' | sed 's/mwan3_policy_/- /' | sed 's/mwan3_rule_/S /'
	fi
}

mwan3_report_rules_v6()
{
	if [ -n "$(nft_list_chain mwan3_rules 2> /dev/null)" ]; then
		nft_list_rules mwan3_rules 2> /dev/null | tail -n+3 | sed 's/mark.*//' | sed 's/mwan3_policy_/- /' | sed 's/mwan3_rule_/S /'
	fi
}

mwan3_flush_conntrack()
{
	local interface="$1"
	local action="$2"

	handle_flush() {
		local flush_conntrack="$1"
		local action="$2"

		if [ "$action" = "$flush_conntrack" ]; then
			echo f > ${CONNTRACK_FILE}
			LOG info "Connection tracking flushed for interface '$interface' on action '$action'"
		fi
	}

	if [ -e "$CONNTRACK_FILE" ]; then
		config_list_foreach "$interface" flush_conntrack handle_flush "$action"
	fi
}

mwan3_track_clean()
{
	rm -rf "${MWAN3_STATUS_DIR:?}/${1}" &> /dev/null
	rmdir --ignore-fail-on-non-empty "$MWAN3_STATUS_DIR"
}
