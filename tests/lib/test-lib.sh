# Test framework for go-dms3fs
#
# Copyright (c) 2014 Christian Couder
# MIT Licensed; see the LICENSE file in this repository.
#
# We are using sharness (https://github.com/mlafeldt/sharness)
# which was extracted from the Git test framework.

# set sharness verbosity. we set the env var directly as
# it's too late to pass in --verbose, and --verbose is harder
# to pass through in some cases.
test "$TEST_VERBOSE" = 1 && verbose=t

cwd=$(pwd)
SHARNESS_LIB="lib/sharness/sharness.sh"

. "$SHARNESS_LIB" || {
	echo >&2 "Cannot source: $SHARNESS_LIB"
	echo >&2 "Please check Sharness installation."
	exit 1
}

# add current directory to path, for dms3fs tool.
# after loading sharness, so that ./bin takes precedence over ./.
PATH="$cwd"/bin:${PATH}
export PATH

# assert the `dms3fs` we're using is the right one.
if test `which dms3fs` != "$cwd/bin/dms3fs"; then
	echo >&2 "Found dms3fs executable but it's not $cwd/bin/dms3fs"
	echo >&2 "Check PATH: $PATH"
	exit 1
fi

# Please put go-dms3fs specific shell functions below

# grab + output options
test "$TEST_NO_FUSE" != 1 && test_set_prereq FUSE
test "$TEST_EXPENSIVE" = 1 && test_set_prereq EXPENSIVE

if test "$TEST_VERBOSE" = 1; then
	echo '# TEST_VERBOSE='"$TEST_VERBOSE"
	echo '# TEST_NO_FUSE='"$TEST_NO_FUSE"
	echo '# TEST_EXPENSIVE='"$TEST_EXPENSIVE"
fi

test_cmp_repeat_10_sec() {
	for i in $(test_seq 1 100)
	do
		test_cmp "$1" "$2" >/dev/null && return
		go-sleep 100ms
	done
	test_cmp "$1" "$2"
}

test_fsh() {
	echo "> $@"
	eval "$@"
	echo ""
	false
}

test_run_repeat_60_sec() {
	for i in $(test_seq 1 600)
	do
		(test_eval_ "$1") && return
		go-sleep 100ms
	done
	return 1 # failed
}

test_wait_output_n_lines_60_sec() {
	for i in $(test_seq 1 600)
	do
		test $(cat "$1" | wc -l | tr -d " ") -ge $2 && return
		go-sleep 100ms
	done
	actual=$(cat "$1" | wc -l | tr -d " ")
	test_fsh "expected $2 lines of output. got $actual"
}

test_wait_open_tcp_port_10_sec() {
	for i in $(test_seq 1 100)
	do
		# this is not a perfect check, but it's portable.
		# cant count on ss. not installed everywhere.
		# cant count on netstat using : or . as port delim. differ across platforms.
		echo $(netstat -aln | egrep "^tcp.*LISTEN" | egrep "[.:]$1" | wc -l) -gt 0
		if [ $(netstat -aln | egrep "^tcp.*LISTEN" | egrep "[.:]$1" | wc -l) -gt 0 ]; then
			return 0
		fi
		go-sleep 100ms
	done
	return 1
}


# test_config_set helps us make sure _we really did set_ a config value.
# it sets it and then tests it. This became elaborate because dms3fs config
# was setting really weird things and am not sure why.
test_config_set() {

	# grab flags (like --bool in "dms3fs config --bool")
	test_cfg_flags="" # unset in case.
	test "$#" = 3 && { test_cfg_flags=$1; shift; }

	test_cfg_key=$1
	test_cfg_val=$2

	# when verbose, tell the user what config values are being set
	test_cfg_cmd="dms3fs config $test_cfg_flags \"$test_cfg_key\" \"$test_cfg_val\""
	test "$TEST_VERBOSE" = 1 && echo "$test_cfg_cmd"

	# ok try setting the config key/val pair.
	dms3fs config $test_cfg_flags "$test_cfg_key" "$test_cfg_val"
	echo "$test_cfg_val" >cfg_set_expected
	dms3fs config "$test_cfg_key" >cfg_set_actual
	test_cmp cfg_set_expected cfg_set_actual
}

