# pve01 ファン騒音調査・永続化対応

## 概要

2026-07-01、`pve01` のファン音が通常より大きく、起動後もしばらく落ち着かない状態になった。
過去にも計画停電後に類似のファン常時高回転事象があり、当初は BIOS 設定リセット再発を疑って調査した。

結論として、今回確認できた主な要因は以下。

- Linux 起動後の CPU/GPU 電源管理が `performance` 寄りに戻っていた
- CPU/GPU 温度が 65〜75℃程度まで上がり、BIOS のファンカーブ上、ファンが中〜高回転域に入りやすかった
- BIOS 作業のために接続した HDMI モニターが iGPU 温度を押し上げ、ファン音が残る要因になっていた可能性が高い
- HDMI と USB 無線キーボードドングルを外したところ、体感上ファン音は収まった
- 有効だった Linux 側の省電力設定は、Ansible role と systemd oneshot service で永続化した

ファン RPM/PWM センサーは Linux から見えておらず、実回転数は直接確認できなかった。

## 対象ホスト

- ホスト: `pve01`
- 用途: Proxmox VE ノード
- マザーボード: HC Technology HCAR5000-MI
- BIOS: American Megatrends International, LLC. `0.22` / 2023-06-21
- CPU: AMD Ryzen 7 5800U with Radeon Graphics
- Kernel: `6.17.9-1-pve`
- CPU driver: `amd-pstate-epp`
- VM: `1101 k8s-wk-01` が onboot で起動

## 初期症状

- ファン音が徐々に大きくなり、通常より長く鳴り続けた
- 以前は起動後数分で落ち着いていたが、今回は落ち着きにくかった
- 発生当初、HDMI は接続しておらず、追加で接続していたのは USB 無線キーボードドングルのみ
- 調査中、BIOS 操作用に HDMI モニターを接続した

## 過去の類似事象

2026-05-14 の計画停電後にも、`pve01` でファンが起動直後だけでなく回り続ける事象があった。
このときも以下が観測されていた。

- CPU governor: `performance`
- EPP: `performance`
- CPU idle は高い一方で、CPU 温度は 69℃程度
- カーネルは前ブートと同じで、カーネル更新が主因とは考えにくかった
- governor を変更する自前 script/service は見つからなかった

当時は計画停電により電源断が発生していたため、BIOS 設定リセットや CMOS バッテリー弱化も疑った。
再発時は OS 側の power profile だけでなく、BIOS の以下も確認する。

- Fan Configuration
- Cool'n'Quiet
- Global C-state Control
- BIOS 時刻ずれ
- CMOS バッテリー状態

## 調査内容

### ブート・シャットダウン履歴

`journalctl --list-boots` と前回ブート末尾を確認した。

- 直前の shutdown はクラッシュではなく、OS としては正常な poweroff
- ユーザー申告により、これはファン音がうるさすぎて一度手動で停止したものと判明
- したがって shutdown 自体は原因ではなく、事象発生後の対応

### CPU 電源管理

初期状態では以下だった。

```text
scaling_governor = performance
energy_performance_preference = performance
energy_performance_available_preferences = performance
boost = 1
amd_pstate/status = active
```

全 CPU が `performance` 固定で、EPP も `performance` だった。
当初 `energy_performance_available_preferences` が `performance` しか見えなかったため、BIOS 側の省電力設定異常も疑った。

ただし、後で `scaling_governor` を `powersave` に変更した直後、EPP の選択肢が以下のように復活した。

```text
default performance balance_performance balance_power power
```

そのため、「EPP が performance しか見えない」状態は BIOS だけでなく、`governor=performance` の副作用だった可能性がある。

### 温度

sysfs 経由で確認した。

初期状態の例:

```text
CPU Tctl: 67〜72℃程度
amdgpu edge: 72〜75℃程度
NVMe: 45〜52℃程度
```

CPU 使用率は低く、`top` では idle が 95〜98% 程度あった。
一方で CPU/GPU 温度は高めで、ファンが回り続ける条件に入っていた。

### GPU 電源管理

amdgpu 側は初期状態で以下だった。

```text
power_dpm_force_performance_level = auto
power_dpm_state = performance
gpu_busy_percent = 0
```

gpu busy は 0% でも、`power_dpm_state=performance` かつ HDMI 接続時に iGPU 温度が上がりやすい状態だった。

### C-state

CPU idle state は以下まで見えていた。

```text
POLL
C1
C2
C3
```

C-state が完全に無効化されている状態ではなかった。

### ファンセンサー

以下を確認したが、ファン RPM/PWM は expose されていなかった。

