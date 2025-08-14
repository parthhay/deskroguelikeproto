extends Node

const HTTP_PORT := 8080
const CONTROLLER_ROOT := "res://controller"
const LAN_IP_OVERRIDE := "" # e.g. "192.168.1.42" to force a specific IP (optional)

const START_HAND := 5
const DRAW_PER_TURN := 1

var _server := TCPServer.new()
var _conns: Array = []  # each: { "peer": StreamPeerTCP, "buf": PackedByteArray }


# Card piles
var _hands := {1: [], 2: [], 3: []}      # replace your old contents with empty arrays
var _decks := {1: [], 2: [], 3: []}
var _discards := {1: [], 2: [], 3: []}

var _base_deck: Array = [
	"Strike","Strike","Strike",
	"Zap","Zap",
	"Shield","Shield",
	"Heal","Heal",
	"Shield All",
	"Draw" # <- new effect: draw 2
]
var _boss_spawned: bool = false
# player/session state
var _player_slots := {1:null, 2:null, 3:null} # slot -> peer_id (string)
var _peer_info := {} # peer_id(str) -> { "player_id": int, "name": String }
# very simple turn state
var _turn_player := 1
# session tokens per player slot (for ownership/auth)
var _slot_tokens := {1:"", 2:"", 3:""}
# run/game state
var _players := {
	1: {"name":"", "hp":30, "max_hp":30, "shield":0, "alive":true},
	2: {"name":"", "hp":30, "max_hp":30, "shield":0, "alive":true},
	3: {"name":"", "hp":30, "max_hp":30, "shield":0, "alive":true},
}
var _enemies: Array = []  # each: {"id":int,"name":String,"hp":int,"max_hp":int}
var _enemy_id_seq := 0
var _run_over := false

# waves & boss
var _wave_index: int = 0
var _waves: Array = []        # Array of Array[Dictionary]: [{ "name": String, "hp": int }, ...]
var _event_id := 0
var _events: Array = [] # simple log of broadcasts (not yet used by client)

func _ready() -> void:
	var err := _server.listen(HTTP_PORT)
	if err != OK:
		push_error("Listen failed: %s" % err)
		return
	print("HTTP listening on:", HTTP_PORT)
	_print_all_ips()
	var ip := _preferred_lan_ip()
	print("On THIS PC:                 http://localhost:%d/" % HTTP_PORT)
	print("On OTHER devices (Wi-Fi):   http://%s:%d/" % [ip, HTTP_PORT])

func _process(_dt: float) -> void:
	_accept_new()
	_service_conns()

func _accept_new() -> void:
	if _server.is_connection_available():
		var p := _server.take_connection()
		if p:
			p.set_no_delay(true)
			_conns.append({"peer": p, "buf": PackedByteArray()})

func _service_conns() -> void:
	# iterate backwards so we can remove safely
	for i in range(_conns.size() - 1, -1, -1):
		var c: Dictionary = _conns[i]
		var peer: StreamPeerTCP = c["peer"]
		# drop closed
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.remove_at(i)
			continue
		# read available bytes
		var avail := peer.get_available_bytes()
		if avail > 0:
			var res := peer.get_partial_data(avail)
			if res[0] == OK and (res[1] as PackedByteArray).size() > 0:
				var buf: PackedByteArray = c["buf"]
				buf.append_array(res[1])
				c["buf"] = buf
		# try to parse a full HTTP request
		var req := _parse_http_request(c["buf"])
		if req.size() > 0: # got one full request
			var resp: PackedByteArray = _handle_request(req)
			peer.put_data(resp)
			peer.disconnect_from_host()
			_conns.remove_at(i)