test_init_dms3fs() {

	# we have a problem where initializing daemons with the same api port
	# often fails-- it hangs indefinitely. The proper solution is to make
	# dms3fs pick an unused port for the api on startup, and then use that.
	# Unfortunately, dms3fs doesnt yet know how to do this-- the api port
	# must be specified. Until dms3fs learns how to do this, we must use
	# specific port numbers, which may still fail but less frequently
	# if we at least use different ones.

	# Using RANDOM like this is clearly wrong-- it samples with replacement
	# and it doesnt even check the port is unused. this is a trivial stop gap
	# until the proper solution is implemented.
	RANDOM=$$
	PORT_API=$((RANDOM % 3000 + 5100))
	ADDR_API="/ip4/127.0.0.1/tcp/$PORT_API"

	PORT_GWAY=$((RANDOM % 3000 + 8100))
	ADDR_GWAY="/ip4/127.0.0.1/tcp/$PORT_GWAY"

	PORT_SWARM=$((RANDOM % 3000 + 12000))
	ADDR_SWARM="[
  \"/ip4/0.0.0.0/tcp/$PORT_SWARM\"
]"


	# we set the Addresses.API config variable.
	# the cli client knows to use it, so only need to set.
	# todo: in the future, use env?

	test_expect_success "dms3fs init succeeds" '
		export DMS3FS_PATH="$(pwd)/.dms3-fs" &&
		dms3fs init -b=1024 > /dev/null
	'

	test_expect_success "prepare config -- mounting and bootstrap rm" '
		mkdir mountdir dms3fs dms3ns &&
		test_config_set Mounts.DMS3FS "$(pwd)/dms3fs" &&
		test_config_set Mounts.DMS3NS "$(pwd)/dms3ns" &&
		test_config_set Addresses.API "$ADDR_API" &&
		test_config_set Addresses.Gateway "$ADDR_GWAY" &&
		test_config_set --json Addresses.Swarm "$ADDR_SWARM" &&
		dms3fs bootstrap rm --all ||
		test_fsh cat "\"$DMS3FS_PATH/config\""
	'

}

test_config_dms3fs_gateway_readonly() {
	ADDR_GWAY=$1
	test_expect_success "prepare config -- gateway address" '
		test "$ADDR_GWAY" != "" &&
		test_config_set "Addresses.Gateway" "$ADDR_GWAY"
	'

	# tell the user what's going on if they messed up the call.
	if test "$#" = 0; then
		echo "#			Error: must call with an address, for example:"
		echo '#			test_config_dms3fs_gateway_readonly "/ip4/0.0.0.0/tcp/5002"'
		echo '#'
	fi
}

test_config_dms3fs_gateway_writable() {

	test_config_dms3fs_gateway_readonly $1

	test_expect_success "prepare config -- gateway writable" '
		test_config_set --bool Gateway.Writable true ||
		test_fsh cat "\"$DMS3FS_PATH/config\""
	'
}

test_launch_dms3fs_daemon() {

	args="$@"

	test_expect_success "'dms3fs daemon' succeeds" '
		dms3fs daemon $args >actual_daemon 2>daemon_err &
	'

	# we say the daemon is ready when the API server is ready.
	test_expect_success "'dms3fs daemon' is ready" '
		DMS3FS_PID=$! &&
		pollEndpoint -ep=/version -host=$ADDR_API -v -tout=1s -tries=60 2>poll_apierr > poll_apiout ||
		test_fsh cat actual_daemon || test_fsh cat daemon_err || test_fsh cat poll_apierr || test_fsh cat poll_apiout
	'

	if test "$ADDR_GWAY" != ""; then
		test_expect_success "'dms3fs daemon' output includes Gateway address" '
			pollEndpoint -ep=/version -host=$ADDR_GWAY -v -tout=1s -tries=60 2>poll_gwerr > poll_gwout ||
			test_fsh cat daemon_err || test_fsh cat poll_gwerr || test_fsh cat poll_gwout
		'
	fi
}

