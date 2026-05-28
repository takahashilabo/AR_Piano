// Web MIDI API bridge — injected via HTML head_include
// Pushes [status, note, velocity] into window._midiQueue.
// MidiReceiver.gd drains the queue every frame via JavaScriptBridge.eval().

console.log("[MIDI] midi_bridge.js loading...");

(function () {
  window._midiQueue = window._midiQueue || [];

  if (!navigator.requestMIDIAccess) {
    console.warn("[MIDI] Web MIDI API not supported.");
    return;
  }

  navigator.requestMIDIAccess({ sysex: false }).then(function (access) {
    console.log("[MIDI] Access granted. Inputs:", access.inputs.size);

    function connectInput(input) {
      console.log("[MIDI] Connected:", input.name);
      input.onmidimessage = function (msg) {
        window._midiQueue.push([
          msg.data[0],
          msg.data[1],
          msg.data.length > 2 ? msg.data[2] : 0,
        ]);
      };
    }

    access.inputs.forEach(connectInput);

    access.onstatechange = function (e) {
      if (e.port.type === "input" && e.port.state === "connected") {
        connectInput(e.port);
      }
    };
  }, function (err) {
    console.error("[MIDI] Access denied:", err);
  });
})();