```text
/sys/class/hwmon/**/fan*_input
/sys/class/hwmon/**/pwm*
```

結果:

```text
fan_or_pwm_sensor_not_exposed
```

そのため、ファンの強さは温度・電源状態・体感音から推定した。

## BIOS まわりの確認・調査

### 実機 BIOS

`pve01` の BIOS は以下。

```text
Vendor: American Megatrends International, LLC.
Version: 0.22
Release Date: 06/21/2023
```

### ネット上の同系機調査

`HCAR5000-MI` は、NiPoGi / KAMRUI / ACEMAGIC AM06 Pro 系ミニ PC の内部基板名として多数見つかった。

調査で分かったこと:

- 同系機は AMI Aptio BIOS
- BIOS は比較的シンプル
- レビュー上は「起動時だけファン全開、通常用途ではかなり静か」とされている
- Notebookcheck の同系機レビューでは、負荷時でも概ね 33 dB(A) 程度、CPU 75℃程度
- したがって、今回の低負荷で 70℃台・ファン音継続は通常状態より外れている

同系機 BIOS 画面例では `Advanced` 配下に以下のような項目があった。

```text
Power Configuration
CPU Configuration
AMD CBS
```

### Fan Control 設定例

AM06 Pro 系フォーラムで見つかったファンカーブ例:

```text
Fan Control = Auto
Low Temperature = 50
Medium Temperature = 65
High Temperature = 80
Critical Temperature = 95
Low PWM = 0 または 20
Medium PWM = 35
High PWM = 60
Temperature Hysteresis = 2
PWM Frequency = 25kHz
Fan Polarity = Positive
```

今回の温度が 65℃前後だったため、`Medium Temperature = 65` の設定だと常時 Medium 領域に入り、ファンが回り続ける可能性がある。

静音寄りにするなら、今後は以下も候補。

```text
Low Temperature = 55
Medium Temperature = 75
High Temperature = 85
Critical Temperature = 95
Low PWM = 20
Medium PWM = 30
High PWM = 60
Temperature Hysteresis = 3〜5
Fan Polarity = Positive
```

ただし、温度上昇余地が増えるため、Proxmox 常時稼働環境では様子を見ながら調整する。

### BIOS/EC 更新について

ネット上には AM06 Pro / HCAR5000-MI 系で BIOS `0.33` や EC 更新らしき情報があった。
一方で、CPU・基板リビジョン・販売ブランド違いによる文鎮化リスクがある。

今回の対応では BIOS/EC 更新は実施していない。
まずは設定と OS 側制御で対応する方針。

## 実施した一時対応

### CPU governor を powersave に変更

```bash
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo powersave > "$f"
done
```

### EPP を balance_power に変更

```bash
for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  echo balance_power > "$f"
done
```

### amdgpu を balanced に変更

```bash
gpu=/sys/bus/pci/drivers/amdgpu/0000:05:00.0
 echo auto > "$gpu/power_dpm_force_performance_level"
 echo balanced > "$gpu/power_dpm_state"
```

※ 実際には書き込み可否や EPP 選択肢を確認しながら実行した。

## 一時対応後の結果

設定変更直後:

```text
変更前:
CPU 71.6℃
GPU 73.0℃

after 60s:
CPU 64.9℃
GPU 63.0℃
```

5分程度のモニタリングでは、HDMI 接続中は以下で推移。

```text
CPU: 66〜67℃程度
GPU: 64〜66℃程度
```

その後、HDMI モニターと USB 無線キーボードドングルを外したところ、体感上ファン音が収まった。

モニター取り外し後の確認:

```text
CPU: 64.5〜64.8℃程度
GPU: 61〜62℃程度
NVMe: 47〜48℃程度
```

一時対応後の OS 側設定:

```text
CPU governor = powersave
EPP = balance_power
GPU DPM = balanced
HDMI/DP = disconnected
```

## 現時点の原因仮説

主因は以下の複合と考える。

1. 起動後に CPU/GPU が `performance` 寄りの電源状態へ戻っていた
2. その結果、低負荷でも CPU/GPU 温度が 65〜75℃付近まで上がった
3. BIOS のファンカーブ上、65℃前後が Medium 領域の境目になっている可能性があり、ファンが落ち切らなかった
4. BIOS 作業用に接続した HDMI が iGPU 温度を上げ、ファン音が継続する要因になった
5. USB 無線キーボードドングルは主因とは限らないが、USB 割り込みや省電力阻害の可能性は残る

過去の「BIOS リセット疑い」と完全に同じとは断定しない。
今回観測した範囲では、OS 起動後の CPU/GPU power profile が `performance` 寄りに戻ることが、少なくとも大きく効いている。