func _parse_http_request(buf: PackedByteArray) -> Dictionary:
	var s := buf.get_string_from_utf8()
	var header_end := s.find("\r\n\r\n")
	if header_end == -1:
		return {} # need more
	var header_str := s.substr(0, header_end)
	var lines := header_str.split("\r\n")
	if lines.size() < 1:
		return {}
	var first: String = lines[0]
	var parts := first.split(" ")
	if parts.size() < 3:
		return {}
	var method: String = parts[0]
	var full_path: String = parts[1]
	var path := full_path
	var query := ""
	var qidx := full_path.find("?")
	if qidx != -1:
		path = full_path.substr(0, qidx)
		query = full_path.substr(qidx + 1, full_path.length())

	var headers: Dictionary = {}
	for j in range(1, lines.size()):
		var ln: String = lines[j]
		var cidx := ln.find(":")
		if cidx != -1:
			var key := ln.substr(0, cidx).strip_edges().to_lower()
			var val := ln.substr(cidx + 1, ln.length()).strip_edges()
			headers[key] = val

	# compute body start by bytes
	var head_bytes := header_end + 4
	var total_bytes := buf.size()
	var content_length := int(headers.get("content-length", "0"))
	if method == "POST":
		if total_bytes - head_bytes < content_length:
			return {} # need more body
	var body_bytes := PackedByteArray()
	if method == "POST" and content_length > 0:
		body_bytes = buf.slice(head_bytes, head_bytes + content_length)

	# clear buffer (single-request per connection)
	buf.resize(0)

	return {
		"method": method,
		"path": path,
		"query": query,
		"headers": headers,
		"body": body_bytes
	}

