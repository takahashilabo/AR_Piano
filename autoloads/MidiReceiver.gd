extends Node

signal note_received(status: int, note: int, velocity: int)
signal status_changed(text: String)

func _ready():
	emit_signal("status_changed", "MidiReceiver ready")
	if not OS.has_feature("web"):
		emit_signal("status_changed", "ERROR: not web")
		return
	emit_signal("status_changed", "Requesting MIDI...")
	JavaScriptBridge.eval("""
		window._midiQueue  = [];
		window._midiStatus = 'requesting...';
		window._midiLog    = 'init';

		function connectInput(input) {
			input.open().then(function() {
				window._midiStatus = 'connected: ' + input.name;
				window._midiLog    = 'connected: ' + input.name;
				input.onmidimessage = function(msg) {
					window._midiLog = 'msg st=0x' + msg.data[0].toString(16)
						+ ' n=' + msg.data[1]
						+ ' v=' + (msg.data.length > 2 ? msg.data[2] : 0);
					window._midiQueue.push([
						msg.data[0],
						msg.data[1],
						msg.data.length > 2 ? msg.data[2] : 0
					]);
				};
			}).catch(function(err) {
				window._midiLog = 'open error: ' + input.name + ': ' + err;
			});
		}

		function scanInputs() {
			if (!window._midiAccess) return;
			var n = 0;
			window._midiAccess.inputs.forEach(function(input) {
				n++;
				connectInput(input);
			});
			window._midiLog = 'scanned inputs=' + n;
			if (n === 0) window._midiStatus = 'no device (waiting...)';
		}

		// ページが前面に戻ったとき自動再スキャン（USB抜き差し後の対処）
		document.addEventListener('visibilitychange', function() {
			if (!document.hidden) {
				window._midiLog = 'visibility: rescanning...';
				scanInputs();
			}
		});

		// JS から呼べる手動リセット関数
		window._midiReset = function() {
			window._midiLog = 'manual reset...';
			if (window._midiAccess) {
				window._midiAccess.inputs.forEach(function(input) {
					input.close().catch(function(){});
				});
			}
			setTimeout(scanInputs, 400);
		};

		if (!navigator.requestMIDIAccess) {
			window._midiStatus = 'API not supported';
			window._midiLog    = 'API not supported';
		} else {
			navigator.requestMIDIAccess({ sysex: false }).then(function(access) {
				window._midiAccess = access;
				scanInputs();
				access.onstatechange = function(e) {
					window._midiLog = 'state: ' + e.port.name + '=' + e.port.state;
					if (e.port.type === 'input') {
						if (e.port.state === 'connected') {
							connectInput(e.port);
						} else {
							window._midiStatus = 'disconnected: ' + e.port.name;
						}
					}
				};
			}, function(err) {
				window._midiStatus = 'denied: ' + err;
				window._midiLog    = 'denied: ' + err;
			});
		}
	""")

func _process(_delta: float) -> void:
	if not OS.has_feature("web"):
		return

	var status = JavaScriptBridge.eval("window._midiStatus || ''")
	if status != null and str(status) != "":
		emit_signal("status_changed", str(status))
		JavaScriptBridge.eval("window._midiStatus = ''")

	var raw = JavaScriptBridge.eval(
		"(function(){ var q=window._midiQueue; if(!q||!q.length) return null; var r=q.splice(0); return JSON.stringify(r); })()"
	)
	if raw == null:
		return
	var msgs = JSON.parse_string(str(raw))
	if msgs == null:
		return
	for msg in msgs:
		emit_signal("note_received", int(msg[0]), int(msg[1]), int(msg[2]))

# main.gd から呼ぶ手動リセット
func reset_midi() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("if(window._midiReset) window._midiReset();")
