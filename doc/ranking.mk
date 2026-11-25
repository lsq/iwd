# DeepWiki Q&A with Code Context for Repository: lsq/iwd
## Q1
[怎么配置iwd使用wifi的优先级](https://deepwiki.com/search/78110d33-e512-41ea-9ac7-cc78afc3b768)
### Answer
User asks in Chinese: how to configure iwd WiFi priority. Search codebase for priority/rank settings.Check per-network config options like AutoConnect, and known network ordering (connected_time). Check iwd.network.rst for per-network settings.I have enough. Answer in Chinese: iwd doesn't have explicit per-network priority; autoconnect order is by last connected time (connected_time in known network files), plus [Rank] band modifiers in main.conf, and per-network AutoConnect=false to exclude. Also RoutePriorityOffset is for routes, not WiFi selection.iwd 没有提供"显式指定某个 SSID 优先级"的配置项。自动连接的顺序由内部的 rank 机制决定，你能控制的手段有以下几种：

## 1. 按"最近连接时间"排序（默认行为）

iwd 把已知网络按 `LastConnectedTime` 排序，最近连接过的网络在 autoconnect 列表中排名最高（通过 `util_exponential_decay` 衰减）。所以想提高某个网络的优先级，最简单的方法就是手动连接它一次，它就会变成"最近使用"的网络。 iwd:199-224 iwd:1996-2004 

排序依据存储在 `/var/lib/iwd/<ssid>.psk` 等网络配置文件的 `LastConnectedTime` 字段中，也可以手动编辑该时间戳来调整顺序。

## 2. 禁止低优先级网络自动连接

在每个网络的配置文件（`/var/lib/iwd/` 下）中设置：

```ini
[Settings]
AutoConnect=false
```

这样该网络不会参与自动连接，相当于把其他网络的优先级提高。 iwd:122-125 

## 3. 按频段调整偏好（全局）

在 `/etc/iwd/main.conf` 的 `[Rank]` 组中调整频段权重：

```ini
[Rank]
BandModifier5GHz=2.0
BandModifier2_4GHz=0.5
```

- `BandModifier2_4GHz` / `BandModifier5GHz` / `BandModifier6GHz`：浮点数，默认 1.0，设为 0.0 可完全禁用该频段
- `HighUtilizationThreshold` / `HighStationCountThreshold`：实验性选项，AP 负载/站点数超过阈值时降低其 rank iwd:324-387 

这些 modifier 作用于 BSS 的 rank 计算（`scan_bss_compute_rank`），影响同一网络内选哪个 AP，以及不同网络间的相对比较。 iwd:1775-1784 

## 注意

- `[Network].RoutePriorityOffset` 是路由 metric 的偏移，与 WiFi 网络选择优先级无关。 iwd:266-272 
- rank 计算还会考虑信号强度、加密类型（RSNE > WPA > Open）等因素，见 `network_rank_update`。 iwd:1961-2019 

总结：想"优先连 A 而不是 B"，实际做法是确保 A 的 `LastConnectedTime` 更新（连一次即可），或对 B 设置 `AutoConnect=false`。
### Citations
**File:** src/knownnetworks.c (L199-224)
```c
/*
 * Finds the position n of this network_info in the list of known networks
 * sorted by connected_time.  E.g. an offset of 0 means the most recently
 * used network.  Only networks with seen_count > 0 are considered.  E.g.
 * only networks that appear in scan results on at least one wifi card.
 *
 * Returns -ENOENT if the entry couldn't be found.
 */
int known_network_offset(const struct network_info *target)
{
	const struct l_queue_entry *entry;
	const struct network_info *info;
	int n = 0;

	for (entry = l_queue_get_entries(known_networks); entry;
						entry = entry->next) {
		info = entry->data;
		if (target == info)
			return n;

		if (info->seen_count)
			n += 1;
	}

	return -ENOENT;
}
```
**File:** src/network.c (L1961-2019)
```c
void network_rank_update(struct network *network, bool connected)
{
	static const double RANK_RSNE_FACTOR = 1.2;
	static const double RANK_WPA_FACTOR = 1.0;
	static const double RANK_OPEN_FACTOR = 0.5;
	static const double RANK_NO_PRIVACY_FACTOR = 0.5;
	/*
	 * Theoretically there may be difference between the BSS selection
	 * here and in network_bss_select but those should be rare cases.
	 */
	struct scan_bss *best_bss = l_queue_peek_head(network->bss_list);
	struct network_info *info = network->info;

	/*
	 * The rank should separate networks into four groups that use
	 * non-overlapping ranges for:
	 *   - current connected network,
	 *   - other networks we've connected to before,
	 *   - networks with preprovisioned settings file that we haven't
	 *     used yet,
	 *   - other networks.
	 *
	 * Within the 2nd group the last connection time is the main factor,
	 * for the other two groups it's the BSS rank - mainly signal strength.
	 */
	if (connected) {
		network->rank = INT_MAX;
		return;
	}

	if (!info) { /* Not known, assign negative rank */
		network->rank = (int) best_bss->rank - USHRT_MAX;
		return;
	}

	if (info->config.connected_time != 0) {
		int n = known_network_offset(info);

		L_WARN_ON(n < 0);

		network->rank =
			util_exponential_decay(n) * best_bss->rank + USHRT_MAX;
	} else
		network->rank = best_bss->rank;

	/*
	 * Prefer RSNE first, WPA second.  Open networks are much less
	 * desirable.
	 */
	if (best_bss->rsne)
		network->rank *= RANK_RSNE_FACTOR;
	else if (best_bss->wpa)
		network->rank *= RANK_WPA_FACTOR;
	else
		network->rank *= RANK_OPEN_FACTOR;

	/* We prefer networks with CAP PRIVACY */
	if (!(best_bss->capability & IE_BSS_CAP_PRIVACY))
		network->rank *= RANK_NO_PRIVACY_FACTOR;
```
**File:** src/iwd.network.rst (L122-125)
```text
   * - AutoConnect
     - Values: **true**, false

       Whether the network can be connected to automatically
```
**File:** src/iwd.config.rst (L266-272)
```text
   * - RoutePriorityOffset
     - Values: uint32 value (default: **300**)

       Configures a route priority offset used by the system to prioritize
       the default routes. The route with lower priority offset is preferred.

       If not specified, ``300`` is used as default.
```
**File:** src/iwd.config.rst (L324-387)
```text
Rank
----

The group ``[Rank]`` contains settings related to ranking of networks for
autoconnect purposes.

.. list-table::
   :header-rows: 0
   :stub-columns: 0
   :widths: 20 80
   :align: left

   * - BandModifier2_4GHz
     - Values: floating point value (default: **1.0**)

       Increase or decrease the preference for 2.4GHz access points by
       increasing or decreasing the value of this modifier.

       A value of 0.0 will disable the 2.4GHz band and prevent scanning or
       connecting on those frequencies.

   * - BandModifier5GHz
     - Values: floating point value (default: **1.0**)

       Increase or decrease the preference for 5GHz access points by increasing
       or decreasing the value of this modifier.  5GHz networks are already
       preferred due to their increase throughput / data rate.  However, 5GHz
       networks are highly RSSI sensitive, so it is still possible for IWD to
       prefer 2.4GHz APs in certain circumstances.

       A value of 0.0 will disable the 5GHz band and prevent scanning or
       connecting on those frequencies.

   * - BandModifier6GHz
     - Values: floating point value (default: **1.0**)

       Increase or decrease the preference for 6GHz access points by increasing
       or decreasing the value of this modifier.  Since 6GHz networks are highly
       RSSI sensitive, this gives an option to prefer 6GHz APs over 5GHz APs.

       A value of 0.0 will disable the 6GHz band and prevent scanning or
       connecting on those frequencies.

   * - HighUtilizationThreshold
     - Values: unsigned integer value 0 - 255 (default: **0**, disabled)

       **Warning: This is an experimental feature**

       The BSS utilization threshold at which a negative rank factor begins to
       be applied to the BSS. As the load increases for a BSS the ranking factor
       decays exponentially, meaning the ranking factor will decrease
       exponentially. Setting this can have very drastic effects on the BSS rank
       if its utilization is high, use with care.

   * - HighStationCountThreshold
     - Values: unsigned integer value 0 - 255 (default: **0**, disabled)

       **Warning: This is an experimental feature**

       The BSS station count threshold at which a negative rank factor begins to
       be applied to the BSS. As the station count increases for a BSS the
       ranking factor decays exponentially, meaning the ranking factor will
       decrease exponentially. Setting this can have very drastic effects on the
       BSS rank if its station count is high, use with care.
```
**File:** src/scan.c (L1775-1784)
```c
	if (bss->frequency < 3000)
		rank *= RANK_2G_FACTOR;

	/* Prefer 5G networks over 2.4G and 6G */
	if (bss->frequency >= 4900 && bss->frequency < 5900)
		rank *= RANK_5G_FACTOR;

	/* Prefer 6G networks over 2.4G and 5G */
	if (bss->frequency >= 5900 && bss->frequency < 7200)
		rank *= RANK_6G_FACTOR;
```
## Q2
增加功能，配置文件中可以设置优先级参数，根据优先级参数顺序连接
### Answer
User wants to add a feature: a priority parameter in network config files, used to order autoconnect. I'm in ask-only mode but the instruction says when user wants implementation, include a <plan>. Wait — ask-only mode says do NOT create plans. But the "Creating plans (DISABLED)" section still describes plan format... The ask-only section says "Do NOT create plans or suggest implementation steps... explain what would need to be done conceptually, but do not output a <plan> section." So explain conceptually.

Need to look at relevant code: network_info config parsing (knownnetworks.c), network_rank_update, settings parsing. Let me search for where AutoConnect is parsed and where rank is used for autoconnect ordering.Need to look at knownnetworks.c parsing of settings (AutoConnect, connected_time), network_info struct in knownnetworks.h, and how autoconnect list is built in station.c. Read relevant sections.Need to see how autoconnect picks networks in station.c — likely sorts by network->rank. Grep for the autoconnect function.Need to see where autoconnect list is built in station.c — likely station_autoconnect_next or similar using network rank. Grep for the function that iterates networks sorted by rank.User wants to add a feature: a priority parameter in per-network config files, and autoconnect should follow priority order. I'm in ask-only mode — explain conceptually what needs to change, no <plan>. Answer in Chinese.

Key places:
- `struct network_config` in src/knownnetworks.h:75-85 — add `priority` field.
- `__network_config_parse` in src/knownnetworks.c:57-138 — parse e.g. `[Settings] Priority=N` via `l_settings_get_int`/`l_settings_get_uint`.
- Add `#define NET_PRIORITY SETTINGS, "Priority"` in knownnetworks.h.
- Ordering: `connected_time_compare` (knownnetworks.c:164-177) sorts known_networks list by connected_time; `known_network_offset` (207-224) computes position used by `network_rank_update` (network.c:1996-2004) and `network_rankmod` (network.c:220-240) via `util_exponential_decay(n)`. To honor priority, either sort the known_networks list by priority first then connected_time, or incorporate priority into rank computation in `network_rank_update`.
- Docs: src/iwd.network.rst add Priority under [Settings].
- Also hotspot.c uses network_config? hotspot.c lines 413,483-485 use connected_time — hotspot networks also use network_info; parsing is shared via __network_config_parse so it works automatically.
- D-Bus KnownNetwork interface could optionally expose property (doc/knownnetwork-api.txt) — optional.
- Caveat: rank also multiplies by security factors; priority should probably dominate — simplest: in network_rank_update, if info->config.priority set, add large offset or use priority tier before decay. Or modify connected_time_compare to compare priority first — that changes ordering everywhere including known_network_offset, which is the cleanest: networks with higher priority get lower n → higher rank. But note connected_time is also file mtime; sorting by priority first then time achieves "按优先级顺序连接".

Also mention where the list is sorted: need to check where connected_time_compare is used — likely l_queue_insert sorted in known_networks_add / known_network_set_connected_time (lines ~365, 442-448). I didn't read those lines but grep showed connected_time at 365, 442-448 — reasonable to say the comparator is used when inserting/re-sorting.

Write concise Chinese answer with file/line citations.这个功能的核心思路：在每个网络的 `[Settings]` 中新增一个 `Priority` 整数参数，让已知网络的排序（目前按 `connected_time`）改为先按 priority、再按连接时间。需要改动的位置如下：

## 1. 定义配置键和数据结构

`src/knownnetworks.h`：
- 新增 `#define NET_PRIORITY SETTINGS, "Priority"`（仿照第 27 行 `NET_AUTOCONNECT`）
- 在 `struct network_config` 中加一个字段，如 `int32_t priority`（默认 0） iwd:75-85 

## 2. 解析配置

`src/knownnetworks.c` 的 `__network_config_parse()` 是所有网络配置文件（`.psk`、`.8021x`、`.open`）共用的解析入口，在这里用 `l_settings_get_int()` 读取 `Priority`，未设置时默认 0。hotspot 网络也走这个解析路径，所以自动生效。 iwd:57-78 

## 3. 修改排序逻辑（关键）

自动连接的顺序由 `known_networks` 队列的顺序决定：

- `connected_time_compare()` 目前只按 `connected_time` 降序排列。改成先比较 `priority`（大的在前），priority 相等再比较 `connected_time`。 iwd:164-177 
- `known_network_offset()` 返回网络在该有序队列中的位置 `n`。 iwd:207-224 
- `network_rank_update()` 用 `util_exponential_decay(n)` 把位置换算成 rank 加成，`n` 越小 rank 越高。 iwd:1996-2004 
- `network_rankmod()` 同样依赖 `known_network_offset()`，漫游/BSS 选择也会受益。 iwd:220-240 

只要改了比较函数，整个 autoconnect 排序链就自动按优先级工作了——这是改动最小的方案。

## 4. 注意事项

- `connected_time` 取自文件 mtime（`l_path_get_mtime`），每次连接成功会 `touch` 文件刷新它。priority 排序放在 time 之前，可以避免"连一次就顶到最前"覆盖用户设定的优先级。 iwd:67-67 
- rank 计算中"已连接过的网络"这一组内部才用 offset 衰减；priority 只影响组内顺序，不会改变"当前连接 > 连过的 > 预置未连过的 > 未知"这四个大组的分层。 iwd:1961-1995 
- 需要确认 `known_networks` 队列所有插入/重排点都走 `connected_time_compare`（`known_networks_add`、`known_network_set_connected_time` 附近，约 365、442 行），改比较函数即可全覆盖。
- 文档同步：在 `src/iwd.network.rst` 的 `[Settings]` 表中加 `Priority` 条目（仿照 122 行 `AutoConnect` 的格式）。 iwd:122-125 
- 可选：在 D-Bus `net.connman.iwd.KnownNetwork` 接口暴露 `Priority` 属性（参考 `doc/knownnetwork-api.txt` 和 `known_network_set_autoconnect` 的 property changed 写法），这样 `iwctl` 也能显示/修改。 iwd:241-251 

一个未完全验证的点：`station.c` 中 autoconnect 挑选网络的具体函数我没有逐行读到，但它依赖 `network->rank` 排序，而 rank 由上述 `network_rank_update` 计算，所以改比较函数是正确的作用点；实现时建议在 `station.c` 中确认 autoconnect 遍历确实按 rank 降序取网络。
### Citations
**File:** src/knownnetworks.h (L75-85)
```text
struct network_config {
	uint64_t connected_time;	/* Time last connected */
	bool is_hidden:1;
	bool is_autoconnectable:1;
	bool override_addr:1;
	bool always_random_addr:1;
	uint8_t sta_addr[6];
	bool have_transition_disable : 1;
	uint8_t transition_disable;
	enum known_network_ecc_group ecc_group;
};
```
**File:** src/knownnetworks.c (L57-78)
```c
void __network_config_parse(const struct l_settings *settings,
					const char *full_path,
					struct network_config *config)
{
	bool b;
	const char *value;
	uint8_t new_addr[6];

	memset(config, 0, sizeof(struct network_config));

	config->connected_time = l_path_get_mtime(full_path);

	/* If no entry, default to AutoConnectable=True */
	if (!l_settings_get_bool(settings, NET_AUTOCONNECT, &b))
		b = true;

	config->is_autoconnectable = b;

	if (!l_settings_get_bool(settings, NET_HIDDEN, &b))
		b = false;

	config->is_hidden = b;
```
**File:** src/knownnetworks.c (L164-177)
```c
static int connected_time_compare(const void *a, const void *b, void *user_data)
{
	const struct network_info *ni_a = a;
	const struct network_info *ni_b = b;
	uint64_t ta = ni_a->config.connected_time;
	uint64_t tb = ni_b->config.connected_time;

	if (l_time_after(ta, tb))
		return -1;
	else if (l_time_before(ta, tb))
		return 1;

	return 0;
}
```
**File:** src/knownnetworks.c (L207-224)
```c
int known_network_offset(const struct network_info *target)
{
	const struct l_queue_entry *entry;
	const struct network_info *info;
	int n = 0;

	for (entry = l_queue_get_entries(known_networks); entry;
						entry = entry->next) {
		info = entry->data;
		if (target == info)
			return n;

		if (info->seen_count)
			n += 1;
	}

	return -ENOENT;
}
```
**File:** src/knownnetworks.c (L241-251)
```c
static void known_network_set_autoconnect(struct network_info *network,
							bool autoconnect)
{
	if (network->config.is_autoconnectable == autoconnect)
		return;

	network->config.is_autoconnectable = autoconnect;

	l_dbus_property_changed(dbus_get_bus(), known_network_get_path(network),
				IWD_KNOWN_NETWORK_INTERFACE, "AutoConnect");
}
```
**File:** src/network.c (L220-240)
```c
bool network_rankmod(const struct network *network, double *rankmod)
{
	struct network_info *info = network->info;
	int n;

	/*
	 * Current policy is that only networks successfully connected
	 * to at least once are autoconnectable.  Known Networks that
	 * we have never connected to are not.
	 */
	if (!info || !info->config.connected_time)
		return false;

	n = known_network_offset(network->info);
	if (n < 0)
		return false;

	*rankmod = util_exponential_decay(n);

	return true;
}
```
**File:** src/network.c (L1961-1995)
```c
void network_rank_update(struct network *network, bool connected)
{
	static const double RANK_RSNE_FACTOR = 1.2;
	static const double RANK_WPA_FACTOR = 1.0;
	static const double RANK_OPEN_FACTOR = 0.5;
	static const double RANK_NO_PRIVACY_FACTOR = 0.5;
	/*
	 * Theoretically there may be difference between the BSS selection
	 * here and in network_bss_select but those should be rare cases.
	 */
	struct scan_bss *best_bss = l_queue_peek_head(network->bss_list);
	struct network_info *info = network->info;

	/*
	 * The rank should separate networks into four groups that use
	 * non-overlapping ranges for:
	 *   - current connected network,
	 *   - other networks we've connected to before,
	 *   - networks with preprovisioned settings file that we haven't
	 *     used yet,
	 *   - other networks.
	 *
	 * Within the 2nd group the last connection time is the main factor,
	 * for the other two groups it's the BSS rank - mainly signal strength.
	 */
	if (connected) {
		network->rank = INT_MAX;
		return;
	}

	if (!info) { /* Not known, assign negative rank */
		network->rank = (int) best_bss->rank - USHRT_MAX;
		return;
	}

```
**File:** src/network.c (L1996-2004)
```c
	if (info->config.connected_time != 0) {
		int n = known_network_offset(info);

		L_WARN_ON(n < 0);

		network->rank =
			util_exponential_decay(n) * best_bss->rank + USHRT_MAX;
	} else
		network->rank = best_bss->rank;
```
**File:** src/iwd.network.rst (L122-125)
```text
   * - AutoConnect
     - Values: **true**, false

       Whether the network can be connected to automatically
```
## Q3
确认station.c 中 autoconnect 挑选网络的具体函数，按上面给出的方案实现(包括iwctl 也能显示/修改)，给出具体代码
### Answer
Need to find autoconnect function in station.c, knownnetworks.c relevant sections, iwctl known-networks display code, D-Bus knownnetwork api. Batch searches.Need to read: station.c autoconnect function (find which lines pick networks by rank), knownnetworks.c around 430-470, 730-860, client/known-networks.c, and D-Bus property table in knownnetworks.c. Batch reads.Need a few more pieces: knownnetworks.h defines (NET_AUTOCONNECT etc.), the D-Bus property getters/setters for autoconnect in knownnetworks.c (~lines 600-720), and how autoconnect_list is populated (station.c network_add_foreach uses network_rank_compare — confirmed). Also check where autoconnect_list is built (station.c around line 148?). And proxy_property_set / properties_builder for int variant in client/properties.c — need to know how to add an int property settable. Check client/properties.h/c for builder functions.I have enough. Need client/properties.h to know how to add a settable int property — check quickly? One iteration left; I can read properties.h and properties.c in parallel, plus check proxy_property_set signature. Then write final answer with code.Confirmed: station.c `station_autoconnect_next` pops from `autoconnect_list` sorted by `network_rank_compare` (network->rank), populated via `network_add_foreach`. Rank comes from `network_rank_update` using `known_network_offset` → `connected_time_compare` ordering. So changing the comparator to priority-first works.

Now write full implementation code in Chinese:

1. src/knownnetworks.h: add `#define NET_PRIORITY SETTINGS, "Priority"`, add `int32_t priority;` to network_config.
2. src/knownnetworks.c:
   - parse in `__network_config_parse`: `l_settings_get_int`? ELL has `l_settings_get_int`? ELL settings API: l_settings_get_int exists? ELL has l_settings_get_int (yes, ell/settings.h has l_settings_get_int returning bool with int*). I'll use it, fallback 0.
   - rename/modify `connected_time_compare` → compare priority first then connected_time. Keep name or rename to `known_network_compare`. I'll rename for clarity but keep minimal: modify function body.
   - `known_network_update`: handle priority change — need re-sort + property changed. Add `known_network_set_priority` similar to autoconnect setter: update config, re-insert queue, emit PropertiesChanged.
   - D-Bus: add "Priority" property "i" with get/set. Setter writes to settings file via `l_settings_set_int` (ELL has l_settings_set_int? ELL has l_settings_set_int — yes, ell settings has l_settings_set_int). Then ops->sync; the dir watch will re-parse and call known_network_update which re-sorts. Actually set_autoconnect relies on file watch to update config. For priority, same: write file, watch triggers update. But also update immediately? Follow autoconnect pattern: just write settings + sync; watch callback handles the rest. But to be safe, also re-sort in known_network_update when priority changes.
3. client/known-networks.c: add `int32_t priority` field, update_priority, get_priority_tostr, property entry { "Priority", "i", update_priority, get_priority_tostr, true, builder_append_int_variant, NULL }. Need a builder for int — properties.c only has on_off/yes_no. Add `properties_builder_append_int_variant` in client/properties.c/h. proxy_property_set signature: (proxy, name, value_str, callback) — uses property's settable flag and builder. I didn't read dbus-proxy.h fully but the property table entry format is {name, type, update, getstr, settable, builder, opts}. I'll add int builder.
4. Docs: iwd.network.rst add Priority row; doc/knownnetwork-api.txt mention (didn't read it, note it).

Also note: `known_network_offset` counts only seen networks — unchanged.

Write the code concisely.已确认 autoconnect 选路路径：`station_autoconnect_next()` 从 `station->autoconnect_list` 按序弹出网络，该列表由 `network_add_foreach()` 用 `network_rank_compare`（即 `network->rank`）排序插入 iwd:312-340 。而 `network->rank` 由 `network_rank_update()` 通过 `known_network_offset()` 计算，offset 取决于 `known_networks` 队列顺序，该队列由 `connected_time_compare` 排序 iwd:164-177 。所以**只需让比较函数先按 priority 排序**，整条链路即生效。以下是完整实现。

## 1. `src/knownnetworks.h`

```c
/* 第 27 行后新增 */
#define NET_PRIORITY SETTINGS, "Priority"
```

```c
struct network_config {
	uint64_t connected_time;	/* Time last connected */
	int32_t priority;		/* Autoconnect priority, higher = preferred */
	bool is_hidden:1;
	bool is_autoconnectable:1;
	...
};
```

## 2. `src/knownnetworks.c`

**解析**（`__network_config_parse`，约第 73 行后）：

```c
	if (!l_settings_get_int(settings, NET_PRIORITY, &i))
		i = 0;

	config->priority = i;
```

（函数顶部加 `int i;` 声明）

**排序比较函数**（替换 `connected_time_compare`，164-177 行）：

```c
static int known_network_compare(const void *a, const void *b, void *user_data)
{
	const struct network_info *ni_a = a;
	const struct network_info *ni_b = b;
	uint64_t ta = ni_a->config.connected_time;
	uint64_t tb = ni_b->config.connected_time;

	/* Higher priority sorts first */
	if (ni_a->config.priority != ni_b->config.priority)
		return ni_b->config.priority - ni_a->config.priority;

	if (l_time_after(ta, tb))
		return -1;
	else if (l_time_before(ta, tb))
		return 1;

	return 0;
}
```

把 `known_networks_add`（774 行）和 `known_network_set_connected_time`（456 行）中的 `connected_time_compare` 全部替换为 `known_network_compare`。

**新增 priority setter**（仿照 `known_network_set_autoconnect`，241-251 行）：

```c
static void known_network_set_priority(struct network_info *network,
						int32_t priority)
{
	if (network->config.priority == priority)
		return;

	network->config.priority = priority;

	l_queue_remove(known_networks, network);
	l_queue_insert(known_networks, network, known_network_compare, NULL);

	l_dbus_property_changed(dbus_get_bus(), known_network_get_path(network),
				IWD_KNOWN_NETWORK_INTERFACE, "Priority");
}
```

**`known_network_update`**（459 行起）末尾加：

```c
	known_network_set_priority(network, new->priority);
```

**D-Bus 属性**（在 `known_network_property_set_autoconnect` 后新增）：

```c
static bool known_network_property_get_priority(struct l_dbus *dbus,
					struct l_dbus_message *message,
					struct l_dbus_message_builder *builder,
					void *user_data)
{
	struct network_info *network = user_data;
	int32_t priority = network->config.priority;

	l_dbus_message_builder_append_basic(builder, 'i', &priority);

	return true;
}

static struct l_dbus_message *known_network_property_set_priority(
					struct l_dbus *dbus,
					struct l_dbus_message *message,
					struct l_dbus_message_iter *new_value,
					l_dbus_property_complete_cb_t complete,
					void *user_data)
{
	struct network_info *network = user_data;
	struct l_settings *settings;
	int32_t priority;

	if (!l_dbus_message_iter_get_variant(new_value, "i", &priority))
		return dbus_error_invalid_args(message);

	if (network->config.priority == priority)
		return l_dbus_message_new_method_return(message);

	settings = network->ops->open(network);
	if (!settings)
		return dbus_error_failed(message);

	l_settings_set_int(settings, NET_PRIORITY, priority);

	network->ops->sync(network, settings);
	l_settings_free(settings);

	/* 文件 watch 会触发 known_network_update 完成重排，
	 * 但立即更新可保证 D-Bus 客户端马上看到一致状态 */
	known_network_set_priority(network, priority);

	return l_dbus_message_new_method_return(message);
}
```

**注册属性**（`setup_known_network_interface`，740-745 行后）：

```c
	l_dbus_interface_property(interface, "Priority", 0, "i",
					known_network_property_get_priority,
					known_network_property_set_priority);
```

## 3. `client/properties.c` / `properties.h`（iwctl 需要 int 类型的 setter builder）

```c
bool properties_builder_append_int_variant(
					struct l_dbus_message_builder *builder,
					const char *value_str)
{
	int32_t value;
	char *end;

	if (!builder || !value_str)
		return false;

	errno = 0;
	value = strtol(value_str, &end, 10);
	if (errno || *end != '\0')
		return false;

	return l_dbus_message_builder_append_basic(builder, 'i', &value);
}
```

`properties.h` 加对应声明（需 `#include <errno.h>`、`<stdlib.h>` 于 properties.c）。

## 4. `client/known-networks.c`

```c
struct known_network {
	...
	bool autoconnect;
	int32_t priority;
};
```

```c
static void update_priority(void *data, struct l_dbus_message_iter *variant)
{
	struct known_network *network = data;
	int32_t value;

	if (!l_dbus_message_iter_get_variant(variant, "i", &value)) {
		network->priority = 0;
		return;
	}

	network->priority = value;
}

static const char *get_priority_tostr(const void *data)
{
	const struct known_network *network = data;
	static char buf[12];

	snprintf(buf, sizeof(buf), "%d", network->priority);

	return buf;
}
```

属性表（163-172 行）加一行：

```c
	{ "Priority",          "i", update_priority, get_priority_tostr,
		true, properties_builder_append_int_variant },
```

这样 `iwctl known-networks <ssid> show` 会显示 Priority，`iwctl known-networks <ssid> set-property Priority 10` 可修改。

## 5. 文档

`src/iwd.network.rst` 的 `[Settings]` 表（122 行 `AutoConnect` 后）加：

```rst
   * - Priority
     - Values: signed integer (default: **0**)

       Autoconnect priority.  Known networks with a higher priority are
       preferred for autoconnect.  Networks with equal priority are
       ordered by last connected time.
```

`doc/knownnetwork-api.txt` 中 `net.connman.iwd.KnownNetwork` 接口也应补充 `Priority` 属性说明（该文件我未读取，按现有 `AutoConnect` 属性的格式仿写即可）。

## 效果说明

- `Priority` 大的网络在 `known_networks` 队列中靠前 → `known_network_offset` 返回更小的 `n` → `util_exponential_decay(n)` 衰减更少 → `network->rank` 更高 → `station_autoconnect_next` 优先尝试。
- 同优先级时仍按 `LastConnectedTime` 排序，完全向后兼容（默认 0 时行为与现在一致）。
- 注意 priority 只影响"已连接过的网络"组内排序；`network_rank_update` 中"当前连接 > 连过的 > 未连过的 > 未知"四个大组的分层不变 iwd:1974-1984 。若希望 priority 能跨组生效（例如让从未连过但预置了 priority 的网络排在已连过的之前），则需要在 `network_rank_update` 中额外加 `priority` 偏移量，而不是只改比较函数——这一点取决于你的需求语义。
### Citations
**File:** src/station.c (L312-340)
```c
static void network_add_foreach(struct network *network, void *user_data)
{
	struct station *station = user_data;

	l_queue_insert(station->autoconnect_list, network,
				network_rank_compare, NULL);
}

static int station_autoconnect_next(struct station *station)
{
	struct network *network;
	int r;

	if (!station->autoconnect_list)
		return -ENOENT;

	while ((network = l_queue_pop_head(station->autoconnect_list))) {
		const char *ssid = network_get_ssid(network);
		struct scan_bss *bss = network_bss_select(network, false);

		l_debug("autoconnect: Trying SSID: %s", ssid);

		if (!bss) {
			l_debug("autoconnect: No suitable BSSes found");
			continue;
		}

		l_debug("autoconnect: '%s' freq: %u, rank: %u, strength: %i",
			util_address_to_string(bss->addr),
```
**File:** src/knownnetworks.c (L164-177)
```c
static int connected_time_compare(const void *a, const void *b, void *user_data)
{
	const struct network_info *ni_a = a;
	const struct network_info *ni_b = b;
	uint64_t ta = ni_a->config.connected_time;
	uint64_t tb = ni_b->config.connected_time;

	if (l_time_after(ta, tb))
		return -1;
	else if (l_time_before(ta, tb))
		return 1;

	return 0;
}
```
**File:** src/network.c (L1974-1984)
```c
	/*
	 * The rank should separate networks into four groups that use
	 * non-overlapping ranges for:
	 *   - current connected network,
	 *   - other networks we've connected to before,
	 *   - networks with preprovisioned settings file that we haven't
	 *     used yet,
	 *   - other networks.
	 *
	 * Within the 2nd group the last connection time is the main factor,
	 * for the other two groups it's the BSS rank - mainly signal strength.
```
## Q4
.psk中设置了
[Settings]
 Priority=20
重启iwd为什么还是不生效
### Answer
User set Priority=20 in .psk but it doesn't take effect after restart. Possible reasons: the feature isn't implemented yet (they asked for code but maybe applied it), or parsing issue — l_settings_get_int signature, or the file in /var/lib/iwd vs /etc/iwd? Actually iwd reads network files from /var/lib/iwd (state dir). If user edited a file elsewhere it won't load. Also leading space " Priority=20" — settings parser may handle whitespace fine. Another key issue: priority only affects ordering among networks that have connected_time != 0 (seen/connected before). If the network was never connected, connected_time is mtime... actually connected_time = file mtime, nonzero. Hmm.

Also important: known_network_offset only counts networks with seen_count > 0 — networks visible in scan results. If the target network isn't in scan results, ordering doesn't matter.

Also rank grouping: networks with connected_time != 0 get rank = decay(n)*bss_rank + USHRT_MAX. Priority changes n. But if another network has much stronger signal, bss_rank factor could still matter? rank = decay(n)*best_bss->rank + USHRT_MAX — decay(0)=1, decay(1)=0.5... so priority 20 puts it at n=0 → rank = bss_rank + USHRT_MAX, vs other at n=1 → 0.5*bss_rank + USHRT_MAX. Should win.

Most likely causes: (1) code not actually rebuilt/installed, (2) edited wrong file location — must be /var/lib/iwd/<ssid>.psk, (3) iwd caches? On restart it re-reads. (4) The network must have been connected before (autoconnectable requires connected_time). (5) Also check: does the parse code actually run — did they add l_settings_get_int correctly; ELL's l_settings_get_int signature is (settings, group, key, &out)? Actually ELL: l_settings_get_int(settings, group_name, key, &value) — but NET_PRIORITY is defined as SETTINGS, "Priority" which expands to two args — fine.

Also possible: whitespace before "Priority" — "[Settings]\n Priority=20" leading space is fine for ELL parser probably.

Another subtlety: iwd may overwrite the file on sync, dropping unknown keys? iwd writes settings files on connect — it may rewrite and drop Priority if not handled. But after restart parse should still read it if present.

Also: did they restart iwd but the network was already connected? rank INT_MAX for connected.

I should give debugging checklist concisely. Maybe verify with grep whether l_settings_get_int exists in ELL used. Can't check ELL repo (only lsq/iwd). Provide checklist.几个最可能的原因，按概率排查：

## 1. 改的文件位置不对（最常见）

iwd 只读取 state 目录下的网络文件，即 `/var/lib/iwd/`（或编译时 `--localstatedir` 指定的路径）。如果你改的是 `/etc/iwd/` 下的文件或自己保存的副本，iwd 根本不会加载它。确认：

```
ls /var/lib/iwd/*.psk
grep -A2 '\[Settings\]' /var/lib/iwd/<ssid>.psk
```

## 2. 代码没有真正生效

- 确认改动已重新编译并安装到系统实际使用的路径（`which iwd` / `systemctl status iwd` 看 ExecStart 路径），发行版包管理器的 iwd 不会包含你的修改。
- 确认 `__network_config_parse` 里的解析代码在 `memset(config, 0, ...)` 之后执行，且 `l_settings_get_int` 的返回值判断正确（未设置时给默认 0）。
- 确认 `connected_time_compare` 的所有调用点都换成了新的比较函数（`known_networks_add`、`known_network_set_connected_time` 两处）。

## 3. 该网络不在 autoconnect 候选中

priority 只影响 `known_networks` 队列的排序，而 `known_network_offset` 只统计 `seen_count > 0` 的网络——即**必须出现在扫描结果里**的网络才参与排序 iwd:207-224 。如果目标 AP 当前扫描不到（信号弱、频段不对、隐藏网络未配置 `Hidden=true`），priority 再高也不会被选中。

另外 autoconnect 要求 `AutoConnect` 为 true 且网络之前成功连接过（`connected_time != 0`） iwd:220-240 。

## 4. 已经连着别的网络

当前已连接的网络 rank 是 `INT_MAX`，priority 不会触发主动切换——它只影响断开后的 autoconnect 顺序 iwd:1986-1989 。需要先 `iwctl station wlan0 disconnect` 再观察。

## 5. iwd 重写文件把 Priority 丢了

iwd 连接成功后会 sync 网络文件。如果你的实现没有在 `network->ops->sync` 路径里保留 `Priority` 键，文件被重写后该配置会消失。重启前再 `cat` 一下文件确认 `Priority=20` 还在。

## 调试方法

开 debug 日志看实际排序：

```
iwd -d
```

或在 `known_network_compare` / `network_rank_update` 里加 `l_debug("ssid=%s priority=%d n=%d rank=%d", ...)`，重启后看该网络的 priority 是否被解析为 20、offset `n` 是否为 0。如果 priority 解析出来是 0，说明是解析层问题（文件路径/键名/代码未生效）；如果解析正确但 `n` 不是 0，说明有更高 priority 或同级但 `connected_time` 更新的网络排在前面。
### Citations
**File:** src/knownnetworks.c (L207-224)
```c
int known_network_offset(const struct network_info *target)
{
	const struct l_queue_entry *entry;
	const struct network_info *info;
	int n = 0;

	for (entry = l_queue_get_entries(known_networks); entry;
						entry = entry->next) {
		info = entry->data;
		if (target == info)
			return n;

		if (info->seen_count)
			n += 1;
	}

	return -ENOENT;
}
```
**File:** src/network.c (L220-240)
```c
bool network_rankmod(const struct network *network, double *rankmod)
{
	struct network_info *info = network->info;
	int n;

	/*
	 * Current policy is that only networks successfully connected
	 * to at least once are autoconnectable.  Known Networks that
	 * we have never connected to are not.
	 */
	if (!info || !info->config.connected_time)
		return false;

	n = known_network_offset(network->info);
	if (n < 0)
		return false;

	*rankmod = util_exponential_decay(n);

	return true;
}
```
**File:** src/network.c (L1986-1989)
```c
	if (connected) {
		network->rank = INT_MAX;
		return;
	}
```
## Q5
有一个问题：
在开机时，有三个无线网线信号强度由高到低依次为wifi A, 
确认network_rank_update逻辑
### Answer
User's message is truncated: "有三个无线网线信号强度由高到低依次为wifi A," — incomplete. They ask to confirm network_rank_update logic. Read network.c rank update and related code.Read util.c exponential decay and scan.c rank computation to explain fully.User's message was truncated but asks to confirm network_rank_update logic. Explain the logic clearly with the boot scenario: three networks A, B, C with signal strength descending. Explain rank computation and how priority interacts.`network_rank_update` 的完整逻辑如下（`src/network.c:1961-2020`）：

## 分层结构

rank 把网络分成四个不重叠的区间，从高到低：

| 组 | 条件 | rank 范围 |
|---|---|---|
| 1. 当前已连接 | `connected=true` | `INT_MAX` |
| 2. 以前连过的已知网络 | `info && connected_time != 0` | `decay(n) * bss_rank + USHRT_MAX`，再乘安全因子 |
| 3. 有配置文件但没连过 | `info && connected_time == 0` | `bss_rank`，再乘安全因子 |
| 4. 未知网络 | `!info` | `bss_rank - USHRT_MAX`（负数） |

## 第 2 组内部（autoconnect 的主战场）

```c
network->rank = util_exponential_decay(n) * best_bss->rank + USHRT_MAX;
```

- `n = known_network_offset(info)`：该网络在 `known_networks` 有序队列中的位置（只数 `seen_count > 0` 的，即扫描可见的）。`n=0` 表示队首。
- `util_exponential_decay(n)` 查表 `rankmod_table`：`n=0 → 1.0`，`n=1 → ~0.96` 左右递减，最低约 0.287（`src/util.c:660`）。
- `best_bss->rank`：该网络最强 BSS 的 rank，由 `scan_bss_compute_rank` 算出，主要正比于 `data_rate`（间接反映信号强度/频段），再乘 2.4G/5G/6G 频段因子、负载因子、SNR 因子（`src/scan.c:1762-1800`）。
- 最后乘安全因子：RSNE ×1.2，WPA ×1.0，Open ×0.5；无加密再 ×0.5。

## 对应到你的场景（开机，A/B/C 信号强度递减，假设都连过）

- 三者都在第 2 组，rank = `decay(n) * bss_rank + USHRT_MAX`。
- `n` 由 `known_networks` 队列顺序决定——原版按 `connected_time`，加了 Priority 补丁后按 priority 再按 time。
- **关键点**：`decay(n)` 是乘在 `bss_rank` 上的。`n=0` 时系数 1.0，`n=1` 约 0.96，`n=2` 约 0.93……衰减很平缓。所以如果 A 信号远强于 B，即使 B 的 `n=0`、A 的 `n=1`，A 的 `decay(1)*bss_rank_A` 仍可能大于 B 的 `decay(0)*bss_rank_B`——**priority/排序只能在小差距时翻盘，信号差距大时压不过去**。

举例：`bss_rank` 满量程 65535。A 信号很强 `bss_rank=60000`，B 较弱 `bss_rank=30000`：
- B 排第一（n=0）：`1.0 * 30000 + 65535 = 95535`
- A 排第二（n=1）：`~0.96 * 60000 + 65535 ≈ 123135` → A 仍然赢。

## 如果你希望 priority 能绝对压制信号差异

只改 `connected_time_compare` 的排序是不够的，需要在 `network_rank_update` 里让 priority 直接决定组内分层，例如：

```c
if (info->config.connected_time != 0) {
	int n = known_network_offset(info);

	network->rank =
		util_exponential_decay(n) * best_bss->rank + USHRT_MAX;

	/* priority 大的网络直接抬高一个量级，压过 bss_rank 差异 */
	if (info->config.priority > 0)
		network->rank += info->config.priority * USHRT_MAX;
}
```

或者更严格地"按 priority 顺序连接"：把 priority 映射为组内层级，使 priority 高的网络 rank 恒高于 priority 低的（用 `priority * USHRT_MAX` 作为区间基数，bss_rank 只做同优先级内的 tie-break）。这样 A/B/C 的连接顺序就完全由 Priority 决定，与信号强度无关（只要 BSS 可用）。

你的消息似乎没发完整（"依次为wifi A,"后面断了）——如果场景是"A 信号最强但想优先连 B/C"，那结论就是：**当前方案下信号差距会盖过 priority，需要按上面的方式把 priority 提升为区间基数才能严格按优先级连接**。
## Q6
很好，加一个配置开头，决定严格地"按 priority 顺序连接"还是按信号强度，按priority时忽略信号强度
### Answer
User wants a global config switch (in main.conf) deciding strict priority ordering vs signal-strength-based. Need to check how main.conf settings are parsed (iwd_config.c / l_settings_get_*), where global settings live, and how network.c accesses them. Search for config parsing.Need to see how main.conf is loaded — main.c around 418, 554-572; scan.c 2588-2681 for BandModifier parsing pattern; network.c 192/342/353 for how it accesses global settings.I have enough. Global config accessed via `iwd_get_config()` returning `struct l_settings *` (iwd_config in main.c). Pattern: read in module init or lazily via iwd_get_config. For network.c, simplest: read `[Rank] StrictPriority` bool in network_rank_update via iwd_get_config(), or cache in a static. Check iwd_get_config declaration — it's in iwd.h presumably; network.c already includes it? network.c uses l_settings_get at 523 etc. Fine.

Design: add `[Rank] UsePriorityOrder=true` (name e.g. `StrictPriorityOrder`). When true, in network_rank_update group 2: rank = priority * USHRT_MAX + decay-ish tiebreak? Requirement: "按priority时忽略信号强度" — strict ordering by priority. Implement:

```c
if (strict_priority && info->config.priority != 0)
    network->rank = info->config.priority * USHRT_MAX + best_bss->rank;
```

But careful: group separation — group 2 base is +USHRT_MAX. priority*USHRT_MAX could overflow int for large priority; clamp. Also networks with priority 0 should fall back to normal behavior or lowest? Simplest: when strict mode on, rank = USHRT_MAX + priority * USHRT_MAX? That overflows. Use double then clamp to INT_MAX-1.

Better: keep within group 2 range: rank = USHRT_MAX + priority-scaled. Since rank is int, use:

```c
double r = (double) info->config.priority * USHRT_MAX + best_bss->rank;
network->rank = r > INT_MAX - USHRT_MAX ? INT_MAX - 1 : (int) r + USHRT_MAX;
```

Hmm, simpler: rank = USHRT_MAX + (priority clamped) * something. Actually to strictly order by priority ignoring signal: rank = USHRT_MAX * (priority + 1) + bss_rank? For priority up to ~32767 fits int. Clamp priority to e.g. 0-255 in parsing. Then rank = USHRT_MAX + priority * (USHRT_MAX + 1) + bss_rank — for priority 255: 255*65536 ≈ 16.7M, fine under INT_MAX.

But negative priorities? Clamp to >=0 in strict mode, or treat negative as lowest. Keep simple: clamp priority to [-32768..] — just document priority range 0-255, clamp in parse.

Also tie-break: same priority → still want connected_time ordering? "忽略信号强度" — use n decay? If ignoring signal entirely, same priority ties broken by queue order (connected_time). Could do rank = base + decay(n)*something small. Simplest: rank = USHRT_MAX + priority*(USHRT_MAX+1) + (int)(util_exponential_decay(n) * USHRT_MAX)? That keeps time ordering within same priority and ignores signal. But user may want signal as tiebreak within same priority — earlier they said "按priority时忽略信号强度". I'll use decay(n) as tiebreak (keeps recency ordering, no signal). Or offer bss_rank as tiebreak — but that reintroduces signal. Use decay(n).

Also need to apply in network_rankmod? That returns rankmod for BSS selection within network — not needed.

Where to read config: add static bool in network.c, read in network_init? Check network.c has an init function — likely `network_init` IWD_MODULE. I didn't verify; grep showed network.c:192 etc. I'll instruct to read in module init or lazily. Safer: read lazily each call via iwd_get_config() like scan_get_band_rank_modifier does — cheap enough? network_rank_update called per scan update; l_settings_get_bool is a hash lookup, fine. I'll do lazy read with static caching? Config doesn't change at runtime; read once in network_init (IWD_MODULE exists in network.c presumably). I'll present code reading in init function `network_init` — need to verify name. Quick grep? I have 2 iterations left; do one grep for IWD_MODULE in network.c plus check iwd_get_config decl.Read network.c around 2200-2245 for module init, and iwd.h:33 context quickly — one iteration left, batch both.Provide implementation: global switch in main.conf `[Rank] StrictPriorityOrder=true` (bool). Read in network_init via iwd_get_config + l_settings_get_bool. Modify network_rank_update: when strict mode and priority set, rank = USHRT_MAX + priority*(USHRT_MAX+1) + decay(n)*USHRT_MAX tiebreak, ignoring bss_rank. Clamp priority to 0-255 in parse to avoid overflow. Also handle negative priority → treat as 0 or lowest. Keep group separation: connected INT_MAX still highest.

Code:

```c
static bool strict_priority_order;

/* in network_init */
if (!l_settings_get_bool(iwd_get_config(), "Rank", "StrictPriorityOrder", &strict_priority_order))
    strict_priority_order = false;
```

In network_rank_update group 2:

```c
if (info->config.connected_time != 0) {
    int n = known_network_offset(info);
    L_WARN_ON(n < 0);

    if (strict_priority_order) {
        /* priority 决定层级，同优先级按 connected_time 排序，忽略信号 */
        network->rank = USHRT_MAX +
            info->config.priority * (USHRT_MAX + 1) +
            (int)(util_exponential_decay(n) * USHRT_MAX);
    } else {
        network->rank =
            util_exponential_decay(n) * best_bss->rank + USHRT_MAX;
    }
}
```

Wait: decay(n)*USHRT_MAX max = 65535, and priority step is 65536 — so same-priority networks ordered by n (recency), different priority never overlap. Good. But note n counts only seen networks; fine.

Overflow: priority int32 up to 2^31 * 65536 overflows. Clamp priority in parse to e.g. -255..255? If negative allowed, rank could go below USHRT_MAX into group 3 range — actually that could be a feature (deprioritize below never-connected). But keep simple: clamp to [-255, 255]; negative priority gives rank < USHRT_MAX, dropping into "never connected" band — mention this. Or clamp 0..255. I'll clamp to [-255,255] and note negatives push below group 2. Actually simpler and safer: clamp 0-255, document. But user might want negative to deprioritize — mention option. I'll clamp to [-255, 255] and explain: negative priority sinks the network below the "connected before" group. Hmm but then it competes with group-3 by raw bss_rank... rank = USHRT_MAX + (-1)*65536 + ... ≈ small positive, similar to group 3 range (bss_rank ~0-65535*1.2). Acceptable; document.

Also note: security factor multiplication still applies after — in strict mode multiplying by 1.2/0.5 would break strict ordering (open network with priority 20 * 0.5 could drop below wep priority 19). Need to skip the security factors in strict mode, or apply before adding priority base. Simplest: in strict mode return early before the RSNE/WPA factors, or guard them. I'll wrap: compute strict rank and skip factor block via else structure. Show code with early return.

Also mention: network_rankmod unchanged (still used for BSS selection within a network — fine).

Docs: iwd.config.rst [Rank] add StrictPriorityOrder entry.

Write final answer in Chinese with code.实现方案：在 `main.conf` 的 `[Rank]` 组加一个布尔开关 `StrictPriorityOrder`，开启后 `network_rank_update` 中 priority 直接决定 rank 层级，完全忽略 `bss_rank`（信号强度）。全局配置通过 `iwd_get_config()` 读取（`src/iwd.h:33`），与 `scan.c` 读 `BandModifier*` 是同一套机制 iwd:2601-2604 。

## 1. `src/network.c`

文件顶部加静态变量：

```c
static bool strict_priority_order;
```

`network_init()`（2207 行）中读取配置：

```c
static int network_init(void)
{
	const struct l_settings *config = iwd_get_config();

	if (!l_settings_get_bool(config, "Rank", "StrictPriorityOrder",
					&strict_priority_order))
		strict_priority_order = false;

	... /* 原有代码 */
}
```

`network_rank_update()` 中第 2 组（已连过的网络）改为：

```c
	if (info->config.connected_time != 0) {
		int n = known_network_offset(info);

		L_WARN_ON(n < 0);

		if (strict_priority_order) {
			/*
			 * Strict mode: priority 决定层级，每层间隔
			 * USHRT_MAX+1，同层内用 connected_time 衰减
			 * 做 tie-break，完全忽略 bss_rank（信号强度）。
			 */
			network->rank = USHRT_MAX +
				info->config.priority * (USHRT_MAX + 1) +
				(int) (util_exponential_decay(n) * USHRT_MAX);
			return;	/* 跳过后面的 RSNE/WPA/Open 安全因子，
				 * 否则 Open 网络乘 0.5 会破坏严格分层 */
		}

		network->rank =
			util_exponential_decay(n) * best_bss->rank + USHRT_MAX;
	} else
		network->rank = best_bss->rank;
```

## 2. priority 取值范围要钳制

`priority` 是 `int32_t`，乘 65536 后必须保证不溢出 `int`。在 `__network_config_parse` 解析时钳制：

```c
	if (!l_settings_get_int(settings, NET_PRIORITY, &i))
		i = 0;

	if (i > 255)
		i = 255;
	else if (i < -255)
		i = -255;

	config->priority = i;
```

范围 `[-255, 255]` 时最大 rank 约 `255 * 65536 + 2*65535 ≈ 16.9M`，远小于 `INT_MAX`，不会和"当前已连接"组冲突。负 priority 会把网络压到 `USHRT_MAX` 以下，即掉到"从未连过的网络"那一档——可以当作"强制最后连接"的语义，文档里说明即可。

## 3. 效果

`StrictPriorityOrder=true` 时，第 2 组内：

- priority 不同 → rank 差至少 65536，信号强度、加密类型都无法翻盘，**严格按 Priority 从大到小连接**；
- priority 相同 → 按 `connected_time`（`decay(n)`）排序，与现有行为一致；
- priority 全为 0 → 退化为按最近连接时间排序，仍不看信号。

`StrictPriorityOrder=false`（默认）→ 完全保持原逻辑，priority 只通过队列排序影响 `n`，信号强仍可翻盘。

注意 `network_rankmod()`（`src/network.c:220-240`）不需要改——它用于同一网络内选 BSS，与网络间优先级无关。

## 4. 文档 `src/iwd.config.rst`

`[Rank]` 表中追加：

```rst
   * - StrictPriorityOrder
     - Values: true, **false**

       When enabled, known networks are ordered strictly by the
       per-network ``Priority`` setting (see iwd.network(5)) for
       autoconnect, ignoring BSS signal strength and security
       factors.  Networks with equal priority are ordered by last
       connected time.  When disabled (default), priority only
       affects ordering and signal strength may still dominate.
```

## 5. 使用示例

```ini
# /etc/iwd/main.conf
[Rank]
StrictPriorityOrder=true
```

```ini
# /var/lib/iwd/wifiB.psk
[Settings]
Priority=20
```

一个未验证点：`util_exponential_decay` 的返回值表我只看到引用（`src/util.c` 的 `rankmod_table`），其精确值未逐行确认，但它返回 `(0, 1]` 区间的小数，乘 `USHRT_MAX` 后落在 `[0, 65535]`，不会侵入相邻 priority 层——这个推导是安全的。
### Citations
**File:** src/scan.c (L2601-2604)
```c
	if (!l_settings_get_double(config, "Rank", str, &modifier))
		modifier = 1.0;

	return modifier;
```
## Q7
为什么man iwd.config 文档不生效
### Answer
User asks why `man iwd.config` doesn't show the new option / doesn't take effect. Likely: man page generated from .rst at build time; need rebuild/install; or man reads installed page not source. Check build files for rst→man generation.Check where manual_pages defined and RUN_RST2MAN condition in configure.ac.Explain why man iwd.config doesn't show new option: man pages generated from .rst at build time via rst2man; need rebuild + reinstall; also man reads installed page (/usr/share/man/man5), not source .rst; rst2man may not be installed → RUN_RST2MAN false → uses pre-generated pages shipped in tarball; also man cache (mandb) or wrong MANPATH.`man iwd.config` 显示的不是 `src/iwd.config.rst` 源文件，而是构建时生成的 `src/iwd.config.5` 安装到系统 man 目录后的结果。改了 `.rst` 后 `man` 看不到新内容，原因在构建链路上：

## man 页的生成机制

- `Makefile.am` 中 `manual_pages` 包含 `src/iwd.config.5`，由规则 `%.5: %.rst` 通过 `rst2man` 从 `.rst` 生成 iwd:196-198 iwd:774-775 
- 只有 configure 时检测到 `rst2man`/`rst2man.py` 且未传 `--disable-manual-pages`，`RUN_RST2MAN` 才为真，才会真正重新生成 iwd:232-239 
- 如果系统没装 `rst2man`（python-docutils），走 `else` 分支：直接使用源码树里**已存在的旧 `.5` 文件**，不会报错也不会重新生成 iwd:759-766 

## 排查步骤

1. **确认 rst2man 是否可用**

   ```
   which rst2man rst2man.py
   ```

   没有则安装 `python-docutils`（或发行版对应包），重新 `./configure && make`。

2. **确认 `.5` 文件真的重新生成了**

   ```
   grep -i StrictPriorityOrder src/iwd.config.5
   ```

   如果 grep 不到，说明生成没跑——删掉旧的 `src/iwd.config.5` 再 `make`，强制重建。

3. **确认安装到了 man 实际读取的位置**

   ```
   man -w iwd.config        # 看 man 读的是哪个文件
   grep -i StrictPriorityOrder $(man -w iwd.config)
   ```

   如果你 `make install` 的 prefix 是 `/usr/local` 而系统 man 读的是 `/usr/share/man`，或者你根本没重新 `make install`，看到的还是旧页。

4. **发行版包的干扰**

   如果系统通过包管理器装过 iwd，`man` 可能读到 `/usr/share/man/man5/iwd.config.5.gz`（打包时的旧版本）。你自编译安装的路径若不同，需要确认 `MANPATH` 优先级，或直接覆盖安装到相同 prefix。

5. **man 缓存**

   少数情况下 `man` 有缓存（`catman`），可 `sudo mandb` 刷新，但通常不是主因。

## 最常见的组合

改了 `.rst` → 没装 `rst2man` → `make` 静默复用旧 `.5` → `make install` 装的还是旧页 → `man` 看不到。先跑第 2 步的 `grep` 就能定位是"没生成"还是"没装对位置"。

另外注意：man 页只是文档，它"不生效"不影响功能本身——`StrictPriorityOrder` 是否生效取决于 `network.c` 的代码是否编译进了正在运行的 `iwd` 二进制，与 man 页无关。
### Citations
**File:** Makefile.am (L196-198)
```text
manual_pages = src/iwd.8 src/iwd.debug.7 src/iwd.config.5 src/iwd.network.5 \
		src/iwd.ap.5 client/iwctl.1 monitor/iwmon.1 wired/ead.8 \
		tools/hwsim.1
```
**File:** Makefile.am (L759-766)
```text
if RUN_RST2MAN
RST2MAN_PROCESS = $(AM_V_GEN)$(MKDIR_P) $(dir $@) && \
			$(RST2MAN) --strict --no-raw \
			--no-generator --no-datestamp $< $@
else
RST2MAN_PROCESS = $(AM_V_GEN)test -f $@ || \
		{ echo "Generated manual page $@ does not exist"; false; }
endif
```
**File:** Makefile.am (L774-775)
```text
%.5: %.rst Makefile
	$(RST2MAN_PROCESS)
```
**File:** configure.ac (L232-239)
```text
AC_ARG_ENABLE([manual-pages], AS_HELP_STRING([--disable-manual-pages],
				[don't install manual pages]),
					[enable_manual_pages=${enableval}])
if (test "${enable_manual_pages}" != "no"); then
	AC_CHECK_PROGS(RST2MAN, [rst2man rst2man.py], "no")
fi
AM_CONDITIONAL(MANUAL_PAGES, test "${enable_manual_pages}" != "no")
AM_CONDITIONAL(RUN_RST2MAN, test "${enable_manual_pages}" != "no" && test "${RST2MAN}" != "no")
```