func _handle_request(req: Dictionary) -> PackedByteArray:
	var method: String = req["method"]
	var path: String = req["path"]

	match method:
		"GET":
			if path == "/" or path == "/index.html":
				return _respond_file(CONTROLLER_ROOT + "/index.html", "text/html; charset=utf-8")
			if path == "/client.js":
				return _respond_file(CONTROLLER_ROOT + "/client.js", "text/javascript; charset=utf-8")
			if path == "/lobby":
				return _json_ok({"slots": _slots_payload()})
			if path == "/hand":
				var qp := _parse_query(String(req["query"]))
				var pid := int(qp.get("player_id", "0"))
				return _json_ok({"player_id": pid, "hand": _hands.get(pid, [])})
			if path == "/state":
				var qp2 := _parse_query(String(req["query"]))
				var pid2 := int(qp2.get("player_id", "0"))
				return _json_ok(_state_payload(pid2))
			if path == "/start": # ← handy test via address bar
				print("[HTTP] GET /start")
				_start_run()
				var qp3 := _parse_query(String(req["query"]))
				var pid3 := int(qp3.get("player_id", "0"))
				return _json_ok(_state_payload(pid3))
			return _not_found()

		"POST":
			var body: Dictionary = {}
			var has_body := (req["body"] as PackedByteArray).size() > 0
			if has_body:
				var parsed = JSON.parse_string((req["body"] as PackedByteArray).get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					body = parsed
				else:
					return _json_bad({"error":"bad_json"})

			if path == "/claim":
				var player_name := String(body.get("name","Player")).substr(0, 20)
				return _claim(player_name, req)

			if path == "/play_card":
				return _play_card(body, req)

			if path == "/start":
				print("[HTTP] POST /start")
				_start_run()
				var bpid := int(body.get("player_id", 0))
				return _json_ok(_state_payload(bpid))

			return _not_found()

		_:
			return _json_bad({"error":"method_not_allowed"})

func _respond_file(res_path: String, mime: String) -> PackedByteArray:
	if not FileAccess.file_exists(res_path):
		return _not_found()
	var f := FileAccess.open(res_path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	return _http_ok(mime, data)

func _json_ok(d: Dictionary) -> PackedByteArray:
	var body := JSON.stringify(d).to_utf8_buffer()
	return _http_ok("application/json; charset=utf-8", body)

func _json_bad(d: Dictionary) -> PackedByteArray:
	var body := JSON.stringify(d).to_utf8_buffer()
	return _http_resp(400, "Bad Request", "application/json; charset=utf-8", body)

func _not_found() -> PackedByteArray:
	var body := "Not Found".to_utf8_buffer()
	return _http_resp(404, "Not Found", "text/plain; charset=utf-8", body)

func _http_ok(mime: String, body: PackedByteArray) -> PackedByteArray:
	return _http_resp(200, "OK", mime, body)

func _http_resp(code: int, reason: String, mime: String, body: PackedByteArray) -> PackedByteArray:
	var headers := "HTTP/1.1 " + str(code) + " " + reason + "\r\n" \
		+ "Content-Type: " + mime + "\r\n" \
		+ "Content-Length: " + str(body.size()) + "\r\n" \
		+ "Connection: close\r\n" \
		+ "Access-Control-Allow-Origin: *\r\n" \
		+ "Cache-Control: no-store, must-revalidate\r\n" \
		+ "Pragma: no-cache\r\n" \
		+ "Expires: 0\r\n\r\n"

	var head_bytes: PackedByteArray = headers.to_utf8_buffer()
	var out := PackedByteArray()
	out.append_array(head_bytes)
	out.append_array(body)
	return out

func _parse_query(q: String) -> Dictionary:
	var out: Dictionary = {}
	for pair in q.split("&", false):
		if pair == "":
			continue
		var kv := pair.split("=", false)
		var k := kv[0]
		var v := kv[1] if kv.size() > 1 else ""
		out[k] = v.uri_decode()
	return out

func _claim(player_name: String, _req: Dictionary) -> PackedByteArray:
	# reuse a slot if same name already present (prototype convenience)
	for pid in [1,2,3]:
		if _player_slots[pid] != null:
			var key: String = String(_player_slots[pid])  # <— add explicit type
			if _peer_info.has(key) and String(_peer_info[key]["name"]) == player_name:
				_players[pid]["name"] = player_name
				return _json_ok({"player_id": pid, "hand": _hands.get(pid, []), "token": _slot_tokens[pid]})

	# find first free slot
	var assigned := 0
	for pid in [1,2,3]:
		if _player_slots[pid] == null:
			var token := _new_token()
			var peer_key := token
			_player_slots[pid] = peer_key
			_peer_info[peer_key] = {"player_id": pid, "name": player_name}
			_slot_tokens[pid] = token
			_players[pid]["name"] = player_name
			assigned = pid
			break
	if assigned == 0:
		return _json_bad({"error":"lobby_full"})

	_log_event({"type":"join","player_id":assigned,"name":player_name})
	return _json_ok({"player_id": assigned, "hand": _hands.get(assigned, []), "token": _slot_tokens[assigned]})

func _play_card(body: Dictionary, _req: Dictionary) -> PackedByteArray:
	if _run_over:
		return _json_bad({"error":"run_over"})

	var pid: int = int(body.get("player_id", 0))
	var token: String = String(body.get("token", ""))
	var card: String = String(body.get("card", ""))
	var target: String = String(body.get("target", "none"))

	# Validate player + token + turn
	if pid < 1 or pid > 3:
		return _json_bad({"error":"bad_player"})
	if token == "" or _slot_tokens.get(pid, "") != token:
		return _json_bad({"error":"bad_token"})
	if pid != _turn_player:
		return _json_bad({"error":"not_your_turn", "turn_player": _turn_player})

	# Validate card ownership
	if not _hands.get(pid, []).has(card):
		return _json_bad({"error":"illegal_card"})

	# ---- Effects ----
	match card:
		"Strike":
			var eid: int = _parse_enemy_tag(target)
			if eid == -1:
				eid = _first_enemy_id()
				if eid == -1:
					return _json_bad({"error":"need_enemy_target"})
			_damage_enemy(eid, 6)

		"Zap":
			var zeid: int = _parse_enemy_tag(target)
			if zeid == -1:
				zeid = _first_enemy_id()
				if zeid == -1:
					return _json_bad({"error":"need_enemy_target"})
			_damage_enemy(zeid, 4)

		"Shield":
			_add_shield(pid, 5)

		"Heal":
			_heal_player(pid, 5)

		"Shield All":
			for apid in [1,2,3]:
				if _player_slots[apid] != null and bool(_players[apid]["alive"]):
					_add_shield(apid, 5)

		"Draw":
			_draw(pid, 2)

		_:
			pass

	# ---- Consume: move from hand -> discard (single instance) ----
	var removed: bool = false
	for i in range(_hands[pid].size()):
		if String(_hands[pid][i]) == card:
			_hands[pid].remove_at(i)
			removed = true
			break
	if removed:
		_discards[pid].append(card)

	_log_event({"type":"card_played", "player_id": pid, "card": card, "target": target})

	# Advance waves / maybe win; the helper sets _run_over when appropriate
	_maybe_advance_wave_or_win()
	if _run_over:
		return _json_ok(_state_payload(pid))

	# Advance turn or enemy phase
	_next_turn_or_enemy_phase()
	return _json_ok(_state_payload(pid))

func _slots_payload() -> Dictionary:
	return {
		"1": _slot_info(1),
		"2": _slot_info(2),
		"3": _slot_info(3)
	}

func _slot_info(pid: int) -> Dictionary:
	var peer_id = _player_slots[pid]
	if peer_id == null: return {"occupied": false}
	var nm := "Player"
	if _peer_info.has(peer_id):
		nm = String(_peer_info[peer_id]["name"])
	return {"occupied": true, "name": nm}

func _log_event(ev: Dictionary) -> void:
	_event_id += 1
	ev["id"] = _event_id
	_events.append(ev)
	if _events.size() > 256:
		_events.pop_front()
	print("[EVENT]", ev)

func _req_peer_id(req: Dictionary) -> String:
	# Crude fingerprint (prototype only)
	var ua := String(req["headers"].get("user-agent",""))
	return str(hash(ua + str(Time.get_ticks_msec())))

func _local_ip() -> String:
	for a in IP.get_local_addresses():
		if a.find(":") == -1 and not a.begins_with("127."):
			return a
	return "localhost"

func _new_token() -> String:
	return str(randi()) + "-" + str(Time.get_ticks_msec())

func _state_payload(pid: int) -> Dictionary:
	return {
		"turn_player": _turn_player,
		"your_player_id": pid,
		"your_hand": _hands.get(pid, []),
		"players": _players,
		"enemies": _enemies,
		"run_over": _run_over,
		"wave": _wave_index + 1,
		"slots": _slots_payload(),
		"deck_count": _decks.get(pid, []).size(),
		"discard_count": _discards.get(pid, []).size(),
	}

func _next_turn_or_enemy_phase() -> void:
	# next occupied slot
	var next_pid := _turn_player + 1
	while next_pid <= 3 and _player_slots[next_pid] == null:
		next_pid += 1
	if next_pid <= 3:
		_turn_player = next_pid
		_draw(_turn_player, DRAW_PER_TURN)  # << add this
	else:
		_enemy_phase()
		_turn_player = 1
		_draw(_turn_player, DRAW_PER_TURN)  # << and this

func _enemy_phase() -> void:
	var alive_pids: Array = []
	for pid in [1,2,3]:
		if _player_slots[pid] != null and bool(_players[pid]["alive"]):
			alive_pids.append(pid)
	if alive_pids.size() == 0:
		_run_over = true
		_log_event({"type":"run_ended","result":"lose"})
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for i in range(_enemies.size()):
		# Boss follows its cycle
		if bool(_enemies[i].get("is_boss", false)):
			_boss_act(i)
			continue
		# Grunts hit a random alive player for 3
		if alive_pids.size() == 0:
			break
		var tgt_idx := rng.randi_range(0, alive_pids.size()-1)
		var tgt_pid: int = int(alive_pids[tgt_idx])
		_apply_damage_to_player(tgt_pid, 3)
		_log_event({"type":"enemy_attack","enemy":_enemies[i]["name"],"target_pid":tgt_pid,"dmg":3})

		# recompute alive list in case someone died
		alive_pids.clear()
		for pid in [1,2,3]:
			if _player_slots[pid] != null and bool(_players[pid]["alive"]):
				alive_pids.append(pid)

	# defeat check
	if alive_pids.size() == 0:
		_run_over = true
		_log_event({"type":"run_ended","result":"lose"})

func _print_all_ips() -> void:
	print("--- Local addresses ---")
	for a in IP.get_local_addresses():
		print(a)

func _preferred_lan_ip() -> String:
	if LAN_IP_OVERRIDE != "":
		return LAN_IP_OVERRIDE
	var addrs := IP.get_local_addresses()
	# Prefer RFC1918 ranges
	for a in addrs:
		if a.find(":") != -1: continue
		if a.begins_with("192.168."): return a
	for a in addrs:
		if a.find(":") != -1: continue
		if a.begins_with("10."): return a
	for a in addrs:
		if a.find(":") != -1: continue
		if a.begins_with("172."):
			var parts := a.split(".")
			if parts.size() >= 2:
				var second := int(parts[1])
				if second >= 16 and second <= 31:
					return a
	# Fallback: any non-loopback, non-link-local IPv4
	for a in addrs:
		if a.find(":") != -1: continue
		if not a.begins_with("127.") and not a.begins_with("169.254."):
			return a
	return "localhost"

func _spawn_enemy(enemy_name: String, hp: int) -> void:
	_enemy_id_seq += 1
	_enemies.append({"id": _enemy_id_seq, "name": enemy_name, "hp": hp, "max_hp": hp})

func _start_run() -> void:
	print("[HTTP] _start_run called")
	_enemies.clear()
	_enemy_id_seq = 0
	_run_over = false
	_turn_player = 1
	_boss_spawned = false
	_build_waves()
	_spawn_wave(_wave_index)
	# reset players
	for pid in [1,2,3]:
		_players[pid]["hp"] = _players[pid]["max_hp"]
		_players[pid]["shield"] = 0
		_players[pid]["alive"] = true
	# cards
	_setup_decks()
	_log_event({"type":"run_started","wave": _wave_index + 1})
	print("[HTTP] _start_run finished — wave:", _wave_index + 1)

func _find_enemy(eid: int) -> int:
	for i in range(_enemies.size()):
		if int(_enemies[i]["id"]) == eid:
			return i
	return -1

func _damage_enemy(eid: int, dmg: int) -> void:
	var idx := _find_enemy(eid)
	if idx == -1: return
	_enemies[idx]["hp"] = int(_enemies[idx]["hp"]) - dmg
	if int(_enemies[idx]["hp"]) <= 0:
		_log_event({"type":"enemy_defeated","id":eid,"name":_enemies[idx]["name"]})
		_enemies.remove_at(idx)

func _heal_player(pid: int, amt: int) -> void:
	var hp := int(_players[pid]["hp"])
	var mx := int(_players[pid]["max_hp"])
	hp = min(mx, hp + amt)
	_players[pid]["hp"] = hp

func _add_shield(pid: int, amt: int) -> void:
	_players[pid]["shield"] = int(_players[pid]["shield"]) + amt

func _apply_damage_to_player(pid: int, dmg: int) -> void:
	var shield: int = int(_players[pid]["shield"])
	var rem: int = dmg
	if shield > 0:
		var absorb: int = int(min(shield, rem))
		shield -= absorb
		rem -= absorb
	_players[pid]["shield"] = int(max(0, shield))
	if rem > 0:
		var hp: int = int(_players[pid]["hp"]) - rem
		_players[pid]["hp"] = hp
		if hp <= 0:
			_players[pid]["alive"] = false

func _parse_enemy_tag(tag: String) -> int:
	# "enemy_<id>" -> id
	if not tag.begins_with("enemy_"):
		return -1
	var parts := tag.split("_", false)
	if parts.size() < 2: return -1
	return int(parts[1])

func _spawn_boss(enemy_name: String, hp: int) -> void:
	_enemy_id_seq += 1
	_enemies.append({
		"id": _enemy_id_seq,
		"name": enemy_name,
		"hp": hp,
		"max_hp": hp,
		"is_boss": true,
		"phase": "telegraph" # telegraph -> charge -> smite -> telegraph ...
	})

func _build_waves() -> void:
	_waves = [
		[{"name":"Grunt A","hp":12}, {"name":"Grunt B","hp":12}],
		[{"name":"Grunt Elite","hp":16}],
	]
	_wave_index = 0

func _spawn_wave(index: int) -> void:
	if index < 0 or index >= _waves.size():
		return
	_enemies.clear()
	_enemy_id_seq = 0
	for e in _waves[index]:
		_spawn_enemy(String(e["name"]), int(e["hp"]))

func _maybe_advance_wave_or_win() -> void:
	# Only act when the field is empty
	if _enemies.size() > 0:
		return

	# If boss already happened and now field is empty -> WIN
	if _boss_spawned:
		_run_over = true
		_log_event({"type":"run_ended","result":"win"})
		return

	# Otherwise we are still in pre-boss waves
	if _wave_index + 1 < _waves.size():
		_wave_index += 1
		_spawn_wave(_wave_index)
		# small refill for alive players
		for pid in [1,2,3]:
			if _player_slots[pid] != null and bool(_players[pid]["alive"]):
				_draw(pid, 2)
		_log_event({"type":"wave_started","wave": _wave_index + 1})
	else:
		# No more waves -> spawn boss ONCE
		_spawn_boss("Arena Warden", 42)
		_boss_spawned = true
		for pid in [1,2,3]:
			if _player_slots[pid] != null and bool(_players[pid]["alive"]):
				_draw(pid, 2)
		_log_event({"type":"boss_appeared","name":"Arena Warden","hp":42})

func _boss_act(idx: int) -> void:
	var boss: Dictionary = _enemies[idx]
	if not bool(boss.get("is_boss", false)):
		return
	var phase: String = String(boss.get("phase","telegraph"))
	match phase:
		"telegraph":
			# Announce incoming big hit; no damage yet
			_log_event({"type":"boss_phase","phase":"telegraph"})
			boss["phase"] = "charge"
		"charge":
			_log_event({"type":"boss_phase","phase":"charge"})
			boss["phase"] = "smite"
		"smite":
			# Big AOE; shields mitigate as usual
			var dmg: int = 8
			for pid in [1,2,3]:
				if _player_slots[pid] != null and bool(_players[pid]["alive"]):
					_apply_damage_to_player(pid, dmg)
			_log_event({"type":"boss_smite","dmg":8})
			boss["phase"] = "telegraph"
		_:
			boss["phase"] = "telegraph"
	_enemies[idx] = boss

func _shuffle_array(a: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp

func _setup_decks() -> void:
	for pid in [1,2,3]:
		_decks[pid] = _base_deck.duplicate()
		_discards[pid] = []
		_hands[pid] = []
		_shuffle_array(_decks[pid])
		_draw(pid, START_HAND)

func _draw(pid: int, n: int) -> void:
	for i in range(n):
		if _decks[pid].size() == 0:
			if _discards[pid].size() == 0:
				break
			# reshuffle discard into deck
			_decks[pid] = _discards[pid].duplicate()
			_discards[pid].clear()
			_shuffle_array(_decks[pid])
		var card = _decks[pid].pop_back()
		_hands[pid].append(card)

func _first_enemy_id() -> int:
	if _enemies.size() > 0:
		return int(_enemies[0]["id"])
	return -1
