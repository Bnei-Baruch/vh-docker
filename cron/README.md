# Cron

Three production jobs, consolidated here from the two files on the current
Scaleway production host.

## Install — at cutover, not before

```bash
install -m 0644 /root/vh-docker/cron/vh.cron /etc/cron.d/vh
```

`post-install.sh` deliberately does **not** do this.

During Phase 2 the new production VM runs against a restored copy of *real*
production data. `robokasa.sh` imports payments, `activate_specials.sh` mutates
offers, and `invalidate_memberships.sh` expires memberships — all against live
customer rows, and all invisible until a customer complains. Installing cron
early is the one Phase-2 mistake that reaches actual people.

To exercise the jobs during validation, run them on demand instead:

```bash
docker exec vh-srv-orders ./activate_specials.sh
```

That is validation-matrix row 12, and it is a deliberate manual run, not a
schedule.

## Two ways these break quietly

**Timezone.** The entries are wall-clock. `install_rocky_9.sh` sets the host
timezone; if it does not match the old production host, every job shifts and
nothing errors.

**Container names.** Each line targets a `container_name` set in the service's
own compose file. Rename or re-project a service and `docker exec` fails into
cron mail that nobody reads. After installing, confirm:

```bash
docker ps --format '{{.Names}}' | grep -E 'vh-srv-(orders|profile)'
```
