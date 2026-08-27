# GTNH admin

## SSH

```bash
ssh -p 2222 minecraft@gtnh.constantan.dev
```

ログイン先はGTNHデータを格納した`/data`です。公開鍵は[`authorized_keys`](./authorized_keys)で管理します。

## mc-admin

| コマンド | 内容 |
| --- | --- |
| `mc-admin status` | サーバーの稼働状態を表示する |
| `mc-admin stop` | サーバーを停止し、Podの終了を待つ |
| `mc-admin start` | サーバーを起動し、利用可能になるまで待つ |
| `mc-admin backups` | ZIPバックアップを新しい順に表示する |
| `mc-admin restore <backup.zip\|latest>` | 指定したバックアップを復元する |
| `mc-admin rollback list` | 退避されたデータを新しい順に表示する |
| `mc-admin rollback apply <id\|latest>` | ロールバックを適用する |
| `mc-admin rollback delete <id>` | ロールバックを削除する |

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

`restore`は停止中のサーバーにだけ実行できます。復元前のデータは`/data/.minecraft-admin-rollbacks`へ退避され、サーバーは自動では起動しません。

## Rollback

```bash
mc-admin rollback list
mc-admin stop
mc-admin rollback apply latest
mc-admin start
```

`apply`は現在のデータを新しいロールバックへ退避します。適用したロールバックのIDは消費されます。
中断した復元またはロールバックが残っている場合、`mc-admin start`はサーバーを起動しません。

```bash
mc-admin rollback delete <id>
```
