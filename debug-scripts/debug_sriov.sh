#!/bin/bash

SRIOV_NAMESPACE=${SRIOV_NAMESPACE:-"openshift-sriov-network-operator"}
SSH_OPTS='-o StrictHostKeyChecking=no -o PasswordAuthentication=no'

# echoes the command provided as $@ and then runs it
echo_and_eval () {
    echo "> $*"
    echo ""
    eval "$@"
    echo ""
}

# runs the command provided as $@, and either returns silently with
# status 0 or else logs an error message with the command's output
try_eval () {
	tmpfile=`mktemp`
	if ! eval "$@" >& $tmpfile; then
		status=1
		echo "ERROR: Could not run '$*':"
		sed -e 's/^/  /' $tmpfile
		echo ""
    else
		status=0
	fi
	rm -f $tmpfile
	return $status
}

run_self_via_ssh () {
	args=$1
	host=$2

	if ! try_eval ssh $SSH_OPTS core@$host /bin/true; then
		return 1
	fi

	if ! try_eval ssh $SSH_OPTS core@$host mkdir -m 0700 -p $logdir; then
		return 1
	fi

	if ! try_eval scp -pr $SSH_OPTS $logdir/meta core@$host:$logdir; then
		return 1
	fi

	ssh $SSH_OPTS core@$host $extra_env /bin/bash $logdir/meta/debug.sh $args
}

do_operator () {
	while read node addr; do
		stat=$(oc get sriovnetworknodestate $node -n $SRIOV_NAMESPACE --template '{{.status.syncStatus}}' 2>/dev/null)
		if [ "$stat" == "Succeeded" ]; then
			printf "$node ($addr) syncStatus: succeeded\n"
			sriovNodes+=($node)
		elif [ "$stat" == "InProgress" ]; then
			printf "$node ($addr) syncStatus: in progress\n"
		elif [ "$stat" == "Failed" ]; then
			err=$(oc get sriovnetworknodestate $node -n $SRIOV_NAMESPACE --template '{{.status.lastSyncError}}')
			printf "$node ($addr) syncStatus error: $err\n"
		else
			printf "$node ($addr) is not configured as a SR-IOV node\n"
		fi
	done < $logdir/meta/nodeinfo
}

do_node () {
	while read node addr; do
		if ip addr show | grep -q "inet $addr/"; then
			printf "checking devices on node $node\n"

			# Grab node device log
			log_nodedevices $node

			# Grab node system log
			log_nodesystem $node
		fi
	done < $logdir/meta/nodeinfo
}

log_nodeinfo () {
	# Outputs a list of nodes in the form "nodename IP"
	oc get nodes --template '{{range .items}}{{$name := .metadata.name}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{$name}} {{.address}}{{"\n"}}{{end}}{{end}}{{end}}' > $logdir/meta/nodeinfo
}

log_operatorconfig () {
	# Output default operator config in the form "daemonNodeSelector enableInjector enableOperatorWebhook logLevel"
	oc get sriovoperatorconfig default -n $SRIOV_NAMESPACE --template '{{.spec.enableInjector}} {{.spec.enableOperatorWebhook}} {{.spec.logLevel}}' > $logdir/meta/operatorconfig
}

log_policy () {
	# Output a list of policies in the form ""
	oc get sriovnetworknodepolicy -n $SRIOV_NAMESPACE --template '{{range .items}}{{if ne .metadata.name "default"}}{{.metadata.name}} {{.spec.deviceType}} {{.spec.linkType}} {{.spec.numVfs}} {{.spec.resourceName}} {{.spec.isRdma}} {{.spec.priority}} {{"\n"}}{{end}}{{end}}' > $logdir/meta/policy
}

log_sriovstate () {
	while read node addr; do
		len=$(oc get sriovnetworknodestate $node -n $SRIOV_NAMESPACE --template '{{len .spec.interfaces}}' 2>/dev/null)
		# Outputs a list of node PF devices in the form "nodename interfacename pciaddress numvfs linktype"
		for i in $(seq 0 $(($len-1))); do
			oc get sriovnetworknodestate $node -n $SRIOV_NAMESPACE --template "{{.metadata.name}} {{(index .spec.interfaces $i).name}} {{(index .spec.interfaces $i).pciAddress}} {{(index .spec.interfaces $i).linkType}} {{(index .spec.interfaces $i).numVfs}}{{\"\n\"}}" >> $logdir/meta/state
		done
	done < $logdir/meta/nodeinfo
}

log_nodesystem () {
	node=$1
	lognode=$logdir/nodes/$node
	mkdir -p $lognode

	dmesg                                                  > $lognode/dmesg
	try_eval "cat /proc/cmdline"                           > $lognode/cmdline
	try_eval "cat /etc/udev/rules.d/10-nm-unmanaged.rules" > $lognode/udev
}

log_nodedevices () {
	node=$1
	lognode=$logdir/nodes/$node
	mkdir -p $lognode

	ls -al /sys/class/net/ > $lognode/sys-class-net
	ip link show           > $lognode/sys-class-net

	while read dev_node dev_name dev_pci dev_link dev_numvfs; do
		if [ "$node" == "$dev_node" ]; then
			echo_and_eval "ip -d link show $dev_name"                                    >> $lognode/sys-class-net-$dev_name
			echo_and_eval "ls -al /sys/class/net/ | grep $dev_name"                      >> $lognode/sys-class-net-$dev_name
			echo_and_eval "ls -al /sys/class/net/$dev_name/device"                       >> $lognode/sys-class-net-$dev_name
			echo_and_eval "ls -al /sys/class/net/$dev_name/device/ | grep virtfn"        >> $lognode/sys-class-net-$dev_name
		fi
	done < $logdir/meta/state
}

do_operator_and_nodes () {
	log_nodeinfo
	log_operatorconfig
	log_policy
	log_sriovstate

	printf "\n"
	printf "Analyzing SR-IOV operator APIs\n"
	do_operator

	printf "\n"
	printf "Analyzing nodes\n"

	while read node addr; do
		run_self_via_ssh --node $addr < /dev/null && \
		try_eval scp $SSH_OPTS -pr core@$addr:$logdir/nodes $logdir
	done < $logdir/meta/nodeinfo
}

case "$0" in
	/*)
	self=$0
	;;
	*)
	self=$(pwd)/$0
	;;
esac

case "$1" in
	--node)
	logdir=$(dirname $0 | sed -e 's|/meta$||')
	do_node
	exit 0
	;;
esac

logdir=$(mktemp --tmpdir -d openshift-sriov-debug-XXXXXXXXX)
echo $logdir
mkdir $logdir/meta
cp $self $logdir/meta/debug.sh
mkdir $logdir/master
mkdir $logdir/nodes
do_operator_and_nodes |& tee $logdir/log

dumpname=openshift-sriov-debug-$(date --iso-8601).tgz
(cd $logdir; tar -cf - --transform='s/^\./openshift-sriov-debug/' .) | gzip -c > $dumpname
echo ""
echo "Output is in $dumpname"