## 永続化対応

再起動後も同じ省電力設定を適用するため、Ansible role と systemd oneshot service で永続化した。

永続化する設定:

- CPU governor: `powersave`
- CPU EPP: `balance_power`
- amdgpu `power_dpm_force_performance_level`: `auto`
- amdgpu `power_dpm_state`: `balanced`

repo 側の管理ファイル:

```text
ansible/roles/proxmox_power_profile/
ansible/host_vars/pve01.yaml
ansible/inventory.yaml
ansible/site.yaml
```

実機に配置されるファイル:

```text
/usr/local/sbin/pve-power-profile
/etc/systemd/system/pve-power-profile.service
```

systemd unit は `Before=pve-guests.service` を指定し、Proxmox の VM 自動起動より前に省電力設定を適用する。
ただし、これは起動順序の指定であり、`pve-power-profile.service` が失敗した場合に VM 起動を強制停止する設計ではない。
今回の用途では、静音設定失敗を理由に VM 起動まで止めるのは強すぎるため、`systemctl failed` や journal で検知する方針とした。

実装上の安全側の挙動:

- `pve01` は `root` SSH 前提のため、Proxmox play では `become: false` とする
- `proxmox_power_profile_enabled: false` に戻した場合は、既存 service を stop/disable し、unit/script も削除する
- boot 中の sysfs 出現遅延に備え、CPU cpufreq/EPP と amdgpu パスを短時間待つ
- sysfs 書き込み後は read-back し、期待対象が 1 件も適用できない場合や書き込み失敗がある場合は systemd unit を失敗扱いにする
- check mode では未作成 unit に対する systemd 操作で dry-run が失敗しないよう、enable/start は debug 表示に留める

### 適用結果

適用前に dry-run を実行し、差分が想定通りであることを確認した。
その後、`pve01` に適用した。

```bash
cd ansible
ansible-playbook site.yaml --limit pve01 --check --diff
ansible-playbook site.yaml --limit pve01 --diff
```

適用結果:

```text
service_enabled = enabled
service_active = active
CPU governor = powersave x 16
CPU EPP = balance_power x 16
amdgpu power_dpm_force_performance_level = auto
amdgpu power_dpm_state = balanced
```

再実行による冪等性確認:

```text
ansible-playbook site.yaml --limit pve01
changed=0
```

適用直後の参考温度:

```text
CPU Tctl: 68.5℃
GPU edge: 68.0℃
NVMe Composite: 44.85℃
```

## 残タスク・今後の対応候補

### 1. 再起動後の永続化確認

次回メンテナンス時など、都合のよいタイミングで `pve01` を再起動し、起動後も以下になっていることを確認する。

```text
CPU governor = powersave
CPU EPP = balance_power
amdgpu power_dpm_force_performance_level = auto
amdgpu power_dpm_state = balanced
pve-power-profile.service = enabled / active (exited)
```

### 2. USB ドングル単体の切り分け

静かな状態をベースラインにして、USB 無線キーボードドングルだけ挿し、5分程度温度・負荷を見る。

### 3. BIOS Fan Control の静音寄り調整

OS 側省電力化後もファン音が気になる場合のみ、Fan Control の閾値をやや上げる。

例:

```text
Low Temperature = 55
Medium Temperature = 75
High Temperature = 85
Critical Temperature = 95
Low PWM = 20
Medium PWM = 30
High PWM = 60
Temperature Hysteresis = 3〜5
Fan Polarity = Positive
```

### 4. CMOS バッテリー確認

過去に BIOS 設定リセット疑いがあるため、再発する場合は CMOS バッテリー弱化も疑う。
BIOS 時刻ずれが出る場合は特に要注意。

## 参考コマンド

温度確認:

```bash
for d in /sys/class/hwmon/hwmon*; do
  echo "-- $(cat $d/name 2>/dev/null) ($d) --"
  for f in "$d"/temp*_label "$d"/temp*_input "$d"/fan*_input "$d"/pwm* "$d"/freq*_input "$d"/power*_input; do
    [ -e "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
  done
done
```

CPU governor / EPP:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c
cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort | uniq -c
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_available_preferences
```

amdgpu:

```bash
gpu=/sys/bus/pci/drivers/amdgpu/0000:05:00.0
cat "$gpu/power_dpm_state"
cat "$gpu/power_dpm_force_performance_level"
cat "$gpu/gpu_busy_percent"
```

ディスプレイ接続状態:

```bash
for c in /sys/class/drm/card*-*; do
  [ -e "$c/status" ] && echo "$(basename $c) status=$(cat $c/status)"
done
```