test_mount_dms3fs() {

	# make sure stuff is unmounted first.
	test_expect_success FUSE "'dms3fs mount' succeeds" '
		umount "$(pwd)/dms3fs" || true &&
		umount "$(pwd)/dms3ns" || true &&
		dms3fs mount >actual
	'

	test_expect_success FUSE "'dms3fs mount' output looks good" '
		echo "DMS3FS mounted at: $(pwd)/dms3fs" >expected &&
		echo "DMS3NS mounted at: $(pwd)/dms3ns" >>expected &&
		test_cmp expected actual
	'

}

test_launch_dms3fs_daemon_and_mount() {

	test_init_dms3fs
	test_launch_dms3fs_daemon
	test_mount_dms3fs

}

test_kill_repeat_10_sec() {
	# try to shut down once + wait for graceful exit
	kill $1
	for i in $(test_seq 1 100)
	do
		go-sleep 100ms
		! kill -0 $1 2>/dev/null && return
	done

	# if not, try once more, which will skip graceful exit
	kill $1
	go-sleep 1s
	! kill -0 $1 2>/dev/null && return

	# ok, no hope. kill it to prevent it messing with other tests
	kill -9 $1 2>/dev/null
	return 1
}

test_kill_dms3fs_daemon() {

	test_expect_success "'dms3fs daemon' is still running" '
		kill -0 $DMS3FS_PID
	'

	test_expect_success "'dms3fs daemon' can be killed" '
		test_kill_repeat_10_sec $DMS3FS_PID
	'
}

test_curl_resp_http_code() {
	curl -I "$1" >curl_output || {
		echo "curl error with url: '$1'"
		echo "curl output was:"
		cat curl_output
		return 1
	}
	shift &&
	RESP=$(head -1 curl_output) &&
	while test "$#" -gt 0
	do
		expr "$RESP" : "$1" >/dev/null && return
		shift
	done
	echo "curl response didn't match!"
	echo "curl response was: '$RESP'"
	echo "curl output was:"
	cat curl_output
	return 1
}

test_must_be_empty() {
	if test -s "$1"
	then
		echo "'$1' is not empty, it contains:"
		cat "$1"
		return 1
	fi
}

test_should_contain() {
	test "$#" = 2 || error "bug in the test script: not 2 parameters to test_should_contain"
	if ! grep -q "$1" "$2"
	then
		echo "'$2' does not contain '$1', it contains:"
		cat "$2"
		return 1
	fi
}

test_str_contains() {
	find=$1
	shift
	echo "$@" | grep "$find" >/dev/null
}

disk_usage() {
    # normalize du across systems
    case $(uname -s) in
        Linux)
            DU="du -sb"
            ;;
        FreeBSD)
            DU="du -s -A -B 1"
            ;;
        Darwin | DragonFly)
            DU="du"
            ;;
    esac
        $DU "$1" | awk "{print \$1}"
}

# output a file's permission in human readable format
generic_stat() {
    # normalize stat across systems
    case $(uname -s) in
        Linux)
            _STAT="stat -c %A"
            ;;
        FreeBSD | Darwin | DragonFly)
            _STAT="stat -f %Sp"
            ;;
    esac
    $_STAT "$1"
}

test_check_peerid() {
	peeridlen=$(echo "$1" | tr -dC "[:alnum:]" | wc -c | tr -d " ") &&
	test "$peeridlen" = "46" || {
		echo "Bad peerid '$1' with len '$peeridlen'"
		return 1
	}
}


make_package() {
	dir=$1
	lang=$2
	mkdir -p $dir
	test_expect_success "dms3gx init succeeds" '
		(cd $dir && dms3gx init --lang="$lang")
	'
}

publish_package() {
	pkgdir=$1
	(cd $pkgdir && dms3gx publish) | awk '{ print $6 }'
}

pkg_run() {
	dir=$1
	shift
	(cd $dir && $@)
}
