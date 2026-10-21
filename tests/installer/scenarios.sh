# Every scenario prints PASS or FAIL. CI's call is reproduced exactly:
# the deploy user runs "sudo -n /usr/local/sbin/install-api".
pass=0
failed=0
check() {
  if [ "$1" = "$2" ]; then
    echo "PASS  $3"; pass=$((pass + 1))
  else
    echo "FAIL  $3 (got \"$1\", want \"$2\")"; failed=$((failed + 1))
  fi
}
ship() { install -o deploy -g deploy -m 0644 "$1" /srv/deploy/incoming/api.tar.gz; }
run_installer() { sudo -u deploy sudo -n /usr/local/sbin/install-api >/tmp/out 2>&1; echo $?; }
ready() { curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/readyz; }
package_with() { # package_with <binary> <migrations file> <output>
  local e; e="$(mktemp -d)"
  cp "$1" "$e/api"; cp "$2" "$e/migrations.txt"
  tar -czf "$3" -C "$e" api migrations.txt
}
good="$(mktemp -d)"
tar -xzf /t/api.tar.gz -C "$good"

# --- migration gate -----------------------------------------------------------
ship /t/api.tar.gz
check "$(run_installer)" 1 "refused while migration 003 is not applied"
if grep -q 'not yet applied to shop: 003' /tmp/out; then r=yes; else r=no; fi
check "$r" yes "the refusal names migration 003"
check "$(test -e /opt/api/api && echo exists || echo absent)" absent "nothing was installed"
mariadb -e "INSERT INTO shop.schema_migrations VALUES ('003')"

# --- first and second deploy --------------------------------------------------
check "$(run_installer)" 0 "installs once 003 is applied"
check "$(ready)" 200 "/readyz answers"
check "$(stat -c '%U %a' /opt/api/api)" "root 755" "the binary is owned by root, not by the service"
check "$(systemctl show -p User --value api)" www-data "the service still runs as www-data"
check "$(test -e /srv/deploy/incoming/api.tar.gz && echo left || echo gone)" gone "the package is removed after success"
ship /t/api.tar.gz
check "$(run_installer)" 0 "a second deploy succeeds"
check "$(test -f /opt/api/api.bak && echo yes || echo no)" yes "the previous binary is kept as .bak"

# --- bad packages -------------------------------------------------------------
echo 'echo pwned' > /tmp/script
package_with /tmp/script "$good/migrations.txt" /tmp/a.tgz
ship /tmp/a.tgz
check "$(run_installer)" 1 "a shell script posing as the binary is refused"
tar -czf /tmp/b.tgz -C "$good" api
ship /tmp/b.tgz
check "$(run_installer)" 1 "a package without migrations.txt is refused"
printf '001\n; DROP TABLE x\n' > /tmp/evil.txt
package_with "$good/api" /tmp/evil.txt /tmp/c.tgz
ship /tmp/c.tgz
check "$(run_installer)" 1 "a migrations.txt with anything but numbers is refused"
ln -sf /etc/shadow /srv/deploy/incoming/api.tar.gz
check "$(run_installer)" 1 "a symlink as the package is refused"
rm -f /srv/deploy/incoming/*
check "$(ready)" 200 "the service kept running through all refusals"

# --- broken release: a valid ELF that never becomes ready -----------------------
before="$(sha256sum /opt/api/api | cut -c1-64)"
package_with /bin/sleep "$good/migrations.txt" /tmp/r.tgz
ship /tmp/r.tgz
check "$(run_installer)" 1 "a release that never becomes ready fails the build"
check "$(sha256sum /opt/api/api | cut -c1-64)" "$before" "the previous binary is restored"
check "$(ready)" 200 "/readyz answers again after the rollback"

# --- restart that fails at the systemd level ----------------------------------
# The old process keeps answering /readyz here, so an installer that only
# looks at /readyz would report success with a never-started binary on disk.
mkdir -p /etc/systemd/system/api.service.d
printf '[Unit]\nRequires=missing.service\n' > /etc/systemd/system/api.service.d/broken.conf
systemctl daemon-reload
package_with /bin/true "$good/migrations.txt" /tmp/t.tgz
ship /tmp/t.tgz
check "$(run_installer)" 1 "a failed systemctl restart fails the build, though /readyz still answers"
check "$(sha256sum /opt/api/api | cut -c1-64)" "$before" "the never-started binary is not left on disk"
rm /etc/systemd/system/api.service.d/broken.conf
systemctl daemon-reload

# --- privilege boundary -------------------------------------------------------
sudo -u deploy sudo -n /usr/local/sbin/install-api --anything >/dev/null 2>&1
check $? 1 "sudo refuses the installer with arguments"
sudo -u deploy sudo -n /bin/bash -c id >/dev/null 2>&1
check $? 1 "sudo refuses any other command"
printf '[Service]\nUser=root\n' > /etc/systemd/system/api.service.d/root.conf
systemctl daemon-reload
ship /t/api.tar.gz
check "$(run_installer)" 1 "a unit changed to run as root is refused"
rm /etc/systemd/system/api.service.d/root.conf
systemctl daemon-reload
rm -f /srv/deploy/incoming/*

# --- concurrency --------------------------------------------------------------
ship /t/api.tar.gz
( exec 9>/run/lock/install-api.lock; flock 9; sleep 4 ) &
sleep 1
check "$(run_installer)" 1 "a second deploy is refused while one is running"
wait
check "$(run_installer)" 0 "and succeeds once the lock is released"

echo "== $pass passed, $failed failed"
[ "$failed" -eq 0 ]
