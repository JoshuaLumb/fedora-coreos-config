#!/bin/bash
set -xeuo pipefail

# No need to run on any other platform than QEMU.
# kola: { "tags": "needs-internet", "platforms": "qemu-unpriv" }

ok() {
    echo "ok" "$@"
}

fatal() {
    echo "$@" >&2
    exit 1
}

journal_cursor() {
	journalctl --output json --lines 1 \
		| jq --raw-output '.["__CURSOR"]' > /tmp/countme.cursor
}

journal_after_cursor() {
	journalctl --output=json \
		--after-cursor "$(cat /tmp/countme.cursor)" \
		--output=json --unit=rpm-ostree-countme.service \
		--grep "Successful requests:" \
		| jq --raw-output '.MESSAGE'
}

# Check that the timer has been enabled
if [[ $(systemctl show -p ActiveState rpm-ostree-countme.timer) != "ActiveState=active" ]] && \
   [[ $(systemctl show -p SubState rpm-ostree-countme.timer) != "SubState=waiting" ]]; then
	fatal "rpm-ostree-countme timer has not been started"
fi

# Try five times to avoid Fedora infra flakes
for i in $(seq 1 5); do
	# Remove status file so that we retry every time we flake
	rm -f /var/lib/private/rpm-ostree-countme/countme
	# Update the journal cursor
	journal_cursor

	# Check that running the service manually is successful
	systemctl start rpm-ostree-countme.service
	if [[ $(systemctl show -p ActiveState rpm-ostree-countme.service) != "ActiveState=inactive" ]] && \
	   [[ $(systemctl show -p SubState rpm-ostree-countme.service) != "SubState=dead" ]] && \
	   [[ $(systemctl show -p Result rpm-ostree-countme.service) != "Result=success" ]] && \
	   [[ $(systemctl show -p ExecMainStatus rpm-ostree-countme.service) != "ExecMainStatus=0" ]]; then
		echo "rpm-ostree-countme exited with an error (try: $i):"
		systemctl status rpm-ostree-countme.service
		sleep 10
		continue
	fi

	# Check rpm-ostree count me output
	output="$(journal_after_cursor)"
	# Depending on the stream, we expect different numbers of countme-enabled repos
	if [[ "${output}" != "Successful requests: 1/1" ]] && \
	   [[ "${output}" != "Successful requests: 2/2" ]] && \
	   [[ "${output}" != "Successful requests: 3/3" ]]; then
		echo "rpm-ostree-countme service ouput does not match expected sucess output (try: $i):"
		echo "${output}"
		sleep 10
		continue
	fi

	ok countme
	exit 0
done

fatal "rpm-ostree-countme service failed or only partially completed five times"
