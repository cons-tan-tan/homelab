# GTNH admin

## SSH

```bash
ssh -p 2222 minecraft@gtnh.constantan.dev
```

The login directory is `/data`, which contains the GTNH data. Public keys are
managed in [`authorized_keys`](../../../kubernetes/apps/minecraft/gtnh/admin/authorized_keys).

## mc-admin

| Command | Description |
| --- | --- |
| `mc-admin status` | Show the server status |
| `mc-admin stop` | Stop the server and wait for its Pods to terminate |
| `mc-admin start` | Start the server and wait until it is ready |
| `mc-admin backups` | List ZIP backups, newest first |
| `mc-admin restore <backup.zip\|latest>` | Restore the specified backup |
| `mc-admin rollback list` | List retained rollback data, newest first |
| `mc-admin rollback apply <id\|latest>` | Apply a rollback |
| `mc-admin rollback delete <id>` | Delete a rollback |

```bash
mc-admin --help
mc-admin restore --help
mc-admin rollback --help
```

## Restore from Backup

```bash
mc-admin backups
mc-admin stop
mc-admin restore latest
mc-admin start
```

`restore` can only run while the server is stopped. The existing data is moved
to `/data/.minecraft-admin-rollbacks` before restoration. The server is not
started automatically.

## Rollback

```bash
mc-admin rollback list
mc-admin stop
mc-admin rollback apply latest
mc-admin start
```

`apply` retains the current data as a new rollback and consumes the selected
rollback ID. `mc-admin start` refuses to start the server while an interrupted
restore or rollback remains unresolved.

```bash
mc-admin rollback delete <id>
```
